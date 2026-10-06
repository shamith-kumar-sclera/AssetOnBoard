//
//  BluetoothScanner.swift
//  AssetOnBoard
//
//  Bluetooth Low Energy discovery via CoreBluetooth.
//
//  Two limits are worth stating plainly, because they shape everything here:
//  iOS exposes no hardware addresses for BLE peripherals (only a rotating,
//  per-app UUID), and it offers no API for Classic Bluetooth at all — so this
//  sees BLE devices only. Everything a device reveals therefore comes from what
//  it chooses to advertise, plus whatever GATT exposes if the user connects.
//

import Foundation
import CoreBluetooth
import Observation

@Observable
final class BluetoothScanner: NSObject {

    enum Availability: Equatable {
        case unknown
        case unauthorised
        case poweredOff
        case unsupported
        case ready

        var message: String {
            switch self {
            case .unknown: "Preparing Bluetooth…"
            case .unauthorised: "Bluetooth permission is required to scan for nearby devices."
            case .poweredOff: "Bluetooth is switched off. Turn it on to scan."
            case .unsupported: "This device has no Bluetooth LE radio. The iOS Simulator does not provide one — run on a real iPhone to scan."
            case .ready: "Ready"
            }
        }

        var symbolName: String {
            switch self {
            case .unknown: "hourglass"
            case .unauthorised: "hand.raised.fill"
            case .poweredOff: "power"
            case .unsupported: "exclamationmark.triangle.fill"
            case .ready: "checkmark.circle.fill"
            }
        }
    }

    // MARK: - Observable state

    private(set) var availability: Availability = .unknown
    private(set) var isScanning = false
    private(set) var devices: [BluetoothDevice] = []
    private(set) var statusDetail = ""
    private(set) var startedAt: Date?
    private(set) var lastScanDuration: TimeInterval?

    /// Report every advertisement rather than one summary per peripheral.
    ///
    /// Off by default because devices broadcast several times a second; on, it
    /// keeps RSSI and payloads live for tracking signal strength as you move.
    var reportsRepeatAdvertisements = true

    var sortedDevices: [BluetoothDevice] {
        devices.sorted { $0.bestRSSI > $1.bestRSSI }
    }

    // MARK: - Private

    private var central: CBCentralManager?
    private var index: [UUID: BluetoothDevice] = [:]
    /// Held so CoreBluetooth does not deallocate peripherals mid-connection.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var enrichmentTargets: Set<UUID> = []
    private var publishPending = false
    private var lastPublish = Date.distantPast
    private static let publishInterval: TimeInterval = 0.4

    // MARK: - Lifecycle

