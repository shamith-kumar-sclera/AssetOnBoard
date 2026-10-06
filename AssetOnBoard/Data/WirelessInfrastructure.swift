//
//  WirelessInfrastructure.swift
//  AssetOnBoard
//
//  Recognising Wi-Fi hardware that is in radio range but not on your network.
//
//  iOS cannot enumerate nearby SSIDs, so there is no direct way to see the
//  access points around you. There is an indirect one: almost every router,
//  mesh node and managed AP shipped in the last few years keeps a Bluetooth LE
//  radio advertising for its setup app, and unlike Wi-Fi, BLE advertisements are
//  something an App Store app is allowed to listen to. A device answering to
//  "eero-1a2b" or "UniFi-AP" a few metres away is an access point, whether or
//  not you are joined to it.
//
//  This is inference, not a scan, and the scoring reflects that: a name prefix
//  match is strong evidence, a vendor identifier alone is weak, and nothing here
//  ever claims to have read an SSID.
//

import Foundation

nonisolated struct InfrastructureMatch: Sendable, Hashable {
    /// Vendor or product family the signature belongs to.
    let family: String
    /// What matched, phrased for display: "Advertised name begins eero-".
    let evidence: String
    /// 0-1. Only the name prefixes get anywhere near certainty.
    let confidence: Double
}

nonisolated enum WirelessInfrastructure {

    // MARK: - Bluetooth signatures

    /// Advertised-name prefixes used by access point and mesh hardware.
    ///
    /// These are the dependable signal. Setup-mode radios name themselves after
    /// the product line so their own app can find them, which is exactly what
    /// makes them identifiable here.
    private static let namePrefixes: [(prefix: String, family: String)] = [
        ("eero", "eero"),
        ("unifi", "Ubiquiti UniFi"), ("ubnt", "Ubiquiti"), ("amplifi", "Ubiquiti AmpliFi"),
        ("nest wifi", "Google Nest Wifi"), ("google wifi", "Google Wifi"), ("googlewifi", "Google Wifi"),
        ("deco", "TP-Link Deco"), ("tp-link_", "TP-Link"), ("archer", "TP-Link Archer"),
        ("omada", "TP-Link Omada"), ("eap", "TP-Link EAP"),
        ("orbi", "NETGEAR Orbi"), ("netgear", "NETGEAR"), ("nighthawk", "NETGEAR Nighthawk"),
        ("velop", "Linksys Velop"), ("linksys", "Linksys"),
        ("zenwifi", "ASUS ZenWiFi"), ("rt-ax", "ASUS"), ("rt-ac", "ASUS"), ("asus", "ASUS"),
        ("aruba", "Aruba"), ("instant on", "Aruba Instant On"),
        ("meraki", "Cisco Meraki"), ("ruckus", "Ruckus"), ("engenius", "EnGenius"),
        ("mikrotik", "MikroTik"), ("cudy", "Cudy"), ("tenda", "Tenda"), ("mercusys", "Mercusys"),
        ("plume", "Plume"), ("superpod", "Plume SuperPod"),
        ("starlink", "Starlink"), ("fritz", "AVM FRITZ!Box"),
        ("xfinity", "Xfinity Gateway"), ("cox panoramic", "Cox Panoramic"),
        ("sky ", "Sky Broadband"), ("bt hub", "BT Hub"), ("vodafone", "Vodafone"),
        ("esp_", "Espressif SoftAP"), ("prov_", "Espressif provisioning")
    ]

    /// Bluetooth SIG company identifiers belonging to networking vendors.
    ///
    /// Weak on its own — Google and Amazon put their identifier on speakers and
    /// remotes too — so this only ever corroborates a stronger signal.
    private static let companyIdentifiers: [UInt16: String] = [
        0x0327: "Ubiquiti",
        0x00E0: "Google",
        0x0171: "Amazon"
    ]

    /// Service UUIDs advertised by Wi-Fi provisioning profiles.
    private static let provisioningServices: [String: String] = [
        "021A9004-0382-4AEA-BFF4-6B3F1C5ADFB4": "Espressif Wi-Fi provisioning",
        "0000FD3D-0000-1000-8000-00805F9B34FB": "Wi-Fi Easy Connect"
    ]

    /// Decides whether a Bluetooth peripheral is access-point-class hardware.
    ///
    /// Takes the advertisement as-is; nothing here requires connecting.
    static func identify(name: String?,
                         localName: String?,
                         companyIdentifier: UInt16?,
                         serviceUUIDs: [String]) -> InfrastructureMatch? {
        var best: InfrastructureMatch?
        func consider(_ match: InfrastructureMatch) {
            if let current = best, current.confidence >= match.confidence { return }
            best = match
        }

        for label in [name, localName].compactMap({ $0 }) {
            let lowered = label.lowercased().trimmingCharacters(in: .whitespaces)
            guard !lowered.isEmpty else { continue }
            for entry in namePrefixes where lowered.hasPrefix(entry.prefix) {
                consider(InfrastructureMatch(family: entry.family,
                                             evidence: "Advertised name “\(label)”",
                                             confidence: 0.85))
            }
        }

        let advertised = Set(serviceUUIDs.map { $0.uppercased() })
        for (uuid, family) in provisioningServices where advertised.contains(uuid) {
            consider(InfrastructureMatch(family: family,
                                         evidence: "Advertises a Wi-Fi provisioning service",
                                         confidence: 0.7))
        }

        // A networking vendor's identifier only counts once something else has
        // already suggested this is infrastructure.
        if let companyIdentifier, let vendor = companyIdentifiers[companyIdentifier], best != nil {
            consider(InfrastructureMatch(family: vendor,
                                         evidence: "\(vendor) Bluetooth company identifier",
                                         confidence: min(0.9, (best?.confidence ?? 0) + 0.05)))
        }

        return best
    }

    // MARK: - Text signatures

    /// Words that identify routing or Wi-Fi gear in a UPnP or mDNS description.
    private static let productWords: [String] = [
        "access point", "accesspoint", "wireless router", "wifi router", "wi-fi router",
        "mesh", "repeater", "range extender", "wireless bridge", "gateway router",
        "eero", "unifi", "ubiquiti", "amplifi", "orbi", "nighthawk", "deco", "omada",
        "velop", "zenwifi", "airport", "time capsule", "fritz!box", "livebox", "speedport",
        "openwrt", "dd-wrt", "routeros", "mikrotik", "asuswrt", "meraki", "aruba",
        "ruckus", "engenius", "draytek", "zyxel", "tenda", "mercusys", "cudy", "plume"
    ]

    static func textSuggestsAccessPoint(_ lowercasedText: String) -> Bool {
        productWords.contains { lowercasedText.contains($0) }
    }

    /// mDNS service types published by access points and their controllers.
    static let bonjourServiceTypes: Set<String> = [
        "_airport._tcp", "_sleep-proxy._udp", "_ubnt._tcp", "_unifi._tcp",
        "_eero._tcp", "_googlezone._tcp", "_mesh._tcp", "_wifi._tcp"
    ]
}
