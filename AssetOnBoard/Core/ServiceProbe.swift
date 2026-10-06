//
//  ServiceProbe.swift
//  AssetOnBoard
//
//  The port catalogue and per-service interrogation.
//

import Foundation

nonisolated enum ProbeKind: Sendable {
    /// Send a bare GET and read the response.
    case http
    /// Same, wrapped in TLS, which also captures the certificate.
    case https
    /// Say nothing and read whatever the service volunteers.
    case banner
    /// Connect only; the port number itself is the signal.
    case connectOnly
}

nonisolated struct PortDefinition: Sendable, Hashable {
    let port: UInt16
    let name: String
    let detail: String
    let probe: ProbeKind

    static func == (lhs: PortDefinition, rhs: PortDefinition) -> Bool { lhs.port == rhs.port }
    func hash(into hasher: inout Hasher) { hasher.combine(port) }
}

nonisolated struct PortObservation: Sendable, Hashable, Codable, Identifiable {
    var port: UInt16
    var serviceName: String
    var detail: String
    var banner: String?
    var httpStatus: Int?
    var httpServer: String?
    var httpTitle: String?
    var httpRealm: String?
    var httpRedirect: String?
    var certificates: [TLSCertificateInfo] = []
    var tlsVersion: String?
    var cipherSuite: String?
    var responseTime: TimeInterval = 0

    var id: UInt16 { port }

    /// The single most descriptive line we can show for this port.
    var summary: String {
        if let title = httpTitle, !title.isEmpty { return title }
        if let realm = httpRealm, !realm.isEmpty { return "Auth realm: \(realm)" }
        if let server = httpServer, !server.isEmpty { return server }
        if let certificateName = certificates.first?.displayName { return certificateName }
        if let banner, !banner.isEmpty { return banner }
        return detail
    }
}

nonisolated enum ScanDepth: String, CaseIterable, Sendable, Identifiable {
    case quick = "Quick"
    case standard = "Standard"
    case deep = "Deep"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .quick: "16 ports · fastest"
        case .standard: "48 ports · balanced"
        case .deep: "120+ ports · thorough"
        }
    }

    var ports: [PortDefinition] {
        switch self {
        case .quick: Array(ServiceCatalog.all.prefix(16))
        case .standard: Array(ServiceCatalog.all.prefix(48))
        case .deep: ServiceCatalog.all
        }
    }

    /// Concurrent probes in flight, clamped to the descriptor budget the app
    /// actually obtained at launch.
    var concurrency: Int {
        let preferred = switch self {
        case .quick: 128
        case .standard: 160
        case .deep: 192
        }
        return SystemLimits.socketBudget(preferred: preferred)
    }

    /// How many discovery ports to knock on per silent host.
    var knockPortCount: Int {
        switch self {
        case .quick: 6
        case .standard: 12
        case .deep: ServiceCatalog.discoveryKnockPorts.count
        }
    }

    /// How long to wait for a handshake. Firewalled ports never answer, so this
    /// timeout — not the round trip — sets the pace of the whole scan.
    var connectTimeout: TimeInterval {
        switch self {
        case .quick: 0.7
        case .standard: 1.2
        case .deep: 2.0
        }
    }
}

