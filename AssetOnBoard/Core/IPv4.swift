//
//  IPv4.swift
//  AssetOnBoard
//
//  Value types for IPv4 addresses and subnet arithmetic.
//

import Foundation
import Darwin

/// A 32-bit IPv4 address stored in host byte order.
///
/// Named `IPv4` rather than `IPv4Address` to avoid colliding with
/// `Network.IPv4Address` in files that import both.
nonisolated struct IPv4: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    var raw: UInt32

    init(raw: UInt32) { self.raw = raw }

    init?(_ string: String) {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        self.raw = UInt32(bigEndian: addr.s_addr)
    }

    init(networkOrder: in_addr_t) {
        self.raw = UInt32(bigEndian: networkOrder)
    }

    var networkOrder: in_addr_t { raw.bigEndian }

    var octets: [UInt8] {
        [UInt8(raw >> 24 & 0xFF), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
    }

    var description: String {
        let o = octets
        return "\(o[0]).\(o[1]).\(o[2]).\(o[3])"
    }

    static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.raw < rhs.raw }

    /// RFC 1918 / RFC 3927 ranges that indicate a private LAN.
    var isPrivate: Bool {
        let o = octets
        if o[0] == 10 { return true }
        if o[0] == 172 && (16...31).contains(o[1]) { return true }
        if o[0] == 192 && o[1] == 168 { return true }
        if o[0] == 169 && o[1] == 254 { return true }   // link-local
        return false
    }

    var isLoopback: Bool { octets[0] == 127 }

    /// The prefix length this address represents when read as a netmask, or nil
    /// when its set bits are not contiguous.
    ///
    /// A mask such as 255.0.255.0 is not a prefix at all, and counting its bits
    /// alone would quietly read it as a /16. Routers do report nonsense here,
    /// and an SNMP walk has no other way to notice.
    var netmaskPrefixLength: Int? {
        let bits = raw.nonzeroBitCount
        guard IPv4Subnet.mask(for: bits) == raw else { return nil }
        return bits
    }

    /// RFC 3927 link-local (169.254/16): a self-assigned address handed out when
    /// DHCP fails. Nothing useful lives there, so scans skip it.
    var isLinkLocal: Bool { octets[0] == 169 && octets[1] == 254 }

    var socketAddress: sockaddr_in {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = 0
        sa.sin_addr = in_addr(s_addr: networkOrder)
        return sa
    }

    // Codable as a plain dotted-quad string.
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = IPv4(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid IPv4 literal \(text)"))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// An IPv4 network expressed as a base address plus prefix length.
nonisolated struct IPv4Subnet: Hashable, Sendable, CustomStringConvertible {
    let network: IPv4
    let prefixLength: Int

    init(network: IPv4, prefixLength: Int) {
        self.prefixLength = min(max(prefixLength, 0), 32)
        self.network = IPv4(raw: network.raw & Self.mask(for: self.prefixLength))
    }

    /// Builds the subnet containing `address` given a dotted-quad netmask.
    init(address: IPv4, netmask: IPv4) {
        self.init(network: address, prefixLength: netmask.raw.nonzeroBitCount)
    }

    /// The same, but refusing a mask whose bits are not contiguous.
    ///
    /// Used for masks that came off the wire rather than out of the kernel: a
    /// router is free to report 255.0.255.0, and silently treating that as a
    /// /16 would aim a sweep at 65k addresses of nothing.
    init?(address: IPv4, validating netmask: IPv4) {
        guard let prefix = netmask.netmaskPrefixLength else { return nil }
        self.init(network: address, prefixLength: prefix)
    }

    static func mask(for prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
    }

    var netmask: IPv4 { IPv4(raw: Self.mask(for: prefixLength)) }
    var broadcast: IPv4 { IPv4(raw: network.raw | ~Self.mask(for: prefixLength)) }

    /// Total addressable hosts, excluding network and broadcast addresses.
    var hostCount: Int {
        guard prefixLength < 31 else { return prefixLength == 32 ? 1 : 2 }
        return Int(pow(2.0, Double(32 - prefixLength))) - 2
    }

    func contains(_ address: IPv4) -> Bool {
        address.raw & Self.mask(for: prefixLength) == network.raw
    }

    /// Every usable host address in the subnet, in ascending order.
    var hostAddresses: [IPv4] {
        guard prefixLength < 31 else {
            return prefixLength == 32 ? [network] : [network, broadcast]
        }
        let first = network.raw &+ 1
        let last = broadcast.raw &- 1
        guard first <= last else { return [] }
        return (first...last).map { IPv4(raw: $0) }
    }

    /// The conventional router address (`x.x.x.1`) for this subnet.
    var likelyGateway: IPv4? {
        guard prefixLength < 31 else { return nil }
        return IPv4(raw: network.raw &+ 1)
    }

    /// Narrows an oversized subnet to at most `limit` hosts, centred on `anchor`.
    ///
    /// Sweeping a /16 would mean 65k probes; this keeps scans bounded while still
    /// covering the neighbourhood the device actually sits in.
    func clamped(around anchor: IPv4, maxHosts limit: Int) -> IPv4Subnet {
        guard hostCount > limit else { return self }
        var prefix = prefixLength
        while prefix < 32 {
            let candidate = IPv4Subnet(network: anchor, prefixLength: prefix)
            if candidate.hostCount <= limit { return candidate }
            prefix += 1
        }
        return IPv4Subnet(network: anchor, prefixLength: 32)
    }

    var description: String { "\(network)/\(prefixLength)" }

    /// The prefix assumed for a bare address, and for any source that knows an
    /// address but not a mask.
    static let defaultPrefixLength = 24

    /// Parses "192.168.1.0/24", "192.168.1.0/255.255.255.0", or a bare address
    /// which is taken to mean /24.
    ///
    /// All three turn up in the wild: the first from anyone used to CIDR, the
    /// second from routers whose own UI writes masks that way, and the third
    /// when someone reads a LAN address off a label and wants the network
    /// around it.
    init?(cidr text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        guard let slash = trimmed.firstIndex(of: "/") else {
            guard let address = IPv4(trimmed) else { return nil }
            self.init(network: address, prefixLength: Self.defaultPrefixLength)
            return
        }

        let base = trimmed[trimmed.startIndex..<slash].trimmingCharacters(in: .whitespaces)
        guard let address = IPv4(base) else { return nil }
        let suffix = trimmed[trimmed.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty else { return nil }

        if let prefix = Int(suffix) {
            guard (0...32).contains(prefix) else { return nil }
            self.init(network: address, prefixLength: prefix)
            return
        }

        guard let netmask = IPv4(suffix) else { return nil }
        self.init(address: address, validating: netmask)
    }
}

/// A 48-bit hardware address.
nonisolated struct MACAddress: Hashable, Sendable, CustomStringConvertible, Codable {
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    init?(_ string: String) {
        let cleaned = string.replacingOccurrences(of: "-", with: ":")
            .replacingOccurrences(of: ".", with: ":")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var parsed: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part, radix: 16) else { return nil }
            parsed.append(value)
        }
        self.bytes = parsed
    }

    var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// First three octets, used for IEEE OUI vendor lookup.
    var oui: UInt32 {
        UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
    }

    /// True when the U/L bit is set, meaning the address was self-assigned.
    ///
    /// Modern phones rotate a private MAC per network, so this flag explains why
    /// a vendor lookup came back empty.
    var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }

    var isMulticast: Bool { bytes[0] & 0x01 != 0 }

    var isAllZero: Bool { bytes.allSatisfy { $0 == 0 } }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = MACAddress(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid MAC literal \(text)"))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
