//
//  ARPTable.swift
//  AssetOnBoard
//
//  Best-effort read of the kernel ARP cache via sysctl(PF_ROUTE).
//
//  This is the classic way to map IP -> MAC, and it still works in the
//  Simulator. On a real device recent iOS releases usually refuse the routing
//  sysctl outright, so treat a result as a bonus rather than a dependency —
//  mDNS and NetBIOS remain the reliable MAC sources on-device.
//

import Foundation
import Darwin

nonisolated enum ARPTable {

    /// Returns whatever IP-to-MAC bindings the kernel is willing to share.
    static func current() -> [IPv4: MACAddress] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, 0x400 /* RTF_LLINFO */]
        var neededBytes = 0

        guard sysctl(&mib, u_int(mib.count), nil, &neededBytes, nil, 0) == 0, neededBytes > 0
        else { return [:] }

        var buffer = [UInt8](repeating: 0, count: neededBytes)
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &neededBytes, nil, 0)
        }
        guard status == 0 else { return [:] }

        return parse(buffer: buffer, length: neededBytes)
    }

    /// `struct rt_msghdr` is not vended by the iOS SDK, so the layout is spelled
    /// out here: 36 bytes of header fields followed by a 56-byte `rt_metrics`.
    private static let routeHeaderSize = 92
    private static let routeMessageVersion: UInt8 = 5
    private static let rtaDestination = 0x1
    private static let rtaGateway = 0x2

    /// Walks the packed route-message stream returned by the routing sysctl.
    private static func parse(buffer: [UInt8], length: Int) -> [IPv4: MACAddress] {
        var results: [IPv4: MACAddress] = [:]
        let headerSize = routeHeaderSize
        var offset = 0

        while offset + headerSize <= length {
            let messageLength = Int(UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8)
            guard messageLength >= headerSize, offset + messageLength <= length else { break }
            guard buffer[offset + 2] == routeMessageVersion else {
                offset += messageLength
                continue
            }

            // Only entries carrying both a destination and a gateway can yield a
            // binding; the sockaddrs appear in that order right after the header.
            let addressFlags = Int(UInt32(buffer[offset + 12])
                                   | UInt32(buffer[offset + 13]) << 8
                                   | UInt32(buffer[offset + 14]) << 16
                                   | UInt32(buffer[offset + 15]) << 24)
            guard addressFlags & rtaDestination != 0, addressFlags & rtaGateway != 0 else {
                offset += messageLength
                continue
            }

            var cursor = offset + headerSize
            guard cursor + 8 <= length else { break }

            let destinationLength = Int(buffer[cursor])
            let family = buffer[cursor + 1]
            guard destinationLength >= 8, family == UInt8(AF_INET) else {
                offset += messageLength
                continue
            }
            let address = IPv4(raw: UInt32(buffer[cursor + 4]) << 24
                               | UInt32(buffer[cursor + 5]) << 16
                               | UInt32(buffer[cursor + 6]) << 8
                               | UInt32(buffer[cursor + 7]))

            cursor += roundUp(destinationLength)
            guard cursor + 8 <= length else { break }

            let linkLength = Int(buffer[cursor])
            let nameLength = Int(buffer[cursor + 5])
            let addressLength = Int(buffer[cursor + 6])
            let macStart = cursor + 8 + nameLength

            if addressLength == 6, linkLength >= 8, macStart + 6 <= length,
               let mac = MACAddress(bytes: Array(buffer[macStart..<(macStart + 6)])),
               !mac.isAllZero, !mac.isMulticast {
                results[address] = mac
            }

            offset += messageLength
        }
        return results
    }

    /// Routing sockaddrs are padded to 4-byte boundaries; zero length means 4.
    private static func roundUp(_ length: Int) -> Int {
        length == 0 ? 4 : (length + 3) & ~3
    }
}
