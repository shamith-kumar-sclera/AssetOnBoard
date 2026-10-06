//
//  UnifiedAsset.swift
//  AssetOnBoard
//
//  One physical thing, however many radios saw it.
//
//  The four scans answer different questions about overlapping sets of hardware.
//  A laptop is a row in the network scan, an advertisement in the Bluetooth
//  scan, and a rectangle in a room photograph; an access point is all of that
//  plus an SSID. An asset register wants one line per object, so this is the
//  merged record — and, just as importantly, it keeps the evidence for every
//  merge, because a wrong join hides a device from the register entirely and
//  someone has to be able to check the working.
//
//  The radios merge with each other. Photographed objects never merge: see
//  AssetCorrelator. A camera row is its own asset, carrying whatever the room
//  scan read off the hardware.
//

import Foundation

/// Which scan saw the asset. An asset seen by two is better evidence than one.
nonisolated enum AssetChannel: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case network = "Network"
    case bluetooth = "Bluetooth"
    case accessPoint = "Access point"
    case camera = "Camera"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .network: "network"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .accessPoint: "wifi.router.fill"
        case .camera: "camera.viewfinder"
        }
    }
}

/// The union of what the four scans can each call a thing.
///
/// Deliberately wider than any one scanner's own categories: Bluetooth knows
/// about trackers and keyboards, the camera knows about displays and furniture,
/// and the network scan knows about NAS boxes and hypervisors. Flattening those
/// into one enum would throw away the distinctions an asset register is for.
nonisolated enum AssetKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case router = "Router / Gateway"
    case accessPoint = "Access Point"
    case computer = "Computer"
    case phone = "Phone"
    case tablet = "Tablet"
    case tv = "TV / Streaming"
    case speaker = "Speaker / Audio"
    case printer = "Printer"
    case camera = "Camera"
    case nas = "Network Storage"
    case gameConsole = "Game Console"
    case smartHome = "Smart Home"
    case server = "Server"
    case virtualMachine = "Virtual Machine"
    case wearable = "Wearable"
    case input = "Keyboard / Mouse"
    case tracker = "Tracker"
    case beacon = "Beacon"
    case display = "Display"
    case peripheral = "Peripheral"
    case appliance = "Appliance"
    case furniture = "Furniture"
    case unknown = "Unidentified"

    var id: String { rawValue }

    /// Whether an IT asset register would actually carry one of these.
    ///
    /// Furniture is detected because it helps a human recognise the room, and a
    /// beacon is a broadcast rather than a device anyone onboards.
    var isOnboardable: Bool {
        switch self {
        case .furniture, .beacon: false
        default: true
        }
    }

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
        case .input: "keyboard"
        case .tracker: "tag.fill"
        case .beacon: "dot.radiowaves.left.and.right"
        case .display: "display"
        case .peripheral: "cable.connector"
        case .appliance: "oven"
        case .furniture: "chair"
        case .unknown: "questionmark.circle"
        }
    }

    init(_ category: DeviceCategory) {
        self = switch category {
        case .router: .router
        case .accessPoint: .accessPoint
        case .computer: .computer
        case .phone: .phone
        case .tablet: .tablet
        case .tv: .tv
        case .speaker: .speaker
        case .printer: .printer
        case .camera: .camera
        case .nas: .nas
        case .gameConsole: .gameConsole
        case .smartHome: .smartHome
        case .server: .server
        case .virtualMachine: .virtualMachine
        case .wearable: .wearable
        case .unknown: .unknown
        }
    }

    init(_ category: BluetoothCategory) {
        self = switch category {
        case .phone: .phone
        case .computer: .computer
        // A watch and a fitness band are both worn; the register does not need
        // to know which, and Bluetooth appearance bits cannot always tell.
        case .watch, .wearable, .health: .wearable
        case .audio: .speaker
        case .input: .input
        case .tag: .tracker
        case .beacon: .beacon
        case .smartHome: .smartHome
        case .unknown: .unknown
        }
    }

    init(_ category: AssetCategory) {
        self = switch category {
        case .display: .display
        case .computer: .computer
        case .peripheral: .peripheral
        case .phone: .phone
        case .networkGear: .accessPoint
        case .printer: .printer
        case .appliance: .appliance
        case .furniture: .furniture
        case .other: .unknown
        }
    }
}

