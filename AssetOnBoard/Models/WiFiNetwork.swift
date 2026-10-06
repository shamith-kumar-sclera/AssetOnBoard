//
//  WiFiNetwork.swift
//  AssetOnBoard
//
//  One Wi-Fi network in range, as surveyed by a helper on a Mac.
//
//  Nothing in this file can be filled in by iOS itself. It exists because the
//  scan has to happen somewhere that is allowed to perform it.
//

import Foundation

/// Where a survey row came from. The two sources see different things, and
/// the UI has to be able to say which, because neither is a full picture.
nonisolated enum SurveySource: String, Sendable, Codable {
    /// CoreWLAN on a Mac: SSID, BSSID, real dBm, channel, band, width.
    case macHelper = "Mac helper"
    /// NEHotspotHelper on this device: SSID, BSSID, a 0-1 signal, secure flag.
    /// No channel and no frequency — iOS does not report them.
    case hotspotHelper = "iOS hotspot helper"
}

nonisolated struct WiFiNetwork: Sendable, Codable, Hashable {
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var channel: Int
    var band: String
    var width: Int
    var security: String
    var isCurrent: Bool
    var source: SurveySource = .macHelper
    /// iOS's normalised 0-1 signal, when that is what the source reported.
    var signalPercent: Double?

    /// The network name, or an honest stand-in for why there isn't one.
    var displayName: String {
        if let ssid, !ssid.isEmpty { return ssid }
        // A network with no name is either hidden, or macOS withheld it.
        return "Unnamed network"
    }

    var macAddress: MACAddress? { bssid.flatMap { MACAddress($0) } }

    /// Manufacturer of the access point radio, from the BSSID's OUI.
    var vendor: String? { macAddress.flatMap { OUIDatabase.vendor(for: $0) } }

    /// "Channel 44 · 5 GHz · 80 MHz", or an honest note when the source
    /// cannot report the radio details at all.
    var radioSummary: String {
        guard channel > 0 else {
            return signalPercent.map { "Signal \(Int($0 * 100))% · channel not reported by iOS" }
                ?? "Channel not reported"
        }
        var parts = ["Channel \(channel)", band]
        if width > 0 { parts.append("\(width) MHz") }
        return parts.joined(separator: " · ")
    }

    var isOpen: Bool { security == "Open" }

    /// Decoded leniently so the helper and the app can be updated separately.
    ///
    /// Swift's synthesised `init(from:)` throws on a missing key even when the
    /// property has a default, so fields added on this side after the helper
    /// shipped have to be pulled with `decodeIfPresent` or an older helper's
    /// JSON stops decoding entirely.
    init(ssid: String?,
         bssid: String?,
         rssi: Int,
         channel: Int,
         band: String,
         width: Int,
         security: String,
         isCurrent: Bool,
         source: SurveySource = .macHelper,
         signalPercent: Double? = nil) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.channel = channel
        self.band = band
        self.width = width
        self.security = security
        self.isCurrent = isCurrent
        self.source = source
        self.signalPercent = signalPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ssid = try container.decodeIfPresent(String.self, forKey: .ssid)
        bssid = try container.decodeIfPresent(String.self, forKey: .bssid)
        rssi = try container.decodeIfPresent(Int.self, forKey: .rssi) ?? -100
        channel = try container.decodeIfPresent(Int.self, forKey: .channel) ?? 0
        band = try container.decodeIfPresent(String.self, forKey: .band) ?? "Unknown"
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
        security = try container.decodeIfPresent(String.self, forKey: .security) ?? "Unknown"
        isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
        source = try container.decodeIfPresent(SurveySource.self, forKey: .source) ?? .macHelper
        signalPercent = try container.decodeIfPresent(Double.self, forKey: .signalPercent)
    }

    /// Coarse signal bucket, matching the Bluetooth tab's vocabulary.
    var signalStrength: BluetoothDevice.SignalStrength {
        switch rssi {
        case (-55)...: .excellent
        case (-70)..<(-55): .good
        case (-85)..<(-70): .fair
        default: .weak
        }
    }
}

nonisolated struct WiFiSurvey: Sendable, Codable {
    var scannedAt: Date
    var hostName: String
    var interface: String
    /// False when macOS withheld network names for want of location access.
    var locationGranted: Bool
    var networks: [WiFiNetwork]

    /// Networks with a real name, strongest first.
    var named: [WiFiNetwork] { networks.filter { $0.ssid?.isEmpty == false } }

    /// Distinct SSIDs — a mesh publishes one name from several radios.
    var distinctNetworkCount: Int {
        Set(networks.compactMap(\.ssid).filter { !$0.isEmpty }).count
    }

    var bandCounts: [String: Int] {
        Dictionary(grouping: networks, by: \.band).mapValues(\.count)
    }
}
