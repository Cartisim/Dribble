import NIO
import _NIOConcurrency
import NIOConcurrencyHelpers
#if canImport(Android)
import Android
#endif

protocol StunMessageSender: Sendable {
    func sendMessage(_ message: StunMessage, on channel: Channel) async throws -> StunMessage
    func registerTurnAllocationChannel(_ channel: TurnAllocationChannel, theirAddress: SocketAddress) async throws
}

final class StunInboundHandler: @unchecked Sendable, ChannelInboundHandler, StunMessageSender {
    public typealias InboundIn = StunMessage
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    
    let remoteAddress: SocketAddress
    var queries = [StunTransactionId: EventLoopPromise<StunMessage>]()
    var allocations = [(SocketAddress, Channel)]()
    private let lock = NIOLock()
    
    init(remoteAddress: SocketAddress) {
        self.remoteAddress = remoteAddress
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)

        if message.header.type == .dataIndication {
            // Acquire lock only while reading shared state (attributes lookup is cheap)
            lock.lock()
            // capture allocation and buffer while locked
            var capturedBuffer: ByteBuffer?
            var capturedChannel: Channel?
            var resolveError: Error?

            do {
                if
                    let dataAttr = message.attributes.first(where: { $0.stunType == .data }),
                    let originAttr = message.attributes.first(where: { $0.stunType == .xorPeerAddress }),
                    case .data(let buffer) = try dataAttr.resolve(forTransaction: message.header.transactionId),
                    case .xorPeerAddress(let address) = try originAttr.resolve(forTransaction: message.header.transactionId)
                {
                    if let allocation = allocations.first(where: { allocation in
                        switch (allocation.0, address) {
                        case (.v4(let lhs), .v4(let rhs)):
                            return lhs.address.sin_addr.s_addr == rhs.address.sin_addr.s_addr
                        case (.v6(let lhs), .v6(let rhs)):
                        #if swift(>=5.5) && os(Linux) && !os(Android)
                            return lhs.address.sin6_addr.__in6_u.__u6_addr32 == rhs.address.sin6_addr.__in6_u.__u6_addr32
                        #elseif os(Android)
                            return withUnsafeBytes(of: lhs.address.sin6_addr) { lb in
                                withUnsafeBytes(of: rhs.address.sin6_addr) { rb in
                                    lb.elementsEqual(rb)
                                }
                            }
                        #else
                            return lhs.address.sin6_addr.__u6_addr.__u6_addr32 == rhs.address.sin6_addr.__u6_addr.__u6_addr32
                        #endif
                        default:
                            return false
                        }
                    }) {
                        capturedBuffer = buffer
                        capturedChannel = allocation.1
                    }
                }
            } catch {
                resolveError = error
            }
            lock.unlock()

            if let err = resolveError {
                print(err)
                return
            }

            if let buf = capturedBuffer, let ch = capturedChannel {
                ch.pipeline.fireChannelRead(buf)
            }
        } else {
            // remove promise under lock, then fulfill outside
            lock.lock()
            let promise = queries.removeValue(forKey: message.header.transactionId)
            lock.unlock()

            if let q = promise {
                q.succeed(message)
            }
        }
    }

    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        for query in queries.values {
            query.fail(error)
        }
        
        lock.lock()
        queries.removeAll()
        allocations.removeAll()
        lock.unlock()
        context.close(promise: nil)
    }

    func registerTurnAllocationChannel(_ channel: TurnAllocationChannel, theirAddress: SocketAddress) async throws {
        lock.lock()
        defer { lock.unlock() }
        allocations.append((theirAddress, channel))
    }
    
    func sendMessage(_ message: StunMessage, on channel: Channel) async throws -> StunMessage {
        var data = ByteBuffer()
        data.writeStunMessage(message)
        let promise = channel.eventLoop.makePromise(of: StunMessage.self)
        lock.lock()
        self.queries[message.header.transactionId] = promise
        lock.unlock()
        return try await channel.writeAndFlush(
            AddressedEnvelope(
                remoteAddress: remoteAddress,
                data: data
            )
        ).flatMap {
            promise.futureResult
        }.get()
    }
}