/// One object seen in a room photograph, with the room it was shot in.
nonisolated struct RoomAssetRef: Sendable, Codable, Hashable {
    var asset: DetectedAsset
    var room: String
    var capturedAt: Date
}

nonisolated struct UnifiedAsset: Identifiable, Sendable, Codable, Hashable {

    // MARK: - Source records

    var networkDevices: [NetworkDevice] = []
    var bluetoothDevices: [BluetoothDevice] = []
    var accessPoints: [AccessPoint] = []
    var roomAssets: [RoomAssetRef] = []

    /// Why the records above were judged to be the same object, one line per
    /// join. Empty for an asset only one scan ever saw.
    var mergeEvidence: [String] = []

    /// Stable across re-correlation, so SwiftUI does not rebuild every row.
    ///
    /// Derived from the strongest identifier present rather than a fresh UUID:
    /// the same hardware should keep the same row identity between scans.
    var id: String {
        if let mac = macAddresses.first { return "mac:\(mac)" }
        if let ip = ipAddresses.first { return "ip:\(ip)" }
        if let uuid = bluetoothDevices.first?.id { return "bt:\(uuid.uuidString)" }
        if let room = roomAssets.first { return "cam:\(room.asset.id.uuidString)" }
        return "empty"
    }

    // MARK: - Identity

    var ipAddresses: [IPv4] {
        var seen = Set<IPv4>()
        return (networkDevices.map(\.ip) + accessPoints.compactMap(\.ipAddress))
            .filter { seen.insert($0).inserted }
    }

    var macAddresses: [MACAddress] {
        var seen = Set<MACAddress>()
        return (networkDevices.compactMap(\.macAddress)
                + accessPoints.compactMap(\.macAddress)
                + bluetoothDevices.compactMap(\.macAddress))
            .filter { seen.insert($0).inserted }
    }

    var hostnames: [String] {
        var seen = Set<String>()
        return (networkDevices.flatMap(\.hostnames) + accessPoints.flatMap(\.hostnames))
            .filter { seen.insert($0).inserted }
    }

    var seenBy: Set<AssetChannel> {
        var channels: Set<AssetChannel> = []
        if !networkDevices.isEmpty { channels.insert(.network) }
        if !bluetoothDevices.isEmpty { channels.insert(.bluetooth) }
        if !accessPoints.isEmpty { channels.insert(.accessPoint) }
        if !roomAssets.isEmpty { channels.insert(.camera) }
        return channels
    }

    /// True when more than one scan found it — the strongest signal that the
    /// record is real and that the merge was worth making.
    var isCorroborated: Bool { seenBy.count > 1 }

    // MARK: - Description

    /// Best name across every source, preferring the scan that knows most.
    ///
    /// An access point's SSID and a network device's Bonjour name are things the
    /// hardware chose to call itself. A camera label is a guess about a shape,
    /// so it goes last.
    var name: String {
        if let ssid = accessPoints.compactMap(\.ssid).first(where: { !$0.isEmpty }) { return ssid }
        if let device = networkDevices.first(where: { !$0.isUnnamed }) { return device.displayName }
        if let bluetooth = bluetoothDevices.first(where: { $0.name?.isEmpty == false }) {
            return bluetooth.displayName
        }
        if let point = accessPoints.first { return point.displayName }
        if let bluetooth = bluetoothDevices.first { return bluetooth.displayName }
        if let device = networkDevices.first { return device.displayName }
        if let room = roomAssets.first { return room.asset.displayName }
        return "Unidentified asset"
    }

    var kind: AssetKind {
        // An SSID or a confirmed gateway settles it outright.
        if accessPoints.contains(where: { $0.kind == .joined || $0.ssid != nil }) { return .accessPoint }
        if networkDevices.contains(where: \.isGateway) { return .router }

        let candidates = networkDevices.map { AssetKind($0.category) }
            + bluetoothDevices.map { AssetKind($0.category) }
            + roomAssets.map { AssetKind($0.asset.category) }
        if let known = candidates.first(where: { $0 != .unknown }) { return known }
        return accessPoints.isEmpty ? .unknown : .accessPoint
    }

    var vendor: String? {
        networkDevices.compactMap(\.vendor).first
            ?? accessPoints.compactMap(\.vendor).first
            ?? bluetoothDevices.compactMap(\.manufacturerName).first
            ?? bluetoothDevices.compactMap(\.macVendor).first
    }

    var model: String? {
        networkDevices.compactMap(\.modelName).first
            ?? accessPoints.compactMap(\.model).first
            ?? bluetoothDevices.compactMap { $0.deviceInformation["Model"] }.first
            ?? roomAssets.compactMap(\.asset.likelyModelString).first
    }

    var operatingSystem: String? { networkDevices.compactMap(\.operatingSystem).first }

    var ssid: String? { accessPoints.compactMap(\.ssid).first }

    /// Strings worth treating as an asset tag: barcodes first, then model-like
    /// text read off the case.
    var assetTags: [String] {
        var seen = Set<String>()
        return (roomAssets.flatMap(\.asset.barcodes)
                + roomAssets.compactMap(\.asset.likelyModelString))
            .filter { seen.insert($0).inserted }
    }

    var rooms: [String] {
        var seen = Set<String>()
        return roomAssets.map(\.room).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var openPorts: [UInt16] {
        var seen = Set<UInt16>()
        return networkDevices.flatMap { $0.openPorts.map(\.port) }
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    var services: [String] {
        var seen = Set<String>()
        return (networkDevices.flatMap { $0.bonjourServices.map(\.friendlyProtocolName) }
                + bluetoothDevices.flatMap(\.serviceNames)
                + accessPoints.flatMap(\.managementServices))
            .filter { seen.insert($0).inserted }
    }

    /// Strongest Bluetooth signal seen, for a rough sense of proximity.
    var rssi: Int? { bluetoothDevices.map(\.bestRSSI).max() }

    var isThisDevice: Bool { networkDevices.contains(where: \.isThisDevice) }

    var firstSeen: Date {
        ([networkDevices.map(\.firstSeen), bluetoothDevices.map(\.firstSeen),
          roomAssets.map(\.capturedAt)].flatMap { $0 }).min() ?? Date()
    }

    var lastSeen: Date {
        ([networkDevices.map(\.lastSeen), bluetoothDevices.map(\.lastSeen),
          roomAssets.map(\.capturedAt)].flatMap { $0 }).max() ?? Date()
    }

    /// How much to trust that this row is one real, correctly-identified thing.
    ///
    /// Corroboration across independent scans counts for more than any single
    /// scan's own confidence, because the failure modes do not overlap: a
    /// rotating BLE identifier and a stale ARP entry are not wrong in the same
    /// way about the same object.
    var confidence: Double {
        var score = 0.0
        if !networkDevices.isEmpty { score += 0.5 }
        if !accessPoints.isEmpty { score += 0.3 }
        if !bluetoothDevices.isEmpty { score += 0.3 }
        if !roomAssets.isEmpty { score += 0.2 }
        if !macAddresses.isEmpty { score += 0.2 }
        if kind != .unknown { score += 0.1 }
        return min(1, score)
    }

    var subtitle: String {
        var parts: [String] = []
        if kind != .unknown { parts.append(kind.rawValue) }
        if let vendor { parts.append(vendor) }
        if let model, model != name { parts.append(model) }
        if let address = ipAddresses.first { parts.append(address.description) }
        else if let mac = macAddresses.first { parts.append(mac.description) }
        if let room = rooms.first { parts.append(room) }
        return parts.isEmpty ? "Unidentified" : parts.joined(separator: " · ")
    }

    /// Folds another record's sources into this one.
    mutating func absorb(_ other: UnifiedAsset) {
        networkDevices += other.networkDevices
        bluetoothDevices += other.bluetoothDevices
        accessPoints += other.accessPoints
        roomAssets += other.roomAssets
        for reason in other.mergeEvidence where !mergeEvidence.contains(reason) {
            mergeEvidence.append(reason)
        }
    }
}

extension UnifiedAsset {
    /// Matches the search box against every identifying string the merge holds.
    ///
    /// Searches the source records rather than only the derived summary, so a
    /// hostname or a barcode that lost the tie for `name` is still findable.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }

        var haystack: [String] = [name, subtitle, kind.rawValue]
        haystack += ipAddresses.map(\.description)
        haystack += macAddresses.map(\.description)
        haystack += hostnames
        haystack += rooms
        haystack += assetTags
        haystack += services
        haystack += [vendor, model, operatingSystem, ssid].compactMap { $0 }
        haystack += bluetoothDevices.compactMap(\.name)
        haystack += bluetoothDevices.compactMap(\.localName)
        haystack += accessPoints.map(\.displayName)
        haystack += roomAssets.map(\.asset.rawLabel)
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}
