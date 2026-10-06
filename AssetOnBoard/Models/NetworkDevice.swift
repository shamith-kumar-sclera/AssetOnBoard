//
//  NetworkDevice.swift
//  AssetOnBoard
//
//  The merged picture of one host, assembled from every probe that saw it.
//

import Foundation

nonisolated enum DiscoveryMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case icmp = "ICMP ping"
    case tcp = "TCP probe"
    case bonjour = "Bonjour / mDNS"
    case arp = "ARP cache"
    case netbios = "NetBIOS"
    case reverseDNS = "Reverse DNS"
    case snmp = "Router SNMP"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .icmp: "waveform.path.ecg"
        case .tcp: "app.connected.to.app.below.fill"
        case .bonjour: "dot.radiowaves.left.and.right"
        case .arp: "tablecells"
        case .netbios: "pc"
        case .reverseDNS: "character.book.closed"
        case .snmp: "wifi.router"
        }
    }
}

nonisolated enum DeviceCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case router = "Router / Gateway"
    case accessPoint = "Access Point"
    case computer = "Computer"
    case phone = "Phone"
    case tablet = "Tablet"
    case tv = "TV / Streaming"
    case speaker = "Speaker"
    case printer = "Printer"
    case camera = "Camera"
    case nas = "Network Storage"
    case gameConsole = "Game Console"
    case smartHome = "Smart Home"
    case server = "Server"
    case virtualMachine = "Virtual Machine"
    case wearable = "Wearable"
    case unknown = "Unidentified"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .router: "wifi.router.fill"
        case .accessPoint: "antenna.radiowaves.left.and.right"
        case .computer: "desktopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .tv: "tv"
        case .speaker: "hifispeaker.fill"
        case .printer: "printer.fill"
        case .camera: "web.camera.fill"
        case .nas: "externaldrive.connected.to.line.below.fill"
        case .gameConsole: "gamecontroller.fill"
        case .smartHome: "lightbulb.fill"
        case .server: "server.rack"
        case .virtualMachine: "cube.transparent"
        case .wearable: "applewatch"
        case .unknown: "questionmark.circle"
        }
    }
}

nonisolated struct NetworkDevice: Identifiable, Sendable, Codable, Hashable {
    var ip: IPv4
    var macAddress: MACAddress?
    var vendor: String?
    var hostnames: [String] = []
    var netbios: NetBIOSInfo?
    var bonjourServices: [BonjourService] = []
    var openPorts: [PortObservation] = []
    var roundTripTime: TimeInterval?
    var ttl: Int?
    var discoveryMethods: Set<DiscoveryMethod> = []

    var isGateway = false
    var isThisDevice = false

    var category: DeviceCategory = .unknown
    var modelIdentifier: String?
    var modelName: String?
    var operatingSystem: String?
    var confidence: Double = 0

    var firstSeen = Date()
    var lastSeen = Date()

    var id: IPv4 { ip }

    /// Best available human name, falling back through every naming source.
    var displayName: String {
        if isThisDevice { return "This device" }
        if let advertised = bonjourServices.compactMap(\.advertisedFriendlyName).first,
           !advertised.isEmpty { return advertised }
        if let hostname = hostnames.first { return NameResolution.shortName(hostname) }
        if let netbiosName = netbios?.computerName { return netbiosName }
        if let instance = bonjourServices.first?.instanceName, !instance.isEmpty {
            return cleanedInstanceName(instance)
        }
        if let modelName { return modelName }
        if isGateway { return "Router" }
        if let vendor { return "\(vendor) device" }
        return ip.description
    }

    /// One-line subtitle: what we think it is, and who made it.
    var subtitle: String {
        var parts: [String] = []
        if let modelName, modelName != displayName { parts.append(modelName) }
        else if category != .unknown { parts.append(category.rawValue) }
        if let vendor, !parts.contains(where: { $0.localizedCaseInsensitiveContains(vendor) }) {
            parts.append(vendor)
        }
        if let operatingSystem { parts.append(operatingSystem) }
        guard parts.isEmpty else { return parts.joined(separator: " · ") }

        // Nothing identifying came back — say how it was seen instead of
        // repeating the address that is already the row's title.
        if !openPorts.isEmpty {
            return "\(openPorts.count) open port\(openPorts.count == 1 ? "" : "s")"
        }
        if discoveryMethods.contains(.icmp) { return "Responded to ping" }
        return "Responded to discovery"
    }

    /// True when no naming source produced anything better than the address.
    var isUnnamed: Bool { displayName == ip.description }

    /// `_raop` and friends encode a MAC into the instance name; strip it for display.
    private func cleanedInstanceName(_ name: String) -> String {
        if let separator = name.firstIndex(of: "@"), name.distance(from: name.startIndex, to: separator) == 12 {
            return String(name[name.index(after: separator)...])
        }
        if let bracket = name.firstIndex(of: "[") {
            return String(name[name.startIndex..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    var isResponsive: Bool { !discoveryMethods.isEmpty }

    /// Merges another sighting of the same address into this record.
    mutating func merge(_ other: NetworkDevice) {
        macAddress = macAddress ?? other.macAddress
        vendor = vendor ?? other.vendor
        netbios = netbios ?? other.netbios
        roundTripTime = roundTripTime ?? other.roundTripTime
        ttl = ttl ?? other.ttl
        modelIdentifier = modelIdentifier ?? other.modelIdentifier
        modelName = modelName ?? other.modelName
        operatingSystem = operatingSystem ?? other.operatingSystem
        isGateway = isGateway || other.isGateway
        isThisDevice = isThisDevice || other.isThisDevice
        discoveryMethods.formUnion(other.discoveryMethods)
        lastSeen = max(lastSeen, other.lastSeen)

        for hostname in other.hostnames where !hostnames.contains(hostname) {
            hostnames.append(hostname)
        }
        for service in other.bonjourServices where !bonjourServices.contains(service) {
            bonjourServices.append(service)
        }
        for port in other.openPorts where !openPorts.contains(where: { $0.port == port.port }) {
            openPorts.append(port)
        }
        openPorts.sort { $0.port < $1.port }
    }
}

/// A point-in-time snapshot of one subnet, suitable for export.
nonisolated struct ScanReport: Sendable, Codable {
    var startedAt: Date
    var finishedAt: Date
    var interfaceName: String
    var interfaceKind: String
    var localAddress: IPv4
    var subnet: String
    var gateway: IPv4?
    var depth: String
    var devices: [NetworkDevice]

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
