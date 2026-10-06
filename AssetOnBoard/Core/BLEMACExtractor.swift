//
//  BLEMACExtractor.swift
//  AssetOnBoard
//
//  Recovers a Bluetooth hardware address from what a device says about itself.
//
//  iOS never hands over a peripheral's BD_ADDR — CoreBluetooth substitutes a
//  UUID generated per app, and no entitlement changes that. Android's
//  BluetoothDevice.getAddress() has no counterpart here.
//
//  What does work is the same move that beats the problem on the Wi-Fi side:
//  find the places where a device publishes its own address and read those.
//  Four are common enough to be worth checking, in descending order of trust.
//

import Foundation

nonisolated struct ExtractedMAC: Sendable, Hashable {
    let address: MACAddress
    /// Where it came from, so the UI never implies iOS handed it over.
    let source: String
    /// How much the source can be trusted, 0-1.
    let confidence: Double
}

nonisolated enum BLEMACExtractor {

    /// Tries every known route and returns the most trustworthy result.
    static func extract(name: String?,
                        localName: String?,
                        companyIdentifier: UInt16?,
                        manufacturerPayload: Data?,
                        serviceData: [String: Data],
                        systemID: Data?) -> ExtractedMAC? {
        var candidates: [ExtractedMAC] = []

        if let systemID, let found = fromSystemID(systemID) { candidates.append(found) }
        if let found = fromMiBeacon(serviceData) { candidates.append(found) }
        for label in [name, localName].compactMap({ $0 }) {
            if let found = fromName(label) { candidates.append(found); break }
        }
        if let manufacturerPayload, let companyIdentifier,
           let found = fromManufacturerPayload(manufacturerPayload, company: companyIdentifier) {
            candidates.append(found)
        }

        return candidates.max { $0.confidence < $1.confidence }
    }

    // MARK: - 1. GATT System ID (0x2A23)

    /// Decodes the Device Information Service's System ID characteristic.
    ///
    /// The Bluetooth spec defines it as a 64-bit value built from an OUI plus a
    /// manufacturer identifier, and the near-universal implementation is the
    /// EUI-64 form of the device's own 48-bit MAC: the address split in half with
    /// `FF FE` inserted in the middle. Strip that filler and the MAC falls out.
    /// This is the most reliable route, and it needs a GATT connection.
    static func fromSystemID(_ data: Data) -> ExtractedMAC? {
        let bytes = [UInt8](data)
        guard bytes.count == 8 else { return nil }

        // Characteristic values are little-endian, so the common layout reads
        // FF EE DD FE FF CC BB AA for a MAC of AA:BB:CC:DD:EE:FF.
        if bytes[3] == 0xFE, bytes[4] == 0xFF {
            let mac = [bytes[7], bytes[6], bytes[5], bytes[2], bytes[1], bytes[0]]
            if let address = MACAddress(bytes: mac), isPlausible(address) {
                return ExtractedMAC(address: address, source: "GATT System ID", confidence: 0.95)
            }
        }
        // Some firmware writes it big-endian instead: AA BB CC FF FE DD EE FF.
        if bytes[3] == 0xFF, bytes[4] == 0xFE {
            let mac = [bytes[0], bytes[1], bytes[2], bytes[5], bytes[6], bytes[7]]
            if let address = MACAddress(bytes: mac), isPlausible(address) {
                return ExtractedMAC(address: address, source: "GATT System ID", confidence: 0.9)
            }
        }
        return nil
    }

    // MARK: - 2. Xiaomi Mi Beacon service data (0xFE95)

    /// Xiaomi's Mi Beacon frame carries the device's MAC in the clear.
    ///
    /// Layout: 2 bytes frame control, 2 bytes product id, 1 byte frame counter,
    /// then the 6-byte address little-endian. Bit 4 of the frame control says
    /// whether the address is present at all.
    static func fromMiBeacon(_ serviceData: [String: Data]) -> ExtractedMAC? {
        let key = serviceData.keys.first { normalise($0) == "FE95" }
        guard let key, let data = serviceData[key] else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 11 else { return nil }

        let frameControl = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard frameControl & 0x0010 != 0 else { return nil }

        let reversed = Array(bytes[5..<11].reversed())
        guard let address = MACAddress(bytes: reversed), isPlausible(address) else { return nil }
        return ExtractedMAC(address: address, source: "Mi Beacon payload", confidence: 0.9)
    }

    // MARK: - 3. MAC embedded in the advertised name

    /// Many low-cost BLE modules name themselves after their address, e.g.
    /// `JDY-08_A4C138E1F2B0` or `Govee_H5075_1A2B3C4D5E6F`.
    static func fromName(_ name: String) -> ExtractedMAC? {
        let scalars = Array(name.uppercased().unicodeScalars)
        var run: [Character] = []

        for scalar in scalars {
            let isHex = (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 70)
            if isHex {
                run.append(Character(scalar))
                if run.count == 12 { break }
            } else if run.count < 12 {
                run.removeAll()
            }
        }
        guard run.count == 12 else { return nil }

        let pairs = stride(from: 0, to: 12, by: 2).map { String(run[$0..<($0 + 2)]) }
        guard let address = MACAddress(pairs.joined(separator: ":")), isPlausible(address)
        else { return nil }
        // Only trust it when the prefix resolves to a real manufacturer —
        // otherwise a serial number could pass for an address.
        guard OUIDatabase.vendor(for: address) != nil else { return nil }
        return ExtractedMAC(address: address, source: "Embedded in device name", confidence: 0.75)
    }

    // MARK: - 4. MAC inside manufacturer data

    /// Scans a manufacturer payload for six bytes that form a registered OUI.
    ///
    /// Deliberately strict: without the OUI check any six bytes of a sensor
    /// reading would pass, so a match is only accepted when the prefix is in the
    /// IEEE registry. Apple payloads are skipped entirely — Continuity messages
    /// contain rotating identifiers that are not addresses.
    static func fromManufacturerPayload(_ payload: Data, company: UInt16) -> ExtractedMAC? {
        guard company != 0x004C, payload.count >= 6 else { return nil }
        let bytes = [UInt8](payload)

        for offset in 0...(bytes.count - 6) {
            let window = Array(bytes[offset..<(offset + 6)])
            guard let address = MACAddress(bytes: window), isPlausible(address) else { continue }
            guard let vendor = OUIDatabase.vendor(for: address) else { continue }
            return ExtractedMAC(address: address,
                                source: "Manufacturer data (\(vendor) OUI)",
                                confidence: 0.6)
        }
        // Several vendors write the address reversed; try that too.
        for offset in 0...(bytes.count - 6) {
            let window = Array(bytes[offset..<(offset + 6)].reversed())
            guard let address = MACAddress(bytes: window), isPlausible(address) else { continue }
            guard let vendor = OUIDatabase.vendor(for: address) else { continue }
            return ExtractedMAC(address: address,
                                source: "Manufacturer data, reversed (\(vendor) OUI)",
                                confidence: 0.55)
        }
        return nil
    }

    // MARK: - Helpers

    /// Rejects the values that are structurally impossible for a device address.
    private static func isPlausible(_ address: MACAddress) -> Bool {
        guard !address.isAllZero, !address.isMulticast else { return false }
        guard !address.bytes.allSatisfy({ $0 == 0xFF }) else { return false }
        // An address of six identical bytes is padding, not hardware.
        guard Set(address.bytes).count > 1 else { return false }
        return true
    }

    private static func normalise(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        if upper.count == 36, upper.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(upper.prefix(8).suffix(4))
        }
        return upper
    }
}
