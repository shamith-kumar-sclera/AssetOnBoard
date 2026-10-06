//
//  GatewayDiscovery.swift
//  AssetOnBoard
//
//  Finds the real default gateway with a single-hop ICMP probe.
//
//  Assuming the router lives at x.x.x.1 is a guess that quietly fails: plenty of
//  networks put a workstation there. Instead this sends one echo request with
//  IP_TTL = 1 to an off-subnet address. The first router to handle it decrements
//  the TTL to zero, drops it, and answers "time exceeded" from its own address —
//  so the source of that reply *is* the gateway. The probe never leaves the LAN,
//  and the routing sysctl that would normally answer this is blocked on iOS.
//

import Foundation
import Darwin

nonisolated enum GatewayDiscovery {

    private static let queue = DispatchQueue(label: "com.sclera.assetonboard.gateway", qos: .userInitiated)

    /// An address outside any private subnet, used only as a direction to aim at.
    /// With a TTL of 1 the packet dies at the first hop and never reaches it.
    private static let offSubnetTarget = IPv4("8.8.8.8")!

    /// Returns the first-hop router, or nil if nothing answered in time.
    static func discover(timeout: TimeInterval = 1.5) async -> IPv4? {
        await withCheckedContinuation { continuation in
            let box = GatewayBox(continuation)
            queue.async {
                box.finish(probeFirstHop(timeout: timeout))
            }
            queue.asyncAfter(deadline: .now() + timeout + 0.5) { box.finish(nil) }
        }
    }

    private static func probeFirstHop(timeout: TimeInterval) -> IPv4? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var hopLimit: Int32 = 1
        guard setsockopt(fd, IPPROTO_IP, IP_TTL, &hopLimit, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { return nil }

        var readTimeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        let sequence = UInt16.random(in: 1...UInt16.max)
        guard send(fd: fd, sequence: sequence) else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
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
                return nil
            }
            if matchesOurProbe(bytes: buffer, length: count, sequence: sequence) {
                return IPv4(networkOrder: source.sin_addr.s_addr)
            }
        } while Date() < deadline

        return nil
    }

    private static func send(fd: Int32, sequence: UInt16) -> Bool {
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8   // echo request
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

        var destination = offSubnetTarget.socketAddress
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

    /// Confirms an ICMP error refers to the probe we just sent.
    ///
    /// Time-exceeded and unreachable messages quote the original IP header plus
    /// the first eight bytes of its payload, so the echoed sequence number
    /// identifies our packet even though the kernel rewrote the identifier.
    private static func matchesOurProbe(bytes: [UInt8], length: Int, sequence: UInt16) -> Bool {
        guard length > 0, bytes[0] >> 4 == 4 else { return false }
        let headerLength = Int(bytes[0] & 0x0F) * 4
        guard headerLength >= 20, length >= headerLength + 8 else { return false }

        let type = bytes[headerLength]
        // 11 = time exceeded (the expected answer), 3 = destination unreachable
        // (some routers reply this way instead; either identifies the first hop).
        guard type == 11 || type == 3 else { return false }

        let quotedStart = headerLength + 8
        guard length > quotedStart, bytes[quotedStart] >> 4 == 4 else { return false }
        let quotedHeaderLength = Int(bytes[quotedStart] & 0x0F) * 4
        let quotedICMP = quotedStart + quotedHeaderLength
        guard length >= quotedICMP + 8 else { return false }

        let echoedSequence = UInt16(bytes[quotedICMP + 6]) << 8 | UInt16(bytes[quotedICMP + 7])
        return echoedSequence == sequence
    }
}

nonisolated private final class GatewayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IPv4?, Never>?
    init(_ continuation: CheckedContinuation<IPv4?, Never>) { self.continuation = continuation }
    func finish(_ value: IPv4?) {
        let pending = lock.withLock { () -> CheckedContinuation<IPv4?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