    /// Creates the central manager, which is what triggers the iOS permission
    /// prompt. Deferred until the user opens the Bluetooth tab so the app does
    /// not ask for Bluetooth on launch.
    func prepare() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self,
                                   queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startScan() {
        prepare()
        guard let central, central.state == .poweredOn else { return }
        index.removeAll()
        devices = []
        startedAt = Date()
        isScanning = true
        statusDetail = "Listening for advertisements…"

        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: reportsRepeatAdvertisements]
        )
    }

    func stopScan() {
        central?.stopScan()
        guard isScanning else { return }
        isScanning = false
        if let startedAt { lastScanDuration = Date().timeIntervalSince(startedAt) }
        publish()
        statusDetail = "\(devices.count) device\(devices.count == 1 ? "" : "s") found"
    }

    func reset() {
        stopScan()
        index.removeAll()
        devices = []
        statusDetail = ""
        startedAt = nil
        lastScanDuration = nil
    }

    // MARK: - Shared discovery

    /// Runs a short passive pass on behalf of the Access Points tab, and returns
    /// everything currently in range.
    ///
    /// Existing results are kept rather than cleared: the Bluetooth tab may be
    /// mid-scan, and one tab asking a question should not wipe another's list.
    /// Duplicates are switched off for this pass because the caller wants a
    /// census, not a signal-strength feed.
    func collectNearbyRadios(duration: TimeInterval = 6) async -> [BluetoothDevice] {
        prepare()
        guard let central else { return [] }

        // CBCentralManager reports its state asynchronously after construction,
        // so a scan started immediately after `prepare()` would be dropped.
        let deadline = Date().addingTimeInterval(2)
        while central.state == .unknown || central.state == .resetting {
            guard Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard central.state == .poweredOn else { return [] }

        let alreadyRunning = isScanning
        if !alreadyRunning {
            startedAt = startedAt ?? Date()
            isScanning = true
            statusDetail = "Listening for nearby radios…"
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }

        try? await Task.sleep(for: .seconds(duration))

        if !alreadyRunning && isScanning {
            central.stopScan()
            isScanning = false
            publish()
        }
        return Array(index.values)
    }

    // MARK: - GATT enrichment

    /// Connects to a peripheral and reads its standard information services.
    ///
    /// Only connectable devices respond; beacons and trackers advertise and
    /// nothing more, which is why this is opt-in per device rather than
    /// automatic for everything in range.
    func enrich(_ device: BluetoothDevice) {
        guard let central, central.state == .poweredOn,
              let peripheral = peripherals[device.id] else { return }
        guard device.isConnectable else {
            update(device.id) { $0.enrichmentError = "Device does not accept connections." }
            return
        }
        enrichmentTargets.insert(device.id)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)

        // Connection attempts can hang indefinitely; give up and say so.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.enrichmentTargets.contains(device.id) else { return }
            self.enrichmentTargets.remove(device.id)
            self.central?.cancelPeripheralConnection(peripheral)
            self.update(device.id) { entry in
                if !entry.isEnriched { entry.enrichmentError = "Connection timed out." }
            }
        }
    }

    // MARK: - Hardware address recovery

    /// Re-runs MAC extraction over everything currently known about a device.
    ///
    /// Called on each advertisement and again after a GATT read, because the
    /// System ID characteristic is the most reliable source and only becomes
    /// available once connected.
    private func applyExtractedMAC(to device: inout BluetoothDevice) {
        let systemID = device.deviceInformation["System ID"].flatMap(Self.hexToData)
        guard let found = BLEMACExtractor.extract(name: device.name,
                                                  localName: device.localName,
                                                  companyIdentifier: device.companyIdentifier,
                                                  manufacturerPayload: device.manufacturerPayload,
                                                  serviceData: device.serviceData,
                                                  systemID: systemID)
        else { return }

        // Keep whichever source is most trustworthy.
        if let existing = device.macConfidence, existing >= found.confidence { return }
        device.macAddress = found.address
        device.macSource = found.source
        device.macConfidence = found.confidence
        device.macVendor = OUIDatabase.vendor(for: found.address)
    }

    nonisolated private static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.filter(\.isHexDigit)
        guard cleaned.count % 2 == 0, !cleaned.isEmpty else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    // MARK: - Merge and publish

    private func update(_ id: UUID, _ body: (inout BluetoothDevice) -> Void) {
        guard var device = index[id] else { return }
        body(&device)
        index[id] = device
        schedulePublish()
    }

    private func schedulePublish() {
        guard !publishPending else { return }
        publishPending = true
        let delay = max(0, Self.publishInterval - Date().timeIntervalSince(lastPublish))
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self else { return }
            self.publishPending = false
            self.publish()
        }
    }

    private func publish() {
        lastPublish = Date()
        devices = Array(index.values)
        if isScanning {
            statusDetail = "\(devices.count) device\(devices.count == 1 ? "" : "s") nearby"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothScanner: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: availability = .ready
        case .poweredOff: availability = .poweredOff; isScanning = false
        case .unauthorized: availability = .unauthorised; isScanning = false
        case .unsupported: availability = .unsupported; isScanning = false
        case .resetting, .unknown: availability = .unknown
        @unknown default: availability = .unknown
        }
        if availability != .ready { statusDetail = availability.message }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        peripherals[id] = peripheral
        let signal = RSSI.intValue
        // 127 is CoreBluetooth's "RSSI unavailable" sentinel.
        guard signal != 127 else { return }

        var device = index[id] ?? BluetoothDevice(id: id,
                                                  name: peripheral.name,
                                                  localName: nil,
                                                  rssi: signal,
                                                  bestRSSI: signal,
                                                  isConnectable: false)
        device.rssi = signal
        device.bestRSSI = max(device.bestRSSI, signal)
        device.lastSeen = Date()
        device.advertisementCount += index[id] == nil ? 0 : 1
        device.name = peripheral.name ?? device.name

        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            device.localName = localName
        }
        if let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
            device.txPowerLevel = txPower.intValue
        }
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
            device.isConnectable = connectable.boolValue
        }
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturerData.count >= 2 {
            // Company identifier is the first two bytes, little-endian.
            let company = UInt16(manufacturerData[manufacturerData.startIndex])
                | UInt16(manufacturerData[manufacturerData.index(after: manufacturerData.startIndex)]) << 8
            device.companyIdentifier = company
            device.manufacturerName = BluetoothAssignedNumbers.company(for: company)
            let payload = manufacturerData.dropFirst(2)
            device.manufacturerPayload = Data(payload)
            if company == 0x004C, let type = payload.first {
                device.appleContinuityType = BluetoothAssignedNumbers.appleContinuityType(type)
            }
        }
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            device.serviceUUIDs = services.map(\.uuidString)
        }
        if let solicited = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] {
            device.solicitedServiceUUIDs = solicited.map(\.uuidString)
        }
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            device.serviceDataKeys = serviceData.keys.map(\.uuidString)
            device.serviceData = Dictionary(uniqueKeysWithValues:
                serviceData.map { ($0.key.uuidString, $0.value) })
        }

        applyExtractedMAC(to: &device)
        index[id] = device
        schedulePublish()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        enrichmentTargets.remove(peripheral.identifier)
        update(peripheral.identifier) {
            $0.enrichmentError = error?.localizedDescription ?? "Could not connect."
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        enrichmentTargets.remove(peripheral.identifier)
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothScanner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            finishEnrichment(peripheral, error: error)
            return
        }
        update(peripheral.identifier) { device in
            device.gattServices = services.map { service in
                GATTServiceRecord(uuid: service.uuid.uuidString,
                                  name: BluetoothAssignedNumbers.serviceName(for: service.uuid.uuidString),
                                  characteristics: [])
            }
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let characteristics = service.characteristics else { return }

        update(peripheral.identifier) { device in
            let records = characteristics.map { characteristic in
                GATTCharacteristicRecord(uuid: characteristic.uuid.uuidString,
                                         name: BluetoothAssignedNumbers.characteristicName(for: characteristic.uuid.uuidString),
                                         properties: Self.describe(characteristic.properties),
                                         value: nil)
            }
            if let position = device.gattServices.firstIndex(where: { $0.uuid == service.uuid.uuidString }) {
                device.gattServices[position].characteristics = records
            }
        }

        // Read the standard identity and battery values; anything else could be
        // vendor-specific and is left untouched.
        let interesting = Set(BluetoothAssignedNumbers.deviceInformationCharacteristics.map(\.uuid) + ["2A19", "2A00", "2A01"])
        for characteristic in characteristics
        where characteristic.properties.contains(.read)
            && interesting.contains(shortUUID(characteristic.uuid.uuidString)) {
            peripheral.readValue(for: characteristic)
        }

        // Once the last service is processed the peripheral can be released.
        if service.uuid == peripheral.services?.last?.uuid {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.finishEnrichment(peripheral, error: nil)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let uuid = shortUUID(characteristic.uuid.uuidString)

        update(peripheral.identifier) { device in
            switch uuid {
            case "2A19":
                device.batteryLevel = data.first.map(Int.init)
            case "2A01":
                if data.count >= 2 {
                    let value = UInt16(data[data.startIndex]) | UInt16(data[data.index(after: data.startIndex)]) << 8
                    device.appearance = value
                    device.appearanceName = BluetoothAssignedNumbers.appearanceName(for: value)
                }
            case "2A00":
                if let text = String(data: data, encoding: .utf8), !text.isEmpty { device.name = text }
            default:
                guard let label = BluetoothAssignedNumbers.deviceInformationCharacteristics
                    .first(where: { $0.uuid == uuid })?.label else { return }
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                device.deviceInformation[label] = (text?.isEmpty == false)
                    ? text!
                    : data.map { String(format: "%02X", $0) }.joined()
            }
            self.applyExtractedMAC(to: &device)

            // Characteristic values are also mirrored into the GATT tree so the
            // detail screen can show them in context.
            for serviceIndex in device.gattServices.indices {
                for characteristicIndex in device.gattServices[serviceIndex].characteristics.indices
                where shortUUID(device.gattServices[serviceIndex].characteristics[characteristicIndex].uuid) == uuid {
                    device.gattServices[serviceIndex].characteristics[characteristicIndex].value =
                        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
                        ?? data.map { String(format: "%02X", $0) }.joined()
                }
            }
        }
    }

    private func finishEnrichment(_ peripheral: CBPeripheral, error: Error?) {
        enrichmentTargets.remove(peripheral.identifier)
        update(peripheral.identifier) { device in
            device.isEnriched = true
            if let error { device.enrichmentError = error.localizedDescription }
        }
        central?.cancelPeripheralConnection(peripheral)
    }

    private func shortUUID(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        if upper.count == 36, upper.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(upper.prefix(8).suffix(4))
        }
        return upper
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> [String] {
        var names: [String] = []
        if properties.contains(.read) { names.append("Read") }
        if properties.contains(.write) { names.append("Write") }
        if properties.contains(.writeWithoutResponse) { names.append("Write No Response") }
        if properties.contains(.notify) { names.append("Notify") }
        if properties.contains(.indicate) { names.append("Indicate") }
        if properties.contains(.broadcast) { names.append("Broadcast") }
        if properties.contains(.authenticatedSignedWrites) { names.append("Signed Write") }
        return names
    }
}
