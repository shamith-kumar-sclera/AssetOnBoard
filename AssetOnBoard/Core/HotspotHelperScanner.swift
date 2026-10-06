//
//  HotspotHelperScanner.swift
//  AssetOnBoard
//
//  The iOS translation of Android's WifiManager scan — and the reasons it is
//  not equivalent.
//
//  Android:  wifi.startScan()  ->  SCAN_RESULTS_AVAILABLE_ACTION  ->  wifi.scanResults
//  iOS:      (no equivalent)   ->  iOS calls you when it wants    ->  command.networkList
//
//  Three differences matter, and none of them are fixable in code:
//
//  1. ENTITLEMENT. `NEHotspotHelper.register` returns false unless the app
//     carries `com.apple.developer.networking.HotspotHelper`, which Apple grants
//     only by written application, essentially to captive-network and carrier
//     Wi-Fi vendors. Without it every method here runs and finds nothing. Adding
//     the entitlement to the plist without the matching provisioning profile
//     breaks code signing, so it is documented in the README rather than set.
//
//  2. PUSH, NOT PULL. There is no startScan(). You register a handler and iOS
//     invokes it with a FilterScanList command when the system is scanning
//     anyway — typically while the user is in Wi-Fi settings. An app cannot ask
//     for a sweep, so "refresh" is not a thing that can be offered.
//
//  3. LESS DATA. NEHotspotNetwork carries SSID, BSSID, a normalised 0-1 signal
//     and a secure flag. There is no frequency, no channel, and no capabilities
//     string — so the RSN/WPA information element your Android code parses has
//     no counterpart here. Channel and band stay empty for networks from this
//     source; only the Mac helper can fill them.
//

import Foundation
import NetworkExtension
import Observation

@Observable
final class HotspotHelperScanner {

    enum Status: Equatable {
        case notRegistered
        case unavailable(String)
        case waiting
        case receiving(Date)

        var message: String {
            switch self {
            case .notRegistered:
                "Not registered."
            case .unavailable(let reason):
                reason
            case .waiting:
                "Registered. iOS delivers a scan list only when it chooses to — usually while the Wi-Fi settings screen is open. There is no way to request one."
            case .receiving(let date):
                "Last scan list from iOS at \(date.formatted(date: .omitted, time: .standard))."
            }
        }
    }

    private(set) var status: Status = .notRegistered
    private(set) var networks: [WiFiNetwork] = []
    /// Scan lists iOS has handed over since launch.
    private(set) var deliveries = 0

    private let queue = DispatchQueue(label: "com.sclera.assetonboard.hotspot")

    /// Registers as a hotspot helper. Call once, at launch.
    ///
    /// Returns false when the entitlement is absent, which is the normal case.
    @discardableResult
    func register(displayName: String = "AssetOnBoard") -> Bool {
        let options: [String: NSObject] = [
            kNEHotspotHelperOptionDisplayName: displayName as NSString
        ]

        let registered = NEHotspotHelper.register(options: options, queue: queue) { [weak self] command in
            self?.handle(command)
        }

        if !registered {
            status = .unavailable("""
                iOS refused the hotspot-helper registration. This needs the \
                com.apple.developer.networking.HotspotHelper entitlement, which \
                Apple issues only on application to captive-network providers, \
                plus 'network-authentication' in UIBackgroundModes. Without it \
                no iOS API returns the list of networks in range.
                """)
        } else {
            status = .waiting
        }
        return registered
    }

    // MARK: - Command handling

    /// Every command must be answered, or iOS stops delivering them.
    private func handle(_ command: NEHotspotHelperCommand) {
        switch command.commandType {
        case .filterScanList:
            // This is the one that matters: the scan list Android would have
            // handed you from wifi.scanResults.
            let found = (command.networkList ?? []).map(Self.convert)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.networks = found.sorted { $0.rssi > $1.rssi }
                self.deliveries += 1
                self.status = .receiving(Date())
            }

            // We are an inventory tool, not a captive-network client: hand the
            // list back untouched rather than filtering anything out of the
            // user's Wi-Fi picker.
            let response = command.createResponse(.success)
            response.setNetworkList(command.networkList ?? [])
            response.deliver()

        case .evaluate:
            // Say we cannot help with this network, so iOS stops offering it.
            let response = command.createResponse(.unsupportedNetwork)
            response.deliver()

        case .authenticate, .maintain, .logoff, .presentUI, .none:
            command.createResponse(.unsupportedNetwork).deliver()

        @unknown default:
            command.createResponse(.unsupportedNetwork).deliver()
        }
    }

    /// NEHotspotNetwork carries strictly less than Android's ScanResult.
    private static func convert(_ network: NEHotspotNetwork) -> WiFiNetwork {
        // signalStrength is normalised 0-1, not dBm. Mapping it onto the usual
        // -100…-30 dBm scale keeps one sort order across both survey sources;
        // `signalPercent` preserves what iOS actually said.
        let percent = network.signalStrength
        let approximateRSSI = Int((percent * 70) - 100)

        return WiFiNetwork(
            ssid: network.ssid.isEmpty ? nil : network.ssid,
            bssid: network.bssid.isEmpty ? nil : network.bssid,
            rssi: approximateRSSI,
            channel: 0,          // iOS does not report frequency or channel
            band: "Unknown",
            width: 0,
            security: network.isSecure ? "Secured" : "Open",
            isCurrent: network.didAutoJoin || network.didJustJoin,
            source: .hotspotHelper,
            signalPercent: percent
        )
    }
}
