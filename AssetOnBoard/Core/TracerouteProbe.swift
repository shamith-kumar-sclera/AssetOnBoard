//
//  TracerouteProbe.swift
//  AssetOnBoard
//
//  Walks the route out of the network, one hop at a time.
//
//  Generalises the trick GatewayDiscovery uses for the first hop: send an echo
//  request with IP_TTL set to N and the Nth router on the path must discard it
//  and answer "time exceeded" from its own address. Repeating for N = 1, 2, 3…
//  enumerates every router between this device and the internet — which is how
//  the app finds infrastructure that sits beyond the local subnet and therefore
//  never appears in a subnet sweep.
//

import Foundation
import Darwin

nonisolated struct RouteHop: Identifiable, Sendable, Hashable {
    let hopNumber: Int
    let address: IPv4?
    let roundTripTime: TimeInterval?
    /// True once a hop answers with an echo reply rather than time-exceeded,
    /// meaning the probe reached its destination and the trace is finished.
    let isDestination: Bool

    var id: Int { hopNumber }
    var timedOut: Bool { address == nil }
}

nonisolated enum TracerouteProbe {

    private static let queue = DispatchQueue(label: "com.sclera.assetonboard.traceroute",
                                             qos: .userInitiated)

    /// Traces the path towards `target`, reporting each hop as it resolves.
    static func trace(to target: IPv4 = IPv4("8.8.8.8")!,
                      maxHops: Int = 12,
                      timeout: TimeInterval = 1.2,
                      onHop: (@Sendable (RouteHop) -> Void)? = nil) async -> [RouteHop] {
        await withCheckedContinuation { continuation in
            let box = TraceBox(continuation)
            queue.async {
                var hops: [RouteHop] = []
                for ttl in 1...max(1, maxHops) {
                    if Task.isCancelled { break }
                    let hop = probe(target: target, ttl: ttl, timeout: timeout)
                    hops.append(hop)
                    onHop?(hop)
                    // Stop at the destination, or after three silent hops in a
                    // row — past that point the remaining routers are simply
                    // configured not to answer.
                    if hop.isDestination { break }
                    if hops.suffix(3).count == 3 && hops.suffix(3).allSatisfy(\.timedOut) { break }
                }
                box.finish(hops)
            }
        }
    }

    private static func probe(target: IPv4, ttl: Int, timeout: TimeInterval) -> RouteHop {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            return RouteHop(hopNumber: ttl, address: nil, roundTripTime: nil, isDestination: false)
        }
        defer { close(fd) }

        var hopLimit = Int32(ttl)
        guard setsockopt(fd, IPPROTO_IP, IP_TTL, &hopLimit, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            return RouteHop(hopNumber: ttl, address: nil, roundTripTime: nil, isDestination: false)
        }
        var readTimeout = timeval(tv_sec: 0, tv_usec: 80_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        let sequence = UInt16.random(in: 1...UInt16.max)
        let sentAt = Date()
        guard send(fd: fd, to: target, sequence: sequence) else {
            return RouteHop(hopNumber: ttl, address: nil, roundTripTime: nil, isDestination: false)
        }

        let deadline = sentAt.addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 1500)

        repeat {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(fd, &buffer, buffer.count, 0, sockaddrPointer, &sourceLength)
                }
            }
            guard count > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            guard let kind = classify(bytes: buffer, length: count, sequence: sequence) else { continue }
            return RouteHop(hopNumber: ttl,
                            address: IPv4(networkOrder: source.sin_addr.s_addr),
                            roundTripTime: Date().timeIntervalSince(sentAt),
                            isDestination: kind == .echoReply)
        } while Date() < deadline

        return RouteHop(hopNumber: ttl, address: nil, roundTripTime: nil, isDestination: false)
    }

    private enum ReplyKind { case timeExceeded, echoReply }

    /// Accepts either a time-exceeded error quoting our probe, or an echo reply
    /// carrying our sequence number — the latter means we reached the target.
    private static func classify(bytes: [UInt8], length: Int, sequence: UInt16) -> ReplyKind? {
        guard length > 0, bytes[0] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[0] & 0x0F) * 4
        guard headerLength >= 20, length >= headerLength + 8 else { return nil }

        let type = bytes[headerLength]
        if type == 0 {
            let echoed = UInt16(bytes[headerLength + 6]) << 8 | UInt16(bytes[headerLength + 7])
            return echoed == sequence ? .echoReply : nil
        }
        guard type == 11 || type == 3 else { return nil }

        // Time-exceeded and unreachable quote the original header plus 8 bytes.
        let quoted = headerLength + 8
        guard length > quoted, bytes[quoted] >> 4 == 4 else { return nil }
        let quotedHeaderLength = Int(bytes[quoted] & 0x0F) * 4
        let quotedICMP = quoted + quotedHeaderLength
        guard length >= quotedICMP + 8 else { return nil }

        let echoed = UInt16(bytes[quotedICMP + 6]) << 8 | UInt16(bytes[quotedICMP + 7])
        return echoed == sequence ? .timeExceeded : nil
    }

    private static func send(fd: Int32, to target: IPv4, sequence: UInt16) -> Bool {
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)

        var sum: UInt32 = 0
        var index = 0
        while index + 1 < packet.count {
            sum &+= UInt32(packet[index]) << 8 | UInt32(packet[index + 1])
            index += 2
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        let checksum = UInt16(truncatingIfNeeded: ~sum)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xFF)

        var destination = target.socketAddress
        let sent = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                packet.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, raw.count, 0,
                           sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent > 0
    }
}

nonisolated private final class TraceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[RouteHop], Never>?
    init(_ continuation: CheckedContinuation<[RouteHop], Never>) { self.continuation = continuation }
    func finish(_ value: [RouteHop]) {
        let pending = lock.withLock { () -> CheckedContinuation<[RouteHop], Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
