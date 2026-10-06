//
//  BonjourDiscovery.swift
//  AssetOnBoard
//
//  Passive device discovery over mDNS / DNS-SD.
//
//  This is the single richest source of identity on iOS. Devices advertise their
//  own model strings, friendly names and — for AirPlay, AirPlay-audio and Avahi
//  workstations — their MAC address, none of which any active probe can reach
//  from inside the sandbox.
//

import Foundation
import Network

nonisolated struct BonjourService: Sendable, Hashable, Codable, Identifiable {
    var instanceName: String
    var serviceType: String
    var domain: String
    var txtRecord: [String: String]
    var addresses: [IPv4]
    var port: UInt16?

    var id: String { "\(instanceName).\(serviceType).\(domain)" }

    /// Human label for the protocol, e.g. `_airplay._tcp` -> "AirPlay".
    var friendlyProtocolName: String {
        BonjourDiscovery.friendlyNames[serviceType] ?? serviceType
    }

    /// MAC addresses a service advertises about itself.
    ///
    /// Three well-known conventions carry one:
    /// `_airplay` TXT `deviceid`, `_raop` instance names (`AABBCC…@Speaker`),
    /// and Avahi's `_workstation` names (`host [aa:bb:cc:dd:ee:ff]`).
    var advertisedMAC: MACAddress? {
        if let deviceID = txtRecord["deviceid"], let mac = MACAddress(deviceID) { return mac }
        if let raw = txtRecord["mac"] ?? txtRecord["MAC"], let mac = MACAddress(raw) { return mac }

        if serviceType.hasPrefix("_raop"), let separator = instanceName.firstIndex(of: "@") {
            let hex = String(instanceName[instanceName.startIndex..<separator])
            if hex.count == 12 {
                let pairs = stride(from: 0, to: 12, by: 2).map { offset -> String in
                    let start = hex.index(hex.startIndex, offsetBy: offset)
                    return String(hex[start..<hex.index(start, offsetBy: 2)])
                }
                if let mac = MACAddress(pairs.joined(separator: ":")) { return mac }
            }
        }

        if let open = instanceName.firstIndex(of: "["), let close = instanceName.firstIndex(of: "]"),
           open < close {
            let candidate = String(instanceName[instanceName.index(after: open)..<close])
            if let mac = MACAddress(candidate) { return mac }
        }
        return nil
    }

    /// The model identifier a device volunteers about itself, if any.
    var advertisedModel: String? {
        for key in ["model", "am", "md", "usb_MDL", "ty", "product", "MDL"] {
            if let value = txtRecord[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// A display name the device chose for itself.
    var advertisedFriendlyName: String? {
        for key in ["fn", "n", "name", "CtlN", "friendlyName"] {
            if let value = txtRecord[key], !value.isEmpty { return value }
        }
        return nil
    }
}

nonisolated final class BonjourDiscovery: @unchecked Sendable {

    /// Every type here must also appear in `NSBonjourServices` in Info.plist or
    /// iOS silently returns nothing for it.
    static let serviceTypes: [String] = [
        "_device-info._tcp", "_airplay._tcp", "_raop._tcp", "_companion-link._tcp",
        "_rdlink._tcp", "_sleep-proxy._udp", "_apple-mobdev2._tcp", "_touch-able._tcp",
        "_mediaremotetv._tcp", "_homekit._tcp", "_hap._tcp", "_adisk._tcp",
        "_daap._tcp", "_dacp._tcp", "_airport._tcp",
        "_googlecast._tcp", "_androidtvremote2._tcp", "_amzn-wplay._tcp",
        "_spotify-connect._tcp", "_sonos._tcp", "_roku._tcp", "_rsp._tcp",
        "_http._tcp", "_https._tcp", "_workstation._tcp", "_ssh._tcp",
        "_sftp-ssh._tcp", "_telnet._tcp", "_rfb._tcp", "_smb._tcp",
        "_afpovertcp._tcp", "_nfs._tcp", "_webdav._tcp", "_ftp._tcp",
        "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp",
        "_scanner._tcp", "_uscan._tcp", "_uscans._tcp",
        "_hue._tcp", "_esphomelib._tcp", "_matter._tcp", "_matterc._udp",
        "_miio._udp", "_ewelink._tcp", "_viziocast._tcp", "_plexmediasvr._tcp",
        "_nvstream._tcp", "_teamviewer._tcp", "_ldap._tcp", "_ipp-tls._tcp"
    ]

    static let friendlyNames: [String: String] = [
        "_device-info._tcp": "Device Info", "_airplay._tcp": "AirPlay",
        "_raop._tcp": "AirPlay Audio", "_companion-link._tcp": "Apple Continuity",
        "_rdlink._tcp": "Apple Remote Desktop", "_sleep-proxy._udp": "Bonjour Sleep Proxy",
        "_apple-mobdev2._tcp": "iOS Wi-Fi Sync", "_touch-able._tcp": "Apple Remote",
        "_mediaremotetv._tcp": "Apple TV Remote", "_homekit._tcp": "HomeKit",
        "_hap._tcp": "HomeKit Accessory", "_adisk._tcp": "Time Machine",
        "_daap._tcp": "iTunes Sharing", "_dacp._tcp": "iTunes Remote",
        "_airport._tcp": "AirPort Base Station", "_googlecast._tcp": "Google Cast",
        "_androidtvremote2._tcp": "Android TV Remote", "_amzn-wplay._tcp": "Amazon Fire TV",
        "_spotify-connect._tcp": "Spotify Connect", "_sonos._tcp": "Sonos",
        "_roku._tcp": "Roku", "_rsp._tcp": "Roku Search",
        "_http._tcp": "Web Server", "_https._tcp": "Secure Web Server",
        "_workstation._tcp": "Workstation", "_ssh._tcp": "SSH",
        "_sftp-ssh._tcp": "SFTP", "_telnet._tcp": "Telnet", "_rfb._tcp": "VNC / Screen Sharing",
        "_smb._tcp": "SMB File Sharing", "_afpovertcp._tcp": "Apple File Sharing",
        "_nfs._tcp": "NFS", "_webdav._tcp": "WebDAV", "_ftp._tcp": "FTP",
        "_ipp._tcp": "Printer (IPP)", "_ipps._tcp": "Printer (IPPS)",
        "_printer._tcp": "Printer (LPD)", "_pdl-datastream._tcp": "Printer (Raw)",
        "_scanner._tcp": "Scanner", "_uscan._tcp": "AirScan", "_uscans._tcp": "AirScan (TLS)",
        "_hue._tcp": "Philips Hue", "_esphomelib._tcp": "ESPHome", "_matter._tcp": "Matter",
        "_matterc._udp": "Matter Commissioning", "_miio._udp": "Xiaomi MIoT",
        "_ewelink._tcp": "eWeLink", "_viziocast._tcp": "Vizio SmartCast",
        "_plexmediasvr._tcp": "Plex Media Server", "_nvstream._tcp": "NVIDIA GameStream",
        "_teamviewer._tcp": "TeamViewer", "_ldap._tcp": "LDAP", "_ipp-tls._tcp": "Printer (IPP/TLS)"
    ]

    private let queue = DispatchQueue(label: "com.sclera.assetonboard.bonjour", qos: .userInitiated)
    private let lock = NSLock()
    private var browsers: [NWBrowser] = []
    private var seen: Set<String> = []

    private var deniedFlag = false

    /// True once any browser reports that Local Network access was refused.
    /// Written from the browser queue, read from the main actor.
    var permissionDenied: Bool {
        lock.withLock { deniedFlag }
    }

    /// Browses all known service types, emitting each resolved instance once.
    ///
    /// The stream stays open until `stop()` is called or the task is cancelled;
    /// devices that only announce themselves periodically keep trickling in.
    func start(types: [String] = BonjourDiscovery.serviceTypes) -> AsyncStream<BonjourService> {
        AsyncStream { continuation in
            for type in types {
                let parameters = NWParameters()
                parameters.includePeerToPeer = false
                parameters.prohibitedInterfaceTypes = [.cellular]

                let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."),
                                        using: parameters)

                browser.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                            self?.lock.withLock { self?.deniedFlag = true }
                        }
                        browser.cancel()
                    }
                }

                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    guard let self else { return }
                    for result in results {
                        guard case .service(let name, let serviceType, let domain, _) = result.endpoint
                        else { continue }

                        let key = "\(name)|\(serviceType)|\(domain)"
                        let isNew: Bool = self.lock.withLock {
                            guard !self.seen.contains(key) else { return false }
                            self.seen.insert(key)
                            return true
                        }
                        guard isNew else { continue }

                        var txt: [String: String] = [:]
                        if case .bonjour(let record) = result.metadata {
                            for entry in record {
                                switch entry.value {
                                case .string(let value): txt[entry.key] = value
                                case .data(let data):
                                    txt[entry.key] = String(data: data, encoding: .utf8)
                                        ?? data.map { String(format: "%02x", $0) }.joined()
                                case .empty, .none: txt[entry.key] = ""
                                @unknown default: break
                                }
                            }
                        }

                        Task { [weak self] in
                            guard let self else { return }
                            let resolved = await self.resolve(endpoint: result.endpoint)
                            continuation.yield(BonjourService(instanceName: name,
                                                              serviceType: serviceType,
                                                              domain: domain,
                                                              txtRecord: txt,
                                                              addresses: resolved.addresses,
                                                              port: resolved.port))
                        }
                    }
                }

                browser.start(queue: queue)
                lock.withLock { browsers.append(browser) }
            }

            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    func stop() {
        let active: [NWBrowser] = lock.withLock {
            defer { browsers.removeAll() }
            return browsers
        }
        active.forEach { $0.cancel() }
    }

    /// Turns a Bonjour endpoint into concrete IP addresses.
    ///
    /// UDP parameters are deliberate: the connection reaches `.ready` as soon as
    /// mDNS resolves a route, with no handshake, so services that would refuse a
    /// TCP connection still give up their address.
    private func resolve(endpoint: NWEndpoint,
                         timeout: TimeInterval = 4.0) async -> (addresses: [IPv4], port: UInt16?) {
        await withCheckedContinuation { continuation in
            let box = ResolveBox(continuation)
            let connection = NWConnection(to: endpoint, using: .udp)

            let finish: @Sendable () -> Void = {
                var addresses: [IPv4] = []
                var port: UInt16?
                if case .hostPort(let host, let hostPort) = connection.currentPath?.remoteEndpoint {
                    port = hostPort.rawValue
                    switch host {
                    case .ipv4(let value):
                        if let parsed = IPv4("\(value)".split(separator: "%").first.map(String.init) ?? "") {
                            addresses.append(parsed)
                        }
                    case .name(let name, _):
                        if let parsed = IPv4(name) { addresses.append(parsed) }
                    default: break
                    }
                }
                box.finish((addresses, port))
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish()
                case .failed, .cancelled: box.finish(([], nil))
                default: break
                }
            }
            connection.pathUpdateHandler = { path in
                if path.status == .satisfied { finish() }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                box.finish(([], nil))
                connection.cancel()
            }
        }
    }
}

nonisolated private final class ResolveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(addresses: [IPv4], port: UInt16?), Never>?
    init(_ continuation: CheckedContinuation<(addresses: [IPv4], port: UInt16?), Never>) {
        self.continuation = continuation
    }
    func finish(_ value: (addresses: [IPv4], port: UInt16?)) {
        let pending = lock.withLock { () -> CheckedContinuation<(addresses: [IPv4], port: UInt16?), Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
