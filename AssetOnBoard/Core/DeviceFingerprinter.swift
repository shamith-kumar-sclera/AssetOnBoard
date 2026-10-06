//
//  DeviceFingerprinter.swift
//  AssetOnBoard
//
//  Turns raw observations into a device type, model and OS guess.
//
//  No single signal is trustworthy on its own, so each one votes with a weight
//  and the highest-scoring category wins. Self-reported model strings from mDNS
//  are near-certain; an open port is only a hint.
//

import Foundation

nonisolated enum DeviceFingerprinter {

    /// Fills in `category`, `modelName`, `operatingSystem` and `confidence`.
    static func classify(_ device: inout NetworkDevice) {
        var scores: [DeviceCategory: Double] = [:]
        func vote(_ category: DeviceCategory, _ weight: Double) {
            scores[category, default: 0] += weight
        }

        let ports = Set(device.openPorts.map(\.port))
        let serviceTypes = Set(device.bonjourServices.map(\.serviceType))
        let vendor = device.vendor?.lowercased() ?? ""
        let textCorpus = buildCorpus(device).lowercased()

        // 1. Self-reported hardware model — the strongest signal there is.
        if let identifier = device.bonjourServices.compactMap(\.advertisedModel).first {
            device.modelIdentifier = identifier
            if let resolved = AppleModelCatalog.name(for: identifier) {
                device.modelName = resolved.name
                vote(resolved.category, 10)
                device.operatingSystem = resolved.operatingSystem
            } else {
                device.modelName = identifier
                vote(categoryFromModelString(identifier) ?? .unknown, 4)
            }
        }

        // 2. Advertised services.
        for type in serviceTypes {
            switch type {
            case "_airplay._tcp", "_mediaremotetv._tcp", "_androidtvremote2._tcp",
                 "_googlecast._tcp", "_amzn-wplay._tcp", "_roku._tcp", "_rsp._tcp",
                 "_viziocast._tcp":
                vote(.tv, 5)
            case "_raop._tcp", "_sonos._tcp", "_spotify-connect._tcp":
                vote(.speaker, 5)
            case "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp",
                 "_scanner._tcp", "_uscan._tcp", "_uscans._tcp", "_ipp-tls._tcp":
                vote(.printer, 8)
            case "_adisk._tcp", "_afpovertcp._tcp", "_smb._tcp", "_nfs._tcp":
                vote(.nas, 3)
            case "_hap._tcp", "_homekit._tcp", "_hue._tcp", "_esphomelib._tcp",
                 "_matter._tcp", "_matterc._udp", "_miio._udp", "_ewelink._tcp":
                vote(.smartHome, 6)
            case "_apple-mobdev2._tcp":
                vote(.phone, 4)
            case "_workstation._tcp", "_rfb._tcp", "_sftp-ssh._tcp":
                vote(.computer, 4)
            case "_companion-link._tcp", "_rdlink._tcp":
                vote(.computer, 1.5)
            case "_airport._tcp":
                vote(.router, 8)
            case "_plexmediasvr._tcp", "_nvstream._tcp":
                vote(.server, 3)
            default:
                break
            }
        }

        // HomeKit accessories publish a numeric category in their TXT record.
        if let accessory = device.bonjourServices.first(where: { $0.serviceType == "_hap._tcp" }),
           let raw = accessory.txtRecord["ci"], let categoryID = Int(raw) {
            vote(homeKitCategory(categoryID), 6)
        }

        // 3. NetBIOS. A node-status reply is near-conclusive evidence of a
        //    Windows or Samba host, and it often arrives from machines whose
        //    firewall drops every TCP probe, leaving no other signal at all.
        if let netbios = device.netbios {
            vote(netbios.isDomainController ? .server : .computer, 6)
            if netbios.services.contains("File Server") { vote(.computer, 1) }
        }

        // 4. Open ports.
        if ports.contains(62078) { vote(.phone, 7) }
        if ports.contains(9100) || ports.contains(515) || ports.contains(631) { vote(.printer, 5) }
        if ports.contains(445) || ports.contains(139) { vote(.computer, 2) }
        if ports.contains(3389) { vote(.computer, 3) }
        if ports.contains(548) || ports.contains(5900) { vote(.computer, 2) }
        if ports.contains(5000) && ports.contains(5001) { vote(.nas, 4) }
        if ports.contains(32400) || ports.contains(8096) { vote(.server, 3) }
        if ports.contains(554) { vote(.camera, 4) }
        if ports.contains(8008) || ports.contains(8009) || ports.contains(8060) { vote(.tv, 4) }
        if ports.contains(1400) { vote(.speaker, 6) }
        if ports.contains(5555) { vote(.phone, 2) }
        if ports.contains(1883) || ports.contains(8883) { vote(.smartHome, 2) }
        if ports.contains(3306) || ports.contains(5432) || ports.contains(27017)
            || ports.contains(6379) || ports.contains(9200) { vote(.server, 3) }
        if ports.contains(53) && ports.contains(80) { vote(.router, 2) }
        if ports.contains(22) && ports.contains(80) { vote(.server, 1) }

        // 5. Vendor.
        switch true {
        case vendor.contains("apple"): vote(.computer, 1)
        case vendor.contains("netgear"), vendor.contains("tp-link"), vendor.contains("d-link"),
             vendor.contains("zyxel"), vendor.contains("arcadyan"), vendor.contains("sagemcom"),
             vendor.contains("technicolor"), vendor.contains("arris"), vendor.contains("mikrotik"),
             vendor.contains("linksys"), vendor.contains("edimax"):
            vote(.router, 5)
        case vendor.contains("ubiquiti"), vendor.contains("aruba"), vendor.contains("meraki"):
            vote(.accessPoint, 5)
        case vendor.contains("brother"), vendor.contains("epson"), vendor.contains("canon"),
             vendor.contains("kyocera"), vendor.contains("ricoh"), vendor.contains("xerox"),
             vendor.contains("konica"), vendor.contains("sharp"):
            vote(.printer, 5)
        case vendor.contains("synology"), vendor.contains("qnap"), vendor.contains("western digital"):
            vote(.nas, 6)
        case vendor.contains("sonos"): vote(.speaker, 7)
        case vendor.contains("roku"), vendor.contains("vizio"): vote(.tv, 7)
        case vendor.contains("nintendo"), vendor.contains("sony interactive"), vendor.contains("xbox"):
            vote(.gameConsole, 8)
        case vendor.contains("espressif"), vendor.contains("tuya"), vendor.contains("signify"),
             vendor.contains("nest"), vendor.contains("ring"), vendor.contains("netatmo"):
            vote(.smartHome, 6)
        case vendor.contains("raspberry"): vote(.server, 4)
        case vendor.contains("vmware"), vendor.contains("virtualbox"), vendor.contains("qemu"),
             vendor.contains("parallels"), vendor.contains("hyper-v"):
            vote(.virtualMachine, 9)
        case vendor.contains("samsung"), vendor.contains("xiaomi"), vendor.contains("huawei"),
             vendor.contains("lg electronics"):
            vote(.phone, 1)
        case vendor.contains("intel"), vendor.contains("dell"), vendor.contains("lenovo"),
             vendor.contains("hewlett"), vendor.contains("asustek"), vendor.contains("giga-byte"):
            vote(.computer, 3)
        case vendor.contains("amazon"): vote(.tv, 2); vote(.speaker, 2)
        default: break
        }

        // 6. Free text from HTTP titles, certificates and banners.
        for (needle, category, weight) in Self.textSignals where textCorpus.contains(needle) {
            vote(category, weight)
        }

        // 7. Gateways are routers unless something much stronger disagrees.
        if device.isGateway { vote(.router, 6) }
        if device.isThisDevice { vote(.phone, 8) }

        // 8. Operating system, mostly from banners and TTL.
        device.operatingSystem = device.operatingSystem ?? inferOperatingSystem(device, corpus: textCorpus)

        let ranked = scores.sorted { $0.value > $1.value }
        if let best = ranked.first, best.value >= 1 {
            device.category = best.key
            let runnerUp = ranked.dropFirst().first?.value ?? 0
            // Confidence reflects both the absolute score and how clearly it beat
            // the alternatives, so a lone weak hint never reads as certainty.
            let margin = (best.value - runnerUp) / max(best.value, 1)
            device.confidence = min(1, (best.value / 12) * 0.7 + margin * 0.3)
        } else {
            device.category = .unknown
            device.confidence = 0
        }
    }

    // MARK: - Signals

    private static let textSignals: [(String, DeviceCategory, Double)] = [
        ("synology", .nas, 7), ("diskstation", .nas, 7), ("qnap", .nas, 7),
        ("truenas", .nas, 7), ("freenas", .nas, 7), ("unraid", .nas, 6),
        ("openwrt", .router, 7), ("dd-wrt", .router, 7), ("pfsense", .router, 7),
        ("opnsense", .router, 7), ("mikrotik", .router, 7), ("routeros", .router, 7),
        ("fritz!box", .router, 7), ("asuswrt", .router, 7), ("tomato", .router, 5),
        ("unifi", .accessPoint, 6), ("ubnt", .accessPoint, 6), ("aruba", .accessPoint, 5),
        ("hp laserjet", .printer, 8), ("officejet", .printer, 8), ("deskjet", .printer, 8),
        ("brother", .printer, 6), ("epson", .printer, 6), ("cups", .printer, 5),
        ("printer", .printer, 4), ("ipp everywhere", .printer, 5),
        ("hikvision", .camera, 8), ("dahua", .camera, 8), ("axis", .camera, 5),
        ("reolink", .camera, 8), ("onvif", .camera, 7), ("ip camera", .camera, 7),
        ("nvr", .camera, 5), ("webcam", .camera, 4),
        ("home assistant", .smartHome, 8), ("homebridge", .smartHome, 7),
        ("tasmota", .smartHome, 8), ("esphome", .smartHome, 8), ("shelly", .smartHome, 8),
        ("philips hue", .smartHome, 8), ("hue bridge", .smartHome, 8),
        ("plex", .server, 6), ("jellyfin", .server, 6), ("emby", .server, 6),
        ("portainer", .server, 5), ("grafana", .server, 5), ("proxmox", .server, 7),
        ("nextcloud", .server, 5), ("gitlab", .server, 5), ("jenkins", .server, 5),
        ("apache", .server, 1), ("nginx", .server, 1), ("openresty", .server, 1),
        ("chromecast", .tv, 8), ("android tv", .tv, 8), ("roku", .tv, 8),
        ("fire tv", .tv, 8), ("apple tv", .tv, 8), ("smartcast", .tv, 7),
        ("webos", .tv, 8), ("tizen", .tv, 7), ("bravia", .tv, 7),
        ("sonos", .speaker, 8), ("homepod", .speaker, 8), ("bose", .speaker, 6),
        ("playstation", .gameConsole, 9), ("xbox", .gameConsole, 9), ("nintendo", .gameConsole, 9),
        ("raspberry pi", .server, 5), ("openmediavault", .nas, 6),
        ("windows", .computer, 3), ("macbook", .computer, 6), ("imac", .computer, 6)
    ]

    private static func inferOperatingSystem(_ device: NetworkDevice, corpus: String) -> String? {
        if let ssh = device.openPorts.first(where: { $0.port == 22 || $0.port == 2222 })?.banner {
            if ssh.contains("OpenSSH") {
                if ssh.contains("Ubuntu") { return "Linux (Ubuntu)" }
                if ssh.contains("Debian") { return "Linux (Debian)" }
                if ssh.contains("Raspbian") { return "Raspberry Pi OS" }
                if ssh.contains("FreeBSD") { return "FreeBSD" }
                if let version = ssh.range(of: "OpenSSH_") {
                    let tail = ssh[version.upperBound...].prefix(while: { !$0.isWhitespace })
                    return "OpenSSH \(tail)"
                }
            }
            if ssh.contains("dropbear") { return "Embedded Linux (Dropbear)" }
        }
        if device.netbios != nil { return "Windows / SMB" }
        if corpus.contains("darwin") || corpus.contains("macos") { return "macOS" }
        if corpus.contains("ubuntu") { return "Linux (Ubuntu)" }
        if corpus.contains("debian") { return "Linux (Debian)" }
        if corpus.contains("openwrt") { return "OpenWrt" }

        // TTL is a coarse but genuine fingerprint: stacks start at 64, 128 or 255
        // and every hop decrements it. On a flat LAN there are no hops at all.
        switch device.ttl {
        case .some(let value) where value > 200: return "Network appliance (BSD-family stack)"
        case .some(let value) where value > 100: return "Windows-family stack"
        case .some(let value) where value > 32: return "Unix-family stack"
        default: return nil
        }
    }

    private static func buildCorpus(_ device: NetworkDevice) -> String {
        var parts: [String] = device.hostnames
        parts.append(contentsOf: device.bonjourServices.map(\.instanceName))
        parts.append(contentsOf: device.bonjourServices.flatMap { $0.txtRecord.values })
        for port in device.openPorts {
            parts.append(contentsOf: [port.httpTitle, port.httpServer, port.httpRealm, port.banner].compactMap { $0 })
            parts.append(contentsOf: port.certificates.compactMap(\.displayName))
            parts.append(contentsOf: port.certificates.compactMap(\.issuerOrganization))
        }
        if let netbios = device.netbios {
            parts.append(contentsOf: [netbios.computerName, netbios.workgroup].compactMap { $0 })
        }
        return parts.joined(separator: " ")
    }

    private static func categoryFromModelString(_ model: String) -> DeviceCategory? {
        let lowered = model.lowercased()
        if lowered.hasPrefix("iphone") { return .phone }
        if lowered.hasPrefix("ipad") { return .tablet }
        if lowered.hasPrefix("watch") { return .wearable }
        if lowered.hasPrefix("appletv") { return .tv }
        if lowered.hasPrefix("audioaccessory") { return .speaker }
        if lowered.hasPrefix("airport") { return .router }
        if lowered.contains("mac") || lowered.contains("book") { return .computer }
        return nil
    }

    /// HomeKit accessory category identifiers from the HAP specification.
    private static func homeKitCategory(_ identifier: Int) -> DeviceCategory {
        switch identifier {
        case 2, 3, 5, 7, 8, 9, 10, 12, 13, 14, 15, 16, 21, 22, 23, 26, 28, 29, 30, 31, 32, 33, 34:
            return .smartHome
        case 17, 18, 19, 20: return .camera
        case 24, 25: return .tv
        case 27: return .speaker
        default: return .smartHome
        }
    }
}