nonisolated enum ServiceCatalog {

    /// Ordered by how much each port reveals about a device, because the Quick
    /// and Standard depths simply take a prefix of this list.
    static let all: [PortDefinition] = deduplicated([
        PortDefinition(port: 80, name: "HTTP", detail: "Web interface", probe: .http),
        PortDefinition(port: 443, name: "HTTPS", detail: "Secure web interface", probe: .https),
        PortDefinition(port: 22, name: "SSH", detail: "Secure shell", probe: .banner),
        PortDefinition(port: 445, name: "SMB", detail: "Windows / Samba file sharing", probe: .connectOnly),
        PortDefinition(port: 139, name: "NetBIOS-SSN", detail: "Legacy Windows file sharing", probe: .connectOnly),
        PortDefinition(port: 62078, name: "lockdownd", detail: "iPhone / iPad pairing service", probe: .connectOnly),
        PortDefinition(port: 8080, name: "HTTP-alt", detail: "Alternate web interface", probe: .http),
        PortDefinition(port: 8443, name: "HTTPS-alt", detail: "Alternate secure web interface", probe: .https),
        PortDefinition(port: 5000, name: "UPnP / Synology", detail: "Device web service", probe: .http),
        PortDefinition(port: 9100, name: "JetDirect", detail: "Raw printing", probe: .connectOnly),
        PortDefinition(port: 631, name: "IPP", detail: "Internet Printing Protocol", probe: .http),
        PortDefinition(port: 548, name: "AFP", detail: "Apple File Protocol", probe: .connectOnly),
        PortDefinition(port: 3389, name: "RDP", detail: "Windows Remote Desktop", probe: .connectOnly),
        PortDefinition(port: 5900, name: "VNC", detail: "Screen sharing", probe: .banner),
        PortDefinition(port: 23, name: "Telnet", detail: "Unencrypted shell", probe: .banner),
        PortDefinition(port: 53, name: "DNS", detail: "Name server", probe: .connectOnly),

        PortDefinition(port: 8008, name: "Chromecast", detail: "Google Cast control", probe: .http),
        PortDefinition(port: 8009, name: "Cast TLS", detail: "Google Cast channel", probe: .connectOnly),
        PortDefinition(port: 1400, name: "Sonos", detail: "Sonos control", probe: .http),
        PortDefinition(port: 32400, name: "Plex", detail: "Plex Media Server", probe: .http),
        PortDefinition(port: 8123, name: "Home Assistant", detail: "Home automation", probe: .http),
        PortDefinition(port: 7000, name: "AirPlay", detail: "AirPlay receiver", probe: .http),
        PortDefinition(port: 5001, name: "Synology HTTPS", detail: "DSM secure interface", probe: .https),
        PortDefinition(port: 21, name: "FTP", detail: "File transfer", probe: .banner),
        PortDefinition(port: 25, name: "SMTP", detail: "Mail transfer", probe: .banner),
        PortDefinition(port: 110, name: "POP3", detail: "Mail retrieval", probe: .banner),
        PortDefinition(port: 143, name: "IMAP", detail: "Mail access", probe: .banner),
        PortDefinition(port: 554, name: "RTSP", detail: "Camera / media stream", probe: .banner),
        PortDefinition(port: 3306, name: "MySQL", detail: "Database", probe: .banner),
        PortDefinition(port: 5432, name: "PostgreSQL", detail: "Database", probe: .connectOnly),
        PortDefinition(port: 6379, name: "Redis", detail: "Key-value store", probe: .connectOnly),
        PortDefinition(port: 27017, name: "MongoDB", detail: "Database", probe: .connectOnly),
        PortDefinition(port: 5555, name: "ADB", detail: "Android Debug Bridge", probe: .connectOnly),
        PortDefinition(port: 515, name: "LPD", detail: "Line printer daemon", probe: .connectOnly),
        PortDefinition(port: 111, name: "Portmapper", detail: "ONC RPC", probe: .connectOnly),
        PortDefinition(port: 2049, name: "NFS", detail: "Network file system", probe: .connectOnly),
        PortDefinition(port: 135, name: "MSRPC", detail: "Windows RPC endpoint mapper", probe: .connectOnly),
        PortDefinition(port: 3283, name: "ARD", detail: "Apple Remote Desktop", probe: .connectOnly),
        PortDefinition(port: 88, name: "Kerberos", detail: "Authentication / HomeKit", probe: .connectOnly),
        PortDefinition(port: 389, name: "LDAP", detail: "Directory service", probe: .connectOnly),
        PortDefinition(port: 873, name: "rsync", detail: "File synchronisation", probe: .banner),
        PortDefinition(port: 993, name: "IMAPS", detail: "Secure mail access", probe: .https),
        PortDefinition(port: 995, name: "POP3S", detail: "Secure mail retrieval", probe: .https),
        PortDefinition(port: 1883, name: "MQTT", detail: "IoT message broker", probe: .connectOnly),
        PortDefinition(port: 8081, name: "HTTP-alt", detail: "Alternate web interface", probe: .http),
        PortDefinition(port: 8000, name: "HTTP-alt", detail: "Alternate web interface", probe: .http),
        PortDefinition(port: 10000, name: "Webmin", detail: "Server administration", probe: .https),
        PortDefinition(port: 9000, name: "Portainer / PHP-FPM", detail: "Management interface", probe: .http),

        PortDefinition(port: 81, name: "HTTP-alt", detail: "Alternate web interface", probe: .http),
        PortDefinition(port: 82, name: "HTTP-alt", detail: "Alternate web interface", probe: .http),
        PortDefinition(port: 591, name: "FileMaker", detail: "Web sharing", probe: .http),
        PortDefinition(port: 8006, name: "Proxmox", detail: "Virtualisation manager", probe: .https),
        PortDefinition(port: 8086, name: "InfluxDB", detail: "Time-series database", probe: .http),
        PortDefinition(port: 8096, name: "Jellyfin", detail: "Media server", probe: .http),
        PortDefinition(port: 8200, name: "Synology / DLNA", detail: "Media service", probe: .http),
        PortDefinition(port: 8888, name: "HTTP-alt", detail: "Alternate web interface", probe: .http),
        PortDefinition(port: 9090, name: "Prometheus / Cockpit", detail: "Monitoring", probe: .http),
        PortDefinition(port: 9200, name: "Elasticsearch", detail: "Search cluster", probe: .http),
        PortDefinition(port: 3000, name: "Grafana / Node", detail: "Application server", probe: .http),
        PortDefinition(port: 5357, name: "WSD", detail: "Web Services for Devices", probe: .http),
        PortDefinition(port: 1900, name: "SSDP", detail: "UPnP discovery", probe: .connectOnly),
        PortDefinition(port: 49152, name: "UPnP", detail: "Dynamic UPnP service", probe: .http),
        PortDefinition(port: 5060, name: "SIP", detail: "Voice over IP", probe: .connectOnly),
        PortDefinition(port: 1723, name: "PPTP", detail: "Legacy VPN", probe: .connectOnly),
        PortDefinition(port: 500, name: "IKE", detail: "IPsec key exchange", probe: .connectOnly),
        PortDefinition(port: 1194, name: "OpenVPN", detail: "VPN tunnel", probe: .connectOnly),
        PortDefinition(port: 1433, name: "MSSQL", detail: "Microsoft SQL Server", probe: .connectOnly),
        PortDefinition(port: 1521, name: "Oracle", detail: "Database listener", probe: .connectOnly),
        PortDefinition(port: 2375, name: "Docker", detail: "Unencrypted Docker API", probe: .http),
        PortDefinition(port: 2376, name: "Docker TLS", detail: "Docker API", probe: .https),
        PortDefinition(port: 5222, name: "XMPP", detail: "Messaging", probe: .connectOnly),
        PortDefinition(port: 6000, name: "X11", detail: "Remote display", probe: .connectOnly),
        PortDefinition(port: 7100, name: "Printer", detail: "Font / print service", probe: .connectOnly),
        PortDefinition(port: 11211, name: "memcached", detail: "Cache", probe: .connectOnly),
        PortDefinition(port: 51413, name: "Transmission", detail: "BitTorrent", probe: .connectOnly),
        PortDefinition(port: 4070, name: "Spotify Connect", detail: "Playback endpoint", probe: .connectOnly),
        PortDefinition(port: 3689, name: "DAAP", detail: "iTunes / Music sharing", probe: .http),
        PortDefinition(port: 902, name: "VMware", detail: "ESXi agent", probe: .banner),
        PortDefinition(port: 465, name: "SMTPS", detail: "Secure mail transfer", probe: .https),
        PortDefinition(port: 587, name: "Submission", detail: "Mail submission", probe: .banner),
        PortDefinition(port: 636, name: "LDAPS", detail: "Secure directory", probe: .https),
        PortDefinition(port: 989, name: "FTPS data", detail: "Secure file transfer", probe: .connectOnly),
        PortDefinition(port: 990, name: "FTPS", detail: "Secure file transfer", probe: .https),
        PortDefinition(port: 1080, name: "SOCKS", detail: "Proxy", probe: .connectOnly),
        PortDefinition(port: 2082, name: "cPanel", detail: "Hosting control panel", probe: .http),
        PortDefinition(port: 2083, name: "cPanel TLS", detail: "Hosting control panel", probe: .https),
        PortDefinition(port: 2222, name: "SSH-alt", detail: "Alternate secure shell", probe: .banner),
        PortDefinition(port: 3128, name: "Squid", detail: "HTTP proxy", probe: .http),
        PortDefinition(port: 4444, name: "Alt service", detail: "Assorted services", probe: .connectOnly),
        PortDefinition(port: 5010, name: "Telepathy", detail: "Assorted services", probe: .connectOnly),
        PortDefinition(port: 5800, name: "VNC HTTP", detail: "Browser screen sharing", probe: .http),
        PortDefinition(port: 5901, name: "VNC :1", detail: "Screen sharing", probe: .banner),
        PortDefinition(port: 5984, name: "CouchDB", detail: "Database", probe: .http),
        PortDefinition(port: 6667, name: "IRC", detail: "Chat", probe: .banner),
        PortDefinition(port: 7001, name: "AirPlay alt", detail: "Media endpoint", probe: .connectOnly),
        PortDefinition(port: 7070, name: "RTSP alt", detail: "Media stream", probe: .connectOnly),
        PortDefinition(port: 8060, name: "Roku ECP", detail: "Roku external control", probe: .http),
        PortDefinition(port: 8089, name: "Splunk", detail: "Management port", probe: .https),
        PortDefinition(port: 8112, name: "Deluge", detail: "BitTorrent client", probe: .http),
        PortDefinition(port: 8181, name: "HTTP-alt", detail: "Alternate web interface", probe: .http),
        PortDefinition(port: 8291, name: "MikroTik", detail: "Winbox management", probe: .connectOnly),
        PortDefinition(port: 8883, name: "MQTT TLS", detail: "Secure IoT broker", probe: .https),
        PortDefinition(port: 9091, name: "Transmission Web", detail: "BitTorrent UI", probe: .http),
        PortDefinition(port: 9443, name: "HTTPS-alt", detail: "Management interface", probe: .https),
        PortDefinition(port: 10001, name: "Ubiquiti", detail: "Device discovery", probe: .connectOnly),
        PortDefinition(port: 32469, name: "Plex DLNA", detail: "Media sharing", probe: .http),
        PortDefinition(port: 49153, name: "UPnP alt", detail: "Dynamic UPnP service", probe: .http),
        PortDefinition(port: 5988, name: "WBEM", detail: "Hardware management", probe: .http),
        PortDefinition(port: 5989, name: "WBEM TLS", detail: "Hardware management", probe: .https),
        PortDefinition(port: 7080, name: "LiteSpeed", detail: "Web server admin", probe: .http),
        PortDefinition(port: 8010, name: "HTTP-alt", detail: "Alternate web interface", probe: .http),
        PortDefinition(port: 8098, name: "Riak", detail: "Database", probe: .http),
        PortDefinition(port: 9999, name: "Alt admin", detail: "Assorted services", probe: .http)
    ])

    /// Deduplicated by port, keeping the first (highest-signal) definition.
    /// Scanning the same port twice wastes a socket and shows a duplicate row.
    private static func deduplicated(_ definitions: [PortDefinition]) -> [PortDefinition] {
        var seen = Set<UInt16>()
        return definitions.filter { seen.insert($0.port).inserted }
    }

    /// Ports knocked on during discovery, ordered by how many otherwise-silent
    /// hosts they reveal.
    ///
    /// Windows leads the list deliberately: a stock Windows machine drops ICMP
    /// and listens on none of the usual web/SSH ports, but almost always answers
    /// on WSD (5357) or MSRPC (135). Measured on a live /23, those two alone
    /// accounted for most of the hosts a ping sweep never sees.
    static let discoveryKnockPorts: [UInt16] = [
        5357,   // WSD — Windows network discovery
        445,    // SMB
        80, 443,
        135,    // MSRPC — domain-joined Windows
        139,
        62078,  // lockdownd — iPhone / iPad
        22,
        3389,   // RDP
        8080,
        5985,   // WinRM
        5040,   // Windows connected-devices platform
        53,
        9100, 631,
        5000
    ]
}

