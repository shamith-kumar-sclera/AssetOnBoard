//
//  NetBIOSProbe.swift
//  AssetOnBoard
//
//  NetBIOS node-status query (UDP/137).
//
//  Worth the effort because it is the one *unicast* probe that returns a MAC
//  address — no multicast entitlement, no ARP cache. Windows PCs, Samba shares,
//  NAS boxes and many printers all answer, giving back the machine name, the
//  workgroup and the adapter's hardware address in a single datagram.
//

import Foundation

nonisolated struct NetBIOSInfo: Sendable, Hashable, Codable {
    var computerName: String?
    var workgroup: String?
    var services: [String]
    var macAddress: MACAddress?
    var isDomainController: Bool
    var isMasterBrowser: Bool
}

nonisolated enum NetBIOSProbe {

    static func query(host: IPv4, timeout: TimeInterval = 1.2) async -> NetBIOSInfo? {
        let transactionID = UInt16.random(in: 0...UInt16.max)
        let request = buildNodeStatusRequest(transactionID: transactionID)

        guard let response = await UDPDatagram.exchange(with: host, port: 137, payload: request, timeout: timeout),
              response.count > 56
        else { return nil }

        return parse(response: [UInt8](response), transactionID: transactionID)
    }

    // MARK: - Request

    /// Builds an NBSTAT query for the wildcard name `*`.
    ///
    /// NetBIOS names travel in "first-level encoding": each byte becomes two
    /// nibbles offset by ASCII 'A', so a 16-byte name expands to 32 characters.
    private static func buildNodeStatusRequest(transactionID: UInt16) -> Data {
        var packet = Data()
        packet.append(UInt8(transactionID >> 8))
        packet.append(UInt8(transactionID & 0xFF))
        packet.append(contentsOf: [0x00, 0x00])   // flags: standard query
        packet.append(contentsOf: [0x00, 0x01])   // QDCOUNT = 1
        packet.append(contentsOf: [0x00, 0x00])   // ANCOUNT
        packet.append(contentsOf: [0x00, 0x00])   // NSCOUNT
        packet.append(contentsOf: [0x00, 0x00])   // ARCOUNT

        var name = [UInt8](repeating: 0x00, count: 16)
        name[0] = 0x2A                            // '*'
        packet.append(0x20)                       // encoded name length
        for byte in name {
            packet.append(0x41 + (byte >> 4))
            packet.append(0x41 + (byte & 0x0F))
        }
        packet.append(0x00)                       // root label

        packet.append(contentsOf: [0x00, 0x21])   // QTYPE = NBSTAT
        packet.append(contentsOf: [0x00, 0x01])   // QCLASS = IN
        return packet
    }

    // MARK: - Response

    private static func parse(response: [UInt8], transactionID: UInt16) -> NetBIOSInfo? {
        guard response.count > 56 else { return nil }
        guard UInt16(response[0]) << 8 | UInt16(response[1]) == transactionID else { return nil }
        let answerCount = UInt16(response[6]) << 8 | UInt16(response[7])
        guard answerCount > 0 else { return nil }

        // 12-byte header + 34-byte encoded name + type/class/TTL/RDLENGTH.
        var cursor = 12 + 34 + 2 + 2 + 4 + 2
        guard cursor < response.count else { return nil }

        let nameCount = Int(response[cursor])
        cursor += 1

        var computerName: String?
        var workgroup: String?
        var services: [String] = []
        var isDomainController = false
        var isMasterBrowser = false

        for _ in 0..<nameCount {
            guard cursor + 18 <= response.count else { break }
            let rawName = Array(response[cursor..<(cursor + 15)])
            let suffix = response[cursor + 15]
            let flags = UInt16(response[cursor + 16]) << 8 | UInt16(response[cursor + 17])
            cursor += 18

            let name = String(bytes: rawName, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { continue }

            let isGroup = flags & 0x8000 != 0
            switch (suffix, isGroup) {
            case (0x00, false): if computerName == nil { computerName = name }
            case (0x00, true): if workgroup == nil { workgroup = name }
            case (0x20, false): services.append("File Server")
            case (0x03, false): services.append("Messenger")
            case (0x1B, _): isDomainController = true; services.append("Domain Master Browser")
            case (0x1C, _): isDomainController = true
            case (0x1D, _): isMasterBrowser = true; services.append("Master Browser")
            case (0x1E, _): services.append("Browser Elections")
            case (0x06, _): services.append("RAS Server")
            case (0x21, _): services.append("RAS Client")
            default: break
            }
        }

        // The 6-byte adapter unit ID sits immediately after the name table.
        var macAddress: MACAddress?
        if cursor + 6 <= response.count {
            let candidate = MACAddress(bytes: Array(response[cursor..<(cursor + 6)]))
            if let candidate, !candidate.isAllZero { macAddress = candidate }
        }

        guard computerName != nil || workgroup != nil || macAddress != nil else { return nil }
        return NetBIOSInfo(computerName: computerName,
                           workgroup: workgroup,
                           services: Array(Set(services)).sorted(),
                           macAddress: macAddress,
                           isDomainController: isDomainController,
                           isMasterBrowser: isMasterBrowser)
    }
}
