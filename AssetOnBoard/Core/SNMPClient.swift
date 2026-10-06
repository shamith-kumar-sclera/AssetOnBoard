//
//  SNMPClient.swift
//  AssetOnBoard
//
//  SNMPv2c client for reading a router's ARP table.
//
//  The router is the one device that legitimately knows every IP-to-MAC binding
//  on the subnet, and `ipNetToMediaPhysAddress` (1.3.6.1.2.1.4.22.1.2) is exactly
//  that table. One GETBULK walk over UDP/161 returns the whole mapping, which is
//  the only way to obtain MAC addresses for hosts that answer neither mDNS nor
//  NetBIOS while iOS keeps the local ARP cache out of reach.
//
//  Read-only: this issues GETBULK requests and never writes to the device.
//

import Foundation

nonisolated struct SNMPResult: Sendable {
    /// IP-to-MAC bindings harvested from the router's ARP table.
    var arpTable: [IPv4: MACAddress] = [:]
    /// The community string that worked, for display.
    var community: String = ""
    var systemDescription: String?
    var systemName: String?
}

/// The networks a router knows about, read from its own tables.
///
/// This is the authoritative answer to "what subnets exist here?". Everything
/// else — traceroute hops, probing likely gateways — is inference; the router
/// simply knows.
nonisolated struct SNMPTopology: Sendable {
    /// Networks the router is directly attached to, each with the router's own
    /// address on that network. These are the only subnets in a scan that carry
    /// a mask somebody actually reported rather than one we assumed.
    var connectedSubnets: [(subnet: IPv4Subnet, address: IPv4)] = []
    /// Networks it holds routes for, default and host routes excluded.
    var routedSubnets: [IPv4Subnet] = []

    var allSubnets: [IPv4Subnet] {
        var seen = Set<IPv4Subnet>()
        return (connectedSubnets.map(\.subnet) + routedSubnets).filter { seen.insert($0).inserted }
    }
}

