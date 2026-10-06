//
//  BluetoothAssignedNumbers.swift
//  AssetOnBoard
//
//  Bluetooth SIG assigned numbers: company identifiers, GATT UUIDs, appearances.
//
//  iOS never exposes a BLE device's hardware address, so the 16-bit company
//  identifier at the front of a manufacturer-data payload is the closest thing
//  to an OUI available here — it is usually the only clue to who built a device
//  that advertises no name at all.
//

import Foundation

nonisolated enum BluetoothAssignedNumbers {

    // MARK: - Company identifiers

    static func company(for identifier: UInt16) -> String? {
        companies[identifier]
    }

    /// Always-useful label: the vendor when known, the raw value otherwise.
    static func companyLabel(for identifier: UInt16) -> String {
        companies[identifier] ?? String(format: "Unknown (0x%04X)", identifier)
    }

    private static let companies: [UInt16: String] = {
        var result: [UInt16: String] = [:]
        for line in packedCompanies.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            guard let key = UInt16(line[line.startIndex..<separator], radix: 16) else { continue }
            result[key] = String(line[line.index(after: separator)...])
        }
        return result
    }()

    // MARK: - GATT services

    static func serviceName(for uuid: String) -> String? {
        let key = normalise(uuid)
        return services[key]
    }

    static func characteristicName(for uuid: String) -> String? {
        let key = normalise(uuid)
        return characteristics[key]
    }

    /// CoreBluetooth prints 16-bit UUIDs short and 128-bit ones in full; reduce
    /// the Bluetooth base UUID form back to its 16-bit assigned number.
    private static func normalise(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        if upper.count == 36, upper.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(upper.prefix(8).suffix(4))
        }
        return upper
    }

    private static let services: [String: String] = [
        "1800": "Generic Access", "1801": "Generic Attribute", "1802": "Immediate Alert",
        "1803": "Link Loss", "1804": "Tx Power", "1805": "Current Time",
        "1808": "Glucose", "1809": "Health Thermometer", "180A": "Device Information",
        "180D": "Heart Rate", "180E": "Phone Alert Status", "180F": "Battery",
        "1810": "Blood Pressure", "1811": "Alert Notification", "1812": "Human Interface Device",
        "1813": "Scan Parameters", "1814": "Running Speed and Cadence",
        "1816": "Cycling Speed and Cadence", "1818": "Cycling Power",
        "1819": "Location and Navigation", "181A": "Environmental Sensing",
        "181B": "Body Composition", "181C": "User Data", "181D": "Weight Scale",
        "181E": "Bond Management", "181F": "Continuous Glucose Monitoring",
        "1820": "Internet Protocol Support", "1821": "Indoor Positioning",
        "1826": "Fitness Machine", "1827": "Mesh Provisioning", "1828": "Mesh Proxy",
        "183A": "Insulin Delivery", "1843": "Audio Input Control",
        "1844": "Volume Control", "1845": "Volume Offset Control",
        "1848": "Media Control", "184E": "Audio Stream Control",
        "FD6F": "Exposure Notification", "FE2C": "Google Fast Pair",
        "FEAA": "Eddystone", "FE59": "Nordic DFU", "FEE0": "Anhui Huami",
        "FEE1": "Anhui Huami", "FEE7": "Tencent", "FD44": "Apple",
        "FE9F": "Google", "FDF0": "Google", "FE07": "Microsoft",
        "FE26": "Google", "FE61": "Logitech", "FE95": "Xiaomi",
        "FEED": "Tile", "FD5A": "Samsung", "FE03": "Amazon"
    ]

    private static let characteristics: [String: String] = [
        "2A00": "Device Name", "2A01": "Appearance", "2A04": "Preferred Connection Parameters",
        "2A19": "Battery Level", "2A23": "System ID", "2A24": "Model Number",
        "2A25": "Serial Number", "2A26": "Firmware Revision", "2A27": "Hardware Revision",
        "2A28": "Software Revision", "2A29": "Manufacturer Name", "2A2A": "IEEE Regulatory Data",
        "2A50": "PnP ID", "2A37": "Heart Rate Measurement", "2A38": "Body Sensor Location",
        "2A6E": "Temperature", "2A6F": "Humidity", "2A6D": "Pressure",
        "2A98": "Weight", "2A9E": "Body Composition Feature"
    ]

    /// Characteristics worth reading during GATT enrichment, in display order.
    static let deviceInformationCharacteristics: [(uuid: String, label: String)] = [
        ("2A29", "Manufacturer"), ("2A24", "Model"), ("2A25", "Serial Number"),
        ("2A27", "Hardware Revision"), ("2A26", "Firmware Revision"),
        ("2A28", "Software Revision"), ("2A23", "System ID")
    ]

    // MARK: - Appearance

    /// Decodes the 16-bit GAP appearance value into its category name.
    static func appearanceName(for value: UInt16) -> String {
        let category = value >> 6
        return appearanceCategories[category] ?? String(format: "Unknown (0x%04X)", value)
    }

    private static let appearanceCategories: [UInt16: String] = [
        0: "Unknown", 1: "Phone", 2: "Computer", 3: "Watch", 4: "Clock",
        5: "Display", 6: "Remote Control", 7: "Eye Glasses", 8: "Tag",
        9: "Keyring", 10: "Media Player", 11: "Barcode Scanner", 12: "Thermometer",
        13: "Heart Rate Sensor", 14: "Blood Pressure", 15: "Human Interface Device",
        16: "Glucose Meter", 17: "Running Walking Sensor", 18: "Cycling",
        19: "Control Device", 20: "Network Device", 21: "Sensor",
        22: "Light Fixture", 23: "Fan", 24: "HVAC", 25: "Air Conditioning",
        26: "Humidifier", 27: "Heating", 28: "Access Control", 29: "Motorized Device",
        30: "Power Device", 31: "Light Source", 32: "Window Covering",
        33: "Audio Sink", 34: "Audio Source", 35: "Motorized Vehicle",
        36: "Domestic Appliance", 37: "Wearable Audio Device", 38: "Aircraft",
        39: "AV Equipment", 40: "Display Equipment", 41: "Hearing Aid",
        42: "Gaming", 43: "Signage", 49: "Pulse Oximeter", 50: "Weight Scale",
        51: "Personal Mobility Device", 52: "Continuous Glucose Monitor",
        53: "Insulin Pump", 54: "Medication Delivery", 55: "Spirometer",
        81: "Outdoor Sports Activity"
    ]

    // MARK: - Apple Continuity

    /// Names the Continuity message inside Apple manufacturer data (company 0x004C).
    ///
    /// Apple packs a one-byte type in front of each payload; recognising it tells
    /// you what an unnamed Apple device is actually doing nearby.
    static func appleContinuityType(_ type: UInt8) -> String? {
        switch type {
        case 0x01: "AirPrint"
        case 0x02: "iBeacon"
        case 0x03: "AirPrint / Discovery"
        case 0x05: "AirDrop"
        case 0x06: "HomeKit"
        case 0x07: "Proximity Pairing (AirPods)"
        case 0x08: "Hey Siri"
        case 0x09: "AirPlay Target"
        case 0x0A: "AirPlay Source"
        case 0x0B: "Magic Switch (Watch)"
        case 0x0C: "Handoff"
        case 0x0D: "Tethering Target"
        case 0x0E: "Tethering Source"
        case 0x0F: "Nearby Action"
        case 0x10: "Nearby Info"
        case 0x12: "Find My"
        default: nil
        }
    }

    private static let packedCompanies = """
    0000=Ericsson
    0001=Nokia Mobile Phones
    0002=Intel
    0003=IBM
    0004=Toshiba
    0005=3Com
    0006=Microsoft
    0007=Lucent
    0008=Motorola
    0009=Infineon
    000A=Qualcomm (CSR)
    000B=Silicon Wave
    000C=Digianswer
    000D=Texas Instruments
    000F=Broadcom
    0010=Mitel Semiconductor
    0012=Zeevo
    0013=Atmel
    0015=Philips Semiconductors
    001D=Qualcomm
    0025=NXP
    002A=Renesas
    0036=Panasonic
    003A=Panasonic
    0047=Harman International
    004C=Apple
    0056=Sony Ericsson
    0059=Nordic Semiconductor
    005D=Realtek Semiconductor
    0065=Hewlett-Packard
    0067=LG Electronics
    006B=Realtek
    0075=Samsung Electronics
    0078=Nike
    0079=Huawei
    0087=Garmin
    008A=Jawbone
    0094=Alpine Electronics
    009E=Bose
    00A0=Airoha
    00B7=Fitbit
    00C4=LG Electronics
    00CF=Logitech
    00D2=Dialog Semiconductor
    00DA=Nautilus
    00E0=Google
    00E4=Seiko Epson
    0104=Realtek
    0107=Cypress
    010F=Sennheiser
    0118=Bang & Olufsen
    0131=Cypress Semiconductor
    0141=Fossil
    0154=Zebra Technologies
    0157=Anhui Huami
    015D=Estimote
    0171=Amazon
    0180=Beats
    01A9=Yamaha
    01AB=Sonova
    01D7=Nintendo
    01DA=Xiaomi
    0211=Telink Semiconductor
    0224=Nuheara
    0238=Sonos
    0244=DJI
    0263=Roku
    027D=Huawei
    0286=Wiliot
    02D5=Netatmo
    02E5=Espressif
    02FF=Silicon Laboratories
    0310=Shenzhen Goodix
    0327=Ubiquiti
    0339=Anker
    0362=Whoop
    038F=Xiaomi
    03DA=Tuya
    0499=Ruuvi Innovations
    04D8=Oura Health
    0553=Amazfit
    05A7=Sonos
    0644=Tile
    064C=Ring
    0757=SharkNinja
    07A6=Signify (Philips Hue)
    0822=Belkin
    """
}
