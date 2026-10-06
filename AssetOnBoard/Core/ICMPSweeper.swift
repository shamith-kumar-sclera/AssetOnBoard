//
//  ICMPSweeper.swift
//  AssetOnBoard
//
//  Subnet-wide ICMP echo sweep over an unprivileged SOCK_DGRAM socket.
//
//  Darwin allows SOCK_DGRAM/IPPROTO_ICMP without root, which is what makes
//  pinging possible inside the iOS sandbox. Two Darwin quirks drive this code:
//  the kernel overwrites the echo identifier with the socket's implicit port,
//  so replies are matched on a payload token instead; and recvfrom() hands back
//  the whole IP packet, which conveniently exposes the reply's TTL.
//

import Foundation
import Darwin

nonisolated struct ICMPReply: Sendable {
    let address: IPv4
    /// Round-trip time derived from the timestamp echoed back in the payload.
    let roundTripTime: TimeInterval
    /// IP header TTL of the reply — a coarse but useful OS-family signal.
    let ttl: Int
}

nonisolated final class ICMPSweeper: @unchecked Sendable {

    private static let magic: [UInt8] = Array("AOB1".utf8)
    private static let payloadSize = 4 + 4 + 2 + 8   // magic + token + sequence + timestamp
    private let queue = DispatchQueue(label: "com.sclera.assetonboard.icmp", qos: .userInitiated)

    enum SweepError: Error, LocalizedError {
        case socketUnavailable(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .socketUnavailable(let code):
                "ICMP socket unavailable (errno \(code)). Ping sweep skipped."
            }
        }
    }

    /// Pings every target and returns replies keyed by responding address.
    ///
    /// - Parameters:
    ///   - rounds: how many echo requests to send per host; retries cover loss.
    ///   - timeout: how long to keep listening after the last request goes out.
    ///   - onReply: called on an arbitrary queue as each first reply arrives, so
    ///     the UI can populate while the sweep is still running.
    func sweep(targets: [IPv4],
               rounds: Int = 2,
               timeout: TimeInterval = 1.2,
               onReply: (@Sendable (ICMPReply) -> Void)? = nil) async throws -> [IPv4: ICMPReply] {
        guard !targets.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let replies = try self.runSweep(targets: targets,
                                                    rounds: rounds,
                                                    timeout: timeout,
                                                    onReply: onReply)
                    continuation.resume(returning: replies)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking implementation (runs on `queue`)

    private func runSweep(targets: [IPv4],
                          rounds: Int,
                          timeout: TimeInterval,
                          onReply: (@Sendable (ICMPReply) -> Void)?) throws -> [IPv4: ICMPReply] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw SweepError.socketUnavailable(errno: errno) }
        defer { close(fd) }

        // Short receive timeout so the read loop can re-check its deadline.
        var readTimeout = timeval(tv_sec: 0, tv_usec: 60_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
        var sendBufferSize: Int32 = 128 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBufferSize, socklen_t(MemoryLayout<Int32>.size))

        let token = UInt32.random(in: 1...UInt32.max)
        var replies: [IPv4: ICMPReply] = [:]

        for round in 0..<max(rounds, 1) {
            for (index, target) in targets.enumerated() {
                // Skip hosts that already answered an earlier round.
                if round > 0 && replies[target] != nil { continue }
                send(fd: fd, to: target, sequence: UInt16(index & 0xFFFF), token: token)

                // Drain in-flight replies periodically so the kernel buffer
                // never overflows during a large sweep.
                if index % 48 == 47 {
                    receive(fd: fd, until: Date(), token: token, into: &replies, onReply: onReply)
                }
            }
            let roundDeadline = Date().addingTimeInterval(round == rounds - 1 ? timeout : 0.35)
            receive(fd: fd, until: roundDeadline, token: token, into: &replies, onReply: onReply)
        }

        return replies
    }

    private func send(fd: Int32, to target: IPv4, sequence: UInt16, token: UInt32) {
        var packet = [UInt8](repeating: 0, count: 8 + Self.payloadSize)
        packet[0] = 8   // ICMP echo request
        packet[1] = 0   // code
        // Bytes 2-3 checksum, 4-5 identifier (kernel-assigned), 6-7 sequence.
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)

        var cursor = 8
        for byte in Self.magic { packet[cursor] = byte; cursor += 1 }
        for shift in stride(from: 24, through: 0, by: -8) {
            packet[cursor] = UInt8((token >> UInt32(shift)) & 0xFF); cursor += 1
        }
        packet[cursor] = UInt8(sequence >> 8); cursor += 1
        packet[cursor] = UInt8(sequence & 0xFF); cursor += 1
        withUnsafeBytes(of: Date().timeIntervalSince1970.bitPattern.bigEndian) { raw in
            for byte in raw { packet[cursor] = byte; cursor += 1 }
        }

        let sum = Self.checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)

        var destination = target.socketAddress
        let sent = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                packet.withUnsafeBytes { buffer in
                    sendto(fd, buffer.baseAddress, buffer.count, 0,
                           sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        // ENOBUFS means we outran the interface queue; a brief pause lets it drain.
        if sent < 0 && errno == ENOBUFS { usleep(1500) }
    }

    private func receive(fd: Int32,
                         until deadline: Date,
                         token: UInt32,
                         into replies: inout [IPv4: ICMPReply],
                         onReply: (@Sendable (ICMPReply) -> Void)?) {
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
            guard let reply = Self.parseReply(bytes: buffer,
                                              length: count,
                                              source: IPv4(networkOrder: source.sin_addr.s_addr),
                                              token: token)
            else { continue }

            if replies[reply.address] == nil {
                replies[reply.address] = reply
                onReply?(reply)
            }
        } while Date() < deadline
    }

    // MARK: - Parsing

    private static func parseReply(bytes: [UInt8], length: Int, source: IPv4, token: UInt32) -> ICMPReply? {
        var offset = 0
        var ttl = 0

        // Darwin delivers the IP header along with the ICMP payload.
        if length > 0, bytes[0] >> 4 == 4 {
            let headerLength = Int(bytes[0] & 0x0F) * 4
            guard length > headerLength, headerLength >= 20 else { return nil }
            ttl = Int(bytes[8])
            offset = headerLength
        }

        guard length >= offset + 8 + payloadSize else { return nil }
        guard bytes[offset] == 0, bytes[offset + 1] == 0 else { return nil }  // echo reply

        var cursor = offset + 8
        for expected in magic {
            guard bytes[cursor] == expected else { return nil }
            cursor += 1
        }

        var receivedToken: UInt32 = 0
        for _ in 0..<4 { receivedToken = receivedToken << 8 | UInt32(bytes[cursor]); cursor += 1 }
        guard receivedToken == token else { return nil }

        cursor += 2   // sequence, already implied by the source address

        var timestampBits: UInt64 = 0
        for _ in 0..<8 { timestampBits = timestampBits << 8 | UInt64(bytes[cursor]); cursor += 1 }
        let sentAt = Double(bitPattern: timestampBits)
        let rtt = max(Date().timeIntervalSince1970 - sentAt, 0)
        guard rtt.isFinite, rtt < 30 else { return nil }

        return ICMPReply(address: source, roundTripTime: rtt, ttl: ttl)
    }

    /// Standard 16-bit one's-complement checksum (RFC 1071).
    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum &+= UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return UInt16(truncatingIfNeeded: ~sum)
    }
}