nonisolated enum SNMPClient {

    /// ipNetToMediaPhysAddress — the ARP table, keyed by interface and IP.
    private static let arpTableOID: [UInt32] = [1, 3, 6, 1, 2, 1, 4, 22, 1, 2]
    /// ipAdEntNetMask — the router's own addresses, each row *indexed by* the
    /// address it describes. Walking this one table yields both halves, which is
    /// why there is no companion walk of ipAdEntAddr.
    private static let ipMaskOID: [UInt32] = [1, 3, 6, 1, 2, 1, 4, 20, 1, 3]
    /// ipCidrRouteIfIndex — the modern forwarding table, indexed by
    /// dest(4) . mask(4) . tos . nextHop(4). Everything needed is in the index.
    private static let cidrRouteOID: [UInt32] = [1, 3, 6, 1, 2, 1, 4, 24, 4, 1, 5]
    /// ipRouteMask — the deprecated table, indexed by destination with the mask
    /// as its value. Kept because some agents populate only this one, and
    /// consulted second because plenty of modern agents leave it empty.
    private static let legacyRouteMaskOID: [UInt32] = [1, 3, 6, 1, 2, 1, 4, 21, 1, 11]
    /// sysDescr.0 and sysName.0 — free identity information while we are here.
    private static let sysDescrOID: [UInt32] = [1, 3, 6, 1, 2, 1, 1, 1, 0]
    private static let sysNameOID: [UInt32] = [1, 3, 6, 1, 2, 1, 1, 5, 0]

    /// Walks the router's ARP table, trying each community in turn.
    ///
    /// Returns nil when SNMP is disabled or no community is accepted, which is
    /// the common case on consumer routers.
    static func readARPTable(from router: IPv4,
                             communities: [String],
                             timeout: TimeInterval = 1.5) async -> SNMPResult? {
        for community in communities where !community.isEmpty {
            guard let identity = await get(oids: [sysDescrOID, sysNameOID],
                                           from: router,
                                           community: community,
                                           timeout: timeout)
            else { continue }

            var result = SNMPResult(community: community)
            result.systemDescription = identity.first(where: { $0.oid.starts(with: Array(sysDescrOID.dropLast())) })?.stringValue
            result.systemName = identity.first(where: { $0.oid.starts(with: Array(sysNameOID.dropLast())) })?.stringValue
            result.arpTable = await walkARP(from: router, community: community, timeout: timeout)
            return result
        }
        return nil
    }

    /// Asks the router which networks it knows about.
    static func readTopology(from router: IPv4,
                             communities: [String],
                             timeout: TimeInterval = 1.5) async -> SNMPTopology? {
        for community in communities where !community.isEmpty {
            // One cheap GET first, so an unreachable or closed agent costs a
            // single datagram rather than four table walks.
            guard await get(oids: [sysNameOID], from: router,
                            community: community, timeout: timeout) != nil
            else { continue }

            var topology = SNMPTopology()
            topology.connectedSubnets = await connectedSubnets(from: router,
                                                               community: community,
                                                               timeout: timeout)
            topology.routedSubnets = await routedSubnets(from: router,
                                                         community: community,
                                                         timeout: timeout)
            return topology
        }
        return nil
    }

    /// The router's own legs, read from ipAdEntNetMask.
    ///
    /// Each row is indexed by the address it belongs to, so the index carries
    /// the address and the value carries its mask — one walk, and the two
    /// halves cannot be mispaired.
    private static func connectedSubnets(from router: IPv4,
                                         community: String,
                                         timeout: TimeInterval) async -> [(subnet: IPv4Subnet, address: IPv4)] {
        var results: [(subnet: IPv4Subnet, address: IPv4)] = []
        var seen = Set<IPv4Subnet>()

        let rows = await walkTable(base: ipMaskOID, from: router,
                                   community: community, timeout: timeout)
        for (suffix, value) in rows {
            guard suffix.count >= 4,
                  let address = ipv4(fromArcs: Array(suffix.suffix(4))),
                  let mask = ipv4(from: value),
                  mask.raw != 0,
                  address.isPrivate, !address.isLoopback,
                  let subnet = IPv4Subnet(address: address, validating: mask)
            else { continue }
            if seen.insert(subnet).inserted { results.append((subnet, address)) }
        }
        return results.sorted { $0.address < $1.address }
    }

    /// Networks the router forwards to but is not attached to.
    private static func routedSubnets(from router: IPv4,
                                      community: String,
                                      timeout: TimeInterval) async -> [IPv4Subnet] {
        var results: [IPv4Subnet] = []
        var seen = Set<IPv4Subnet>()

        func add(destination: IPv4, mask: IPv4) {
            // 0.0.0.0/0 is the default route and /32 is a host route; neither
            // describes a network worth sweeping.
            guard mask.raw != 0, destination.raw != 0, mask.raw != ~UInt32(0),
                  destination.isPrivate,
                  let subnet = IPv4Subnet(address: destination, validating: mask)
            else { return }
            if seen.insert(subnet).inserted { results.append(subnet) }
        }

        // Destination and mask are both arcs of the row's index here.
        let cidrRows = await walkTable(base: cidrRouteOID, from: router,
                                       community: community, timeout: timeout)
        for suffix in cidrRows.keys {
            guard suffix.count >= 9,
                  let destination = ipv4(fromArcs: Array(suffix.prefix(4))),
                  let mask = ipv4(fromArcs: Array(suffix.dropFirst(4).prefix(4)))
            else { continue }
            add(destination: destination, mask: mask)
        }
        guard results.isEmpty else { return results }

        let legacyRows = await walkTable(base: legacyRouteMaskOID, from: router,
                                         community: community, timeout: timeout)
        for (suffix, value) in legacyRows {
            guard suffix.count >= 4,
                  let destination = ipv4(fromArcs: Array(suffix.suffix(4))),
                  let mask = ipv4(from: value)
            else { continue }
            add(destination: destination, mask: mask)
        }
        return results
    }

    private static func ipv4(from bytes: [UInt8]) -> IPv4? {
        guard bytes.count == 4 else { return nil }
        return IPv4(raw: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                    | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    /// Reads four OID arcs as an address, rejecting anything that is not one.
    private static func ipv4(fromArcs arcs: [UInt32]) -> IPv4? {
        guard arcs.count == 4, arcs.allSatisfy({ $0 <= 255 }) else { return nil }
        return IPv4(raw: arcs[0] << 24 | arcs[1] << 16 | arcs[2] << 8 | arcs[3])
    }

    /// Generic table walk, keyed by the OID arcs that follow `base`.
    private static func walkTable(base: [UInt32],
                                  from router: IPv4,
                                  community: String,
                                  timeout: TimeInterval) async -> [[UInt32]: [UInt8]] {
        var rows: [[UInt32]: [UInt8]] = [:]
        var cursor = base

        for _ in 0..<32 {
            guard let varbinds = await getBulk(startingAt: cursor, from: router,
                                               community: community, timeout: timeout),
                  !varbinds.isEmpty
            else { break }

            var advanced = false
            for varbind in varbinds {
                guard varbind.oid.starts(with: base) else { return rows }
                let suffix = Array(varbind.oid.dropFirst(base.count))
                if let value = varbind.dataValue, !suffix.isEmpty { rows[suffix] = value }
                cursor = varbind.oid
                advanced = true
            }
            guard advanced else { break }
        }
        return rows
    }

    // MARK: - Walk

    private static func walkARP(from router: IPv4,
                                community: String,
                                timeout: TimeInterval) async -> [IPv4: MACAddress] {
        var bindings: [IPv4: MACAddress] = [:]
        var cursor = arpTableOID
        // Bounded so a misbehaving agent cannot loop forever.
        for _ in 0..<64 {
            guard let varbinds = await getBulk(startingAt: cursor,
                                               from: router,
                                               community: community,
                                               timeout: timeout),
                  !varbinds.isEmpty
            else { break }

            var advanced = false
            for varbind in varbinds {
                guard varbind.oid.starts(with: arpTableOID) else { return bindings }
                // Trailing arcs are <ifIndex>.<a>.<b>.<c>.<d>.
                let suffix = varbind.oid.dropFirst(arpTableOID.count)
                guard suffix.count >= 5 else { continue }
                let octets = suffix.suffix(4).map { UInt8(truncatingIfNeeded: $0) }
                let address = IPv4(raw: UInt32(octets[0]) << 24 | UInt32(octets[1]) << 16
                                   | UInt32(octets[2]) << 8 | UInt32(octets[3]))

                if let bytes = varbind.dataValue, bytes.count == 6,
                   let mac = MACAddress(bytes: bytes), !mac.isAllZero, !mac.isMulticast {
                    bindings[address] = mac
                }
                cursor = varbind.oid
                advanced = true
            }
            guard advanced else { break }
        }
        return bindings
    }

    // MARK: - Requests

    private struct VarBind {
        let oid: [UInt32]
        let dataValue: [UInt8]?
        let stringValue: String?
    }

    private static func get(oids: [[UInt32]],
                            from host: IPv4,
                            community: String,
                            timeout: TimeInterval) async -> [VarBind]? {
        let requestID = Int32.random(in: 1...Int32.max)
        let pdu = encodeSequence(tag: 0xA0, contents:                 // GetRequest
            encodeInteger(Int(requestID)) + encodeInteger(0) + encodeInteger(0)
            + encodeSequence(tag: 0x30, contents: oids.flatMap { encodeVarBind($0) }))
        return await exchange(message: encodeMessage(community: community, pdu: pdu),
                              with: host, timeout: timeout)
    }

    private static func getBulk(startingAt oid: [UInt32],
                                from host: IPv4,
                                community: String,
                                timeout: TimeInterval) async -> [VarBind]? {
        let requestID = Int32.random(in: 1...Int32.max)
        let pdu = encodeSequence(tag: 0xA5, contents:                 // GetBulkRequest
            encodeInteger(Int(requestID))
            + encodeInteger(0)      // non-repeaters
            + encodeInteger(24)     // max-repetitions
            + encodeSequence(tag: 0x30, contents: encodeVarBind(oid)))
        return await exchange(message: encodeMessage(community: community, pdu: pdu),
                              with: host, timeout: timeout)
    }

    private static func exchange(message: [UInt8],
                                 with host: IPv4,
                                 timeout: TimeInterval) async -> [VarBind]? {
        guard let response = await UDPDatagram.exchange(with: host,
                                                        port: 161,
                                                        payload: Data(message),
                                                        timeout: timeout)
        else { return nil }
        return decode(response: [UInt8](response))
    }

    // MARK: - BER encoding

    private static func encodeMessage(community: String, pdu: [UInt8]) -> [UInt8] {
        encodeSequence(tag: 0x30, contents:
            encodeInteger(1)                                   // version 1 == SNMPv2c
            + encodeOctetString(Array(community.utf8))
            + pdu)
    }

    private static func encodeLength(_ length: Int) -> [UInt8] {
        guard length >= 0x80 else { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func encodeSequence(tag: UInt8, contents: [UInt8]) -> [UInt8] {
        [tag] + encodeLength(contents.count) + contents
    }

    private static func encodeInteger(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining != 0 && remaining != -1
        // Clear the sign bit so a positive value is never read as negative.
        if let first = bytes.first, first & 0x80 != 0, value >= 0 { bytes.insert(0, at: 0) }
        return [0x02] + encodeLength(bytes.count) + bytes
    }

    private static func encodeOctetString(_ bytes: [UInt8]) -> [UInt8] {
        [0x04] + encodeLength(bytes.count) + bytes
    }

    private static func encodeOID(_ arcs: [UInt32]) -> [UInt8] {
        guard arcs.count >= 2 else { return [0x06, 0x00] }
        // The first two arcs share one byte: 40 * first + second.
        var body: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunks: [UInt8] = [UInt8(arc & 0x7F)]
            var remaining = arc >> 7
            while remaining > 0 {
                chunks.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
                remaining >>= 7
            }
            body.append(contentsOf: chunks)
        }
        return [0x06] + encodeLength(body.count) + body
    }

    private static func encodeVarBind(_ oid: [UInt32]) -> [UInt8] {
        encodeSequence(tag: 0x30, contents: encodeOID(oid) + [0x05, 0x00])   // value = NULL
    }

    // MARK: - BER decoding

    private struct Element {
        let tag: UInt8
        let range: Range<Int>
    }

    private static func elements(in bytes: [UInt8], range: Range<Int>) -> [Element] {
        var results: [Element] = []
        var index = range.lowerBound

        while index + 1 < range.upperBound {
            let tag = bytes[index]
            var cursor = index + 1
            var length = 0

            let first = bytes[cursor]
            cursor += 1
            if first & 0x80 == 0 {
                length = Int(first)
            } else {
                let byteCount = Int(first & 0x7F)
                guard byteCount > 0, byteCount <= 4, cursor + byteCount <= range.upperBound else { break }
                for _ in 0..<byteCount {
                    length = length << 8 | Int(bytes[cursor])
                    cursor += 1
                }
            }
            guard cursor + length <= range.upperBound else { break }
            results.append(Element(tag: tag, range: cursor..<(cursor + length)))
            index = cursor + length
        }
        return results
    }

    private static func decode(response bytes: [UInt8]) -> [VarBind]? {
        guard let message = elements(in: bytes, range: 0..<bytes.count).first, message.tag == 0x30
        else { return nil }

        let top = elements(in: bytes, range: message.range)
        // version, community, then the response PDU tagged [2].
        guard let pdu = top.first(where: { $0.tag == 0xA2 }) else { return nil }

        let fields = elements(in: bytes, range: pdu.range)
        guard fields.count >= 4 else { return nil }
        // fields[1] is error-status; anything non-zero means no usable varbinds.
        guard decodeInteger(bytes, fields[1].range) == 0 else { return nil }

        return elements(in: bytes, range: fields[3].range).compactMap { entry in
            let pair = elements(in: bytes, range: entry.range)
            guard pair.count >= 2, pair[0].tag == 0x06 else { return nil }
            let oid = decodeOID(bytes, pair[0].range)
            guard !oid.isEmpty else { return nil }

            let value = pair[1]
            // 0x80/0x81/0x82 are noSuchObject / noSuchInstance / endOfMibView.
            guard value.tag != 0x80, value.tag != 0x81, value.tag != 0x82 else {
                return VarBind(oid: oid, dataValue: nil, stringValue: nil)
            }
            let raw = Array(bytes[value.range])
            return VarBind(oid: oid,
                           dataValue: raw,
                           stringValue: value.tag == 0x04 ? String(bytes: raw, encoding: .utf8) : nil)
        }
    }

    private static func decodeInteger(_ bytes: [UInt8], _ range: Range<Int>) -> Int {
        var value = 0
        for index in range { value = value << 8 | Int(bytes[index]) }
        return value
    }

    private static func decodeOID(_ bytes: [UInt8], _ range: Range<Int>) -> [UInt32] {
        guard let first = range.first else { return [] }
        var arcs: [UInt32] = [UInt32(bytes[first]) / 40, UInt32(bytes[first]) % 40]
        var accumulator: UInt32 = 0

        for index in range.dropFirst() {
            let byte = bytes[index]
            accumulator = accumulator << 7 | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 {
                arcs.append(accumulator)
                accumulator = 0
            }
        }
        return arcs
    }
}
