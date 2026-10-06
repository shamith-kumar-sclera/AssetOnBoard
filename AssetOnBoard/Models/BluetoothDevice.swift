//
//  BluetoothDevice.swift
//  AssetOnBoard
//
//  A Bluetooth Low Energy peripheral seen during a scan.
//
//  Note the missing field: there is no MAC address here, and there cannot be.
//  iOS deliberately withholds a peripheral's hardware address and substitutes a
//  UUID that is unique per app and rotates, so identity has to be assembled from
//  what the device advertises about itself instead.
//

import Foundation

nonisolated struct GATTServiceRecord: Identifiable, Sendable, Codable, Hashable {
    var uuid: String
    var name: String?
    var characteristics: [GATTCharacteristicRecord]

    var id: String { uuid }
    var displayName: String { name ?? uuid }
}

nonisolated struct GATTCharacteristicRecord: Identifiable, Sendable, Codable, Hashable {
    var uuid: String
    var name: String?
    var properties: [String]
    var value: String?

    var id: String { uuid }
    var displayName: String { name ?? uuid }
}

nonisolated struct BluetoothDevice: Identifiable, Sendable, Codable, Hashable {
    /// CoreBluetooth's per-app identifier — not a hardware address.
    var id: UUID
    var name: String?
    var localName: String?

    var rssi: Int
    var bestRSSI: Int
    var txPowerLevel: Int?
    var isConnectable: Bool

    var companyIdentifier: UInt16?
    var manufacturerName: String?
    var manufacturerPayload: Data?
    var appleContinuityType: String?

    var serviceUUIDs: [String] = []
    var solicitedServiceUUIDs: [String] = []
    var serviceDataKeys: [String] = []
    /// Full advertisement service data, keyed by UUID. Retained because some
    /// vendors (notably Xiaomi) publish the device's own MAC inside it.
    var serviceData: [String: Data] = [:]

    /// Hardware address, when the device published one itself.
    ///
    /// iOS never supplies this — see BLEMACExtractor for the routes that do.
    var macAddress: MACAddress?
    var macSource: String?
    var macConfidence: Double?
    var macVendor: String?

    var appearance: UInt16?
    var appearanceName: String?

    // Filled in only when the user asks for a deeper look, which requires
    // connecting to the peripheral.
    var deviceInformation: [String: String] = [:]
    var batteryLevel: Int?
    var gattServices: [GATTServiceRecord] = []
    var isEnriched = false
    var enrichmentError: String?

    var advertisementCount: Int = 1
    var firstSeen = Date()
    var lastSeen = Date()

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let localName, !localName.isEmpty { return localName }
        if let model = deviceInformation["Model"], !model.isEmpty { return model }
        if let manufacturerName { return "\(manufacturerName) device" }
        if let appearanceName, appearanceName != "Unknown" { return appearanceName }
        return "Unnamed device"
    }

    var subtitle: String {
        var parts: [String] = []
        if let manufacturerName { parts.append(manufacturerName) }
        else if let macVendor { parts.append(macVendor) }
        if let appleContinuityType { parts.append(appleContinuityType) }
        if let appearanceName, appearanceName != "Unknown" { parts.append(appearanceName) }
        if parts.isEmpty {
            let named = serviceUUIDs.compactMap { BluetoothAssignedNumbers.serviceName(for: $0) }
            if let first = named.first { parts.append(first) }
        }
        if parts.isEmpty { parts.append(isConnectable ? "Connectable" : "Broadcast only") }
        return parts.joined(separator: " · ")
    }

    /// Human-readable names for everything the device advertises.
    var serviceNames: [String] {
        serviceUUIDs.map { BluetoothAssignedNumbers.serviceName(for: $0) ?? $0 }
    }

    /// Rough distance in metres from the log-distance path-loss model.
    ///
    /// Indoor multipath makes this an estimate, not a measurement — it is useful
    /// for "closer than that one", not for anything precise.
    var estimatedDistance: Double? {
        guard rssi < 0 else { return nil }
        let referencePower = Double(txPowerLevel ?? -59)
        let pathLossExponent = 2.0
        let metres = pow(10, (referencePower - Double(rssi)) / (10 * pathLossExponent))
        return metres.isFinite && metres < 200 ? metres : nil
    }

    /// Coarse signal bucket for the UI.
    var signalStrength: SignalStrength {
        switch rssi {
        case (-55)...: .excellent
        case (-70)..<(-55): .good
        case (-85)..<(-70): .fair
        default: .weak
        }
    }

    enum SignalStrength: String, Sendable {
        case excellent = "Excellent"
        case good = "Good"
        case fair = "Fair"
        case weak = "Weak"

        var bars: Int {
            switch self {
            case .excellent: 4
            case .good: 3
            case .fair: 2
            case .weak: 1
            }
        }
    }

    /// Best-guess device class, from appearance, advertised services and vendor.
    var category: BluetoothCategory {
        if let appearance {
            switch appearance >> 6 {
            case 1: return .phone
            case 2: return .computer
            case 3, 4: return .watch
            case 7: return .wearable
            case 8, 9: return .tag
            case 10: return .audio
            case 13, 16, 17, 18, 49, 50, 52, 53: return .health
            case 15, 42: return .input
            case 33, 34, 37: return .audio
            case 20, 21, 22, 23, 24, 28, 29, 30, 31, 32: return .smartHome
            default: break
            }
        }
        let names = Set(serviceUUIDs.map { $0.uppercased() })
        if names.contains("180D") || names.contains("1810") || names.contains("1808") { return .health }
        if names.contains("1812") { return .input }
        if names.contains("FEAA") || names.contains("FD6F") { return .beacon }
        if names.contains("FEED") { return .tag }
        if let continuity = appleContinuityType {
            if continuity.contains("AirPods") { return .audio }
            if continuity.contains("Find My") { return .tag }
            if continuity.contains("Watch") { return .watch }
            if continuity.contains("HomeKit") { return .smartHome }
        }
        return .unknown
    }
}

nonisolated enum BluetoothCategory: String, Sendable, CaseIterable, Identifiable, Codable {
    case phone = "Phone"
    case computer = "Computer"
    case watch = "Watch"
    case audio = "Audio"
    case wearable = "Wearable"
    case health = "Health"
    case input = "Keyboard / Mouse"
    case tag = "Tracker"
    case beacon = "Beacon"
    case smartHome = "Smart Home"
    case unknown = "Unidentified"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .watch: "applewatch"
        case .audio: "airpods.pro"
        case .wearable: "figure.walk"
        case .health: "heart.fill"
        case .input: "keyboard"
        case .tag: "tag.fill"
        case .beacon: "dot.radiowaves.left.and.right"
        case .smartHome: "lightbulb.fill"
        case .unknown: "questionmark.circle"
        }
    }
}
