//
//  AccessPoint.swift
//  AssetOnBoard
//
//  Network infrastructure: the joined access point, LAN routers, upstream hops.
//

import Foundation

nonisolated enum AccessPointKind: String, Sendable, Codable, CaseIterable, Identifiable {
    /// The access point this device is associated with right now.
    case joined = "Connected Access Point"
    /// The first-hop router, confirmed by a TTL-limited probe.
    case gateway = "Default Gateway"
    /// A router or AP identified on the local subnet by the network scan.
    case localInfrastructure = "Local Router / AP"
    /// A router beyond the gateway, found by tracing the route out.
    case upstreamHop = "Upstream Hop"
    /// Access-point hardware in radio range, identified by its Bluetooth setup
    /// beacon rather than by anything on this network.
    case nearbyRadio = "Nearby Radio"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .joined: "wifi"
        case .gateway: "wifi.router.fill"
        case .localInfrastructure: "antenna.radiowaves.left.and.right"
        case .upstreamHop: "arrow.up.forward"
        case .nearbyRadio: "dot.radiowaves.up.forward"
        }
    }

    /// Ordering for display: nearest and most certain first.
    var sortRank: Int {
        switch self {
        case .joined: 0
        case .gateway: 1
        case .localInfrastructure: 2
        case .upstreamHop: 3
        case .nearbyRadio: 4
        }
    }
}

nonisolated struct AccessPoint: Identifiable, Sendable, Codable, Hashable {
    var id: String
    var kind: AccessPointKind

    var ssid: String?
    /// The access point's own hardware address, however it was obtained.
    var macAddress: MACAddress?
    var macSource: String?
    var ipAddress: IPv4?
    var vendor: String?

    var hopNumber: Int?
    var roundTripTime: TimeInterval?
    var signalStrength: Double?
    var isSecure: Bool?

    var model: String?
    var hostnames: [String] = []
    var managementServices: [String] = []
    var openPorts: [UInt16] = []
    var isPrivateAddress: Bool = true

    /// Self-description read from the device's UPnP stack.
    var upnp: SSDPDescription?

    // Set only for `.nearbyRadio`, where identity comes from a BLE advertisement.
    /// CoreBluetooth's per-app identifier for the advertising peripheral.
    var bluetoothIdentifier: UUID?
    var rssi: Int?
    /// What gave this away as an access point, and how far to trust it.
    var detectionEvidence: String?
    var detectionConfidence: Double?

    var displayName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        if let name = upnp?.displayName, !name.isEmpty { return name }
        if let hostname = hostnames.first { return NameResolution.shortName(hostname) }
        if let model { return model }
        if let vendor { return "\(vendor) \(kind == .joined ? "access point" : "router")" }
        if let ipAddress { return ipAddress.description }
        return kind.rawValue
    }

    var subtitle: String {
        var parts: [String] = []
        if kind != .joined || ssid == nil { parts.append(kind.rawValue) }
        if let vendor { parts.append(vendor) }
        if let hop = hopNumber, kind == .upstreamHop { parts.append("hop \(hop)") }
        if kind == .nearbyRadio, let rssi { parts.append("\(rssi) dBm") }
        if !managementServices.isEmpty { parts.append(managementServices.joined(separator: ", ")) }
        if parts.isEmpty { parts.append(ipAddress?.description ?? "Infrastructure") }
        return parts.joined(separator: " · ")
    }

    /// True when this entry describes hardware that is not on our subnet.
    ///
    /// The UI leans on this to keep the promise the app makes about what it can
    /// and cannot see: a nearby radio was never scanned, only overheard.
    var isRadioOnly: Bool { kind == .nearbyRadio }
}

/// Vendors whose presence on a network strongly implies routing or Wi-Fi gear.
nonisolated enum InfrastructureVendors {
    private static let names: Set<String> = [
        "ubiquiti", "mikrotik", "cisco", "cisco-linksys", "cisco meraki", "aruba networks",
        "juniper networks", "fortinet", "palo alto networks", "netgear", "tp-link", "d-link",
        "zyxel", "edimax", "arcadyan", "sagemcom", "technicolor", "arris", "belkin",
        "asustek", "draytek", "ruckus", "extreme networks", "engenius", "tenda"
    ]

    static func isInfrastructure(_ vendor: String?) -> Bool {
        guard let vendor = vendor?.lowercased() else { return false }
        return names.contains { vendor.contains($0) }
    }

    /// Management interfaces that identify a specific platform.
    static func managementService(forPort port: UInt16) -> String? {
        switch port {
        case 8291: "MikroTik Winbox"
        case 8443: "UniFi Controller"
        case 10001: "Ubiquiti Discovery"
        case 4343: "Aruba Web UI"
        case 1900: "UPnP / SSDP"
        case 5000: "Router Web UI"
        case 53: "DNS Resolver"
        case 67, 68: "DHCP"
        default: nil
        }
    }
}
