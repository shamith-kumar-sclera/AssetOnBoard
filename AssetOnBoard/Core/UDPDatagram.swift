//
//  UDPDatagram.swift
//  AssetOnBoard
//
//  One-shot request/response over UDP.
//
//  Several probes follow the same shape — send a single datagram, keep the first
//  answer, give up on a deadline — so the transport lives here rather than being
//  reimplemented per protocol. Cellular is excluded because every user of this is
//  asking a question about the local network.
//

import Foundation
import Network

nonisolated enum UDPDatagram {

    private static let queue = DispatchQueue(label: "com.sclera.assetonboard.udp",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    /// Sends `payload` to `host:port` and returns the first datagram that comes
    /// back, or nil if nothing arrives before `timeout`.
    static func exchange(with host: IPv4,
                         port: UInt16,
                         payload: Data,
                         timeout: TimeInterval) async -> Data? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port),
              let endpointHost = IPv4Address(host.description)
        else { return nil }

        let parameters = NWParameters.udp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: .ipv4(endpointHost), port: endpointPort, using: parameters)

        return await withCheckedContinuation { continuation in
            let box = DatagramBox(continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .idempotent)
                    connection.receiveMessage { data, _, _, _ in
                        box.finish(data)
                        connection.cancel()
                    }
                case .failed, .cancelled:
                    box.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                box.finish(nil)
                connection.cancel()
            }
        }
    }
}

/// Guarantees the continuation is resumed exactly once, whichever callback wins.
nonisolated private final class DatagramBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }

    func finish(_ value: Data?) {
        let pending = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
