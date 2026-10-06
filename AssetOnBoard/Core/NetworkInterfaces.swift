//
//  NetworkInterfaces.swift
//  AssetOnBoard
//
//  Enumerates the device's own IPv4 interfaces via getifaddrs(3).
//

import Foundation
import Darwin

nonisolated struct LocalInterface: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case wifi = "Wi-Fi"
        case wired = "Ethernet"
        case cellular = "Cellular"
        case hotspot = "Personal Hotspot"
        case vpn = "VPN"
        case awdl = "AirDrop"
        case other = "Other"

        var symbolName: String {
            switch self {
            case .wifi: "wifi"
            case .wired: "cable.connector"
            case .cellular: "antenna.radiowaves.left.and.right"
            case .hotspot: "personalhotspot"
            case .vpn: "lock.shield"
            case .awdl: "shareplay"
            case .other: "network"
            }
        }
    }

    let name: String
    let address: IPv4
    let netmask: IPv4
    let kind: Kind

    var id: String { "\(name)-\(address)" }
    var subnet: IPv4Subnet { IPv4Subnet(address: address, netmask: netmask) }

    /// Interfaces worth sweeping: a real LAN segment we are attached to.
    ///
    /// Cellular has no local peers, VPN tunnels are point-to-point, and AWDL is
    /// Apple's peer-to-peer link rather than the network the user joined.
    var isScannable: Bool {
        switch kind {
        case .wifi, .wired, .hotspot: true
        case .cellular, .vpn, .awdl, .other: false
        }
    }

    static func kind(forBSDName name: String) -> Kind {
        if name == "en0" { return .wifi }
        if name.hasPrefix("bridge") { return .hotspot }
        if name.hasPrefix("pdp_ip") { return .cellular }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return .vpn }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .awdl }
        if name.hasPrefix("en") { return .wired }
        return .other
    }
}

nonisolated enum NetworkInterfaceScanner {

    /// Returns every up-and-running IPv4 interface, loopback excluded.
    static func current() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [LocalInterface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP,
                  flags & IFF_RUNNING == IFF_RUNNING,
                  flags & IFF_LOOPBACK == 0,
                  let rawAddress = entry.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == sa_family_t(AF_INET),
                  let rawNetmask = entry.pointee.ifa_netmask
            else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            let address = rawAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                IPv4(networkOrder: $0.pointee.sin_addr.s_addr)
            }
            let netmask = rawNetmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                IPv4(networkOrder: $0.pointee.sin_addr.s_addr)
            }
            guard !address.isLoopback, netmask.raw != 0 else { continue }

            results.append(LocalInterface(name: name,
                                          address: address,
                                          netmask: netmask,
                                          kind: LocalInterface.kind(forBSDName: name)))
        }
        return results
    }

    /// The interface a LAN scan should run on, preferring Wi-Fi over wired.
    static func preferredScanInterface() -> LocalInterface? {
        let candidates = current().filter(\.isScannable)
        let priority: [LocalInterface.Kind] = [.wifi, .wired, .hotspot]
        for kind in priority {
            if let match = candidates.first(where: { $0.kind == kind }) { return match }
        }
        return candidates.first
    }
}