nonisolated enum ServiceProbe {

    /// Interrogates one port, returning nil when nothing is listening.
    static func probe(host: IPv4,
                      definition: PortDefinition,
                      connectTimeout: TimeInterval) async -> PortObservation? {
        var observation = PortObservation(port: definition.port,
                                          serviceName: definition.name,
                                          detail: definition.detail)

        switch definition.probe {
        case .connectOnly:
            let outcome = await TCPProbe.connect(to: host, port: definition.port, timeout: connectTimeout)
            guard outcome == .open else { return nil }

        case .banner:
            let exchange = await TCPProbe.exchange(with: host,
                                                   port: definition.port,
                                                   maxBytes: 2048,
                                                   connectTimeout: connectTimeout,
                                                   readTimeout: 1.5)
            guard exchange.outcome == .open else { return nil }
            observation.banner = cleanBanner(exchange.data)
            observation.responseTime = exchange.elapsed

        case .http, .https:
            let useTLS = definition.probe == .https
            let request = httpRequest(host: host, port: definition.port, secure: useTLS)
            let exchange = await TCPProbe.exchange(with: host,
                                                   port: definition.port,
                                                   useTLS: useTLS,
                                                   serverName: host.description,
                                                   payload: request,
                                                   connectTimeout: connectTimeout,
                                                   readTimeout: 2.5)
            guard exchange.outcome == .open else { return nil }
            observation.certificates = exchange.certificates
            observation.tlsVersion = exchange.tlsVersion
            observation.cipherSuite = exchange.cipherSuite
            observation.responseTime = exchange.elapsed
            if !exchange.data.isEmpty {
                apply(httpResponse: exchange.data, to: &observation)
            }
        }
        return observation
    }

    private static func httpRequest(host: IPv4, port: UInt16, secure: Bool) -> Data {
        let defaultPort: UInt16 = secure ? 443 : 80
        let hostHeader = port == defaultPort ? host.description : "\(host):\(port)"
        let request = """
        GET / HTTP/1.1\r
        Host: \(hostHeader)\r
        User-Agent: AssetOnBoard/1.0 (Local network inventory)\r
        Accept: */*\r
        Connection: close\r
        \r
        
        """
        return Data(request.utf8)
    }

    /// Pulls status, headers and page title out of a raw HTTP response.
    private static func apply(httpResponse data: Data, to observation: inout PortObservation) {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return }

        let separator = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
        let headerBlock = separator.map { String(text[text.startIndex..<$0.lowerBound]) } ?? text
        let body = separator.map { String(text[$0.upperBound...]) } ?? ""

        var lines = headerBlock.components(separatedBy: .newlines)
        guard let statusLine = lines.first else { return }

        if statusLine.hasPrefix("HTTP/") {
            let parts = statusLine.split(separator: " ")
            if parts.count >= 2 { observation.httpStatus = Int(parts[1]) }
        } else {
            // Not HTTP at all — keep it as a raw banner instead of discarding it.
            observation.banner = cleanBanner(data)
            return
        }
        lines.removeFirst()

        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "server": observation.httpServer = value
            case "location": observation.httpRedirect = value
            case "www-authenticate":
                // The Basic-auth realm is often the literal model name.
                if let realm = value.range(of: "realm=") {
                    observation.httpRealm = value[realm.upperBound...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                } else {
                    observation.httpRealm = value
                }
            case "x-powered-by":
                if observation.httpServer == nil { observation.httpServer = value }
            default: break
            }
        }

        if let title = extractTitle(from: body) { observation.httpTitle = title }
    }

    private static func extractTitle(from body: String) -> String? {
        guard let open = body.range(of: "<title", options: .caseInsensitive),
              let openEnd = body.range(of: ">", range: open.upperBound..<body.endIndex),
              let close = body.range(of: "</title>", options: .caseInsensitive,
                                     range: openEnd.upperBound..<body.endIndex)
        else { return nil }

        let title = body[openEnd.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = title.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(120))
    }

    /// Turns raw bytes into one printable line suitable for a UI row.
    private static func cleanBanner(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let printable = text.unicodeScalars
            .map { scalar -> Character in
                if scalar == "\n" || scalar == "\r" || scalar == "\t" { return " " }
                return scalar.properties.isAlphabetic || (32...126).contains(scalar.value)
                    ? Character(scalar) : "."
            }
        let collapsed = String(printable)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty, collapsed.contains(where: { $0 != "." }) else { return nil }
        return String(collapsed.prefix(200))
    }
}
