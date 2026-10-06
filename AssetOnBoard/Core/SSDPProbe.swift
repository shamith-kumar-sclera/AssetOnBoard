//
//  SSDPProbe.swift
//  AssetOnBoard
//
//  Unicast SSDP / UPnP interrogation of a single host.
//
//  Routers, mesh nodes and standalone access points nearly all run a UPnP stack,
//  and its device description is the one place such a box states its own
//  manufacturer, model name and model number in plain text. The subnet sweep can
//  tell that something is listening on 1900; this asks it what it is.
//
//  Deliberately unicast. A multicast M-SEARCH to 239.255.255.250 would also turn
//  up hosts the sweep missed, but iOS 14 and later gate multicast behind the
//  Multicast Networking entitlement, which Apple grants by application only.
//  UPnP 1.1 defines the unicast form precisely so a control point can question
//  one device, and that needs no entitlement at all.
//
//  The description document is fetched over a raw TCP exchange rather than
//  URLSession, which keeps App Transport Security out of the picture: these
//  devices serve plain HTTP and always will.
//

import Foundation

nonisolated struct SSDPDescription: Sendable, Hashable, Codable {
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
    var modelNumber: String?
    var serialNumber: String?
    var deviceType: String?
    var presentationURL: String?
    /// The raw `SERVER:` header, which usually carries the OS and UPnP stack.
    var server: String?

    /// Everything worth matching against, lowercased.
    var corpus: String {
        [friendlyName, manufacturer, modelName, modelNumber, deviceType, server]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    /// The best single label for a list row.
    var displayName: String? {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        if let modelName, !modelName.isEmpty {
            if let manufacturer, !modelName.localizedCaseInsensitiveContains(manufacturer) {
                return "\(manufacturer) \(modelName)"
            }
            return modelName
        }
        return nil
    }

    /// True when the description says this is routing or Wi-Fi gear.
    ///
    /// `InternetGatewayDevice` is the definitive one — it is the UPnP profile for
    /// a NAT router — and the rest are the words APs put in their model names.
    var describesInfrastructure: Bool {
        let text = corpus
        if text.contains("internetgatewaydevice") || text.contains("wandevice")
            || text.contains("wanconnectiondevice") || text.contains("wlanaccesspoint") {
            return true
        }
        return WirelessInfrastructure.textSuggestsAccessPoint(text)
    }
}

nonisolated enum SSDPProbe {

    /// Asks `host` to describe itself. Returns nil when it runs no UPnP stack.
    static func interrogate(host: IPv4, timeout: TimeInterval = 1.5) async -> SSDPDescription? {
        // `upnp:rootdevice` returns exactly one answer per device; `ssdp:all`
        // returns one per embedded service, and we only want the root.
        var headers = await search(host: host, target: "upnp:rootdevice", timeout: timeout)
        if headers == nil {
            headers = await search(host: host, target: "ssdp:all", timeout: timeout)
        }
        guard let headers else { return nil }

        var description = SSDPDescription(deviceType: headers["st"], server: headers["server"])

        if let location = headers["location"],
           let document = await fetchDescription(location, fallbackHost: host, timeout: timeout) {
            apply(document, to: &description)
        }

        // A bare SERVER header is still worth keeping: "Linux/3.10 UPnP/1.0
        // MiniUPnPd/2.1" identifies plenty of routers on its own.
        guard description.server != nil || description.friendlyName != nil else { return nil }
        return description
    }

    // MARK: - M-SEARCH

    private static func search(host: IPv4,
                               target: String,
                               timeout: TimeInterval) async -> [String: String]? {
        // UPnP 1.1 section 1.3.2: a unicast M-SEARCH omits MX entirely.
        let request = """
        M-SEARCH * HTTP/1.1\r
        HOST: \(host):1900\r
        MAN: "ssdp:discover"\r
        ST: \(target)\r
        USER-AGENT: iOS UPnP/1.1 AssetOnBoard/1.0\r
        \r
        
        """
        guard let response = await UDPDatagram.exchange(with: host,
                                                        port: 1900,
                                                        payload: Data(request.utf8),
                                                        timeout: timeout)
        else { return nil }

        let headers = parseHeaders(response)
        // Anything that answers at all has a status line; require one real header.
        return headers.isEmpty ? nil : headers
    }

    /// Lowercased header name -> value, from an HTTP-style response.
    private static func parseHeaders(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return [:] }

        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            headers[name] = value
        }
        return headers
    }

    // MARK: - Device description

    /// Fetches the XML the LOCATION header points at.
    ///
    /// The host in that URL is ignored in favour of the address we already
    /// probed: some firmware advertises its WAN address or a hostname that does
    /// not resolve from the LAN side.
    private static func fetchDescription(_ location: String,
                                         fallbackHost: IPv4,
                                         timeout: TimeInterval) async -> String? {
        guard let components = URLComponents(string: location) else { return nil }
        let port = UInt16(components.port ?? 80)
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?\(query)" }

        let request = """
        GET \(path) HTTP/1.1\r
        Host: \(fallbackHost):\(port)\r
        User-Agent: AssetOnBoard/1.0 (Local network inventory)\r
        Accept: text/xml, application/xml\r
        Connection: close\r
        \r
        
        """

        let exchange = await TCPProbe.exchange(with: fallbackHost,
                                               port: port,
                                               payload: Data(request.utf8),
                                               maxBytes: 32 * 1024,
                                               connectTimeout: timeout,
                                               readTimeout: timeout + 1)
        guard exchange.outcome == .open, !exchange.data.isEmpty else { return nil }
        return String(data: exchange.data, encoding: .utf8)
            ?? String(data: exchange.data, encoding: .isoLatin1)
    }

    private static func apply(_ document: String, to description: inout SSDPDescription) {
        description.friendlyName = element("friendlyName", in: document)
        description.manufacturer = element("manufacturer", in: document)
        description.modelName = element("modelName", in: document)
        description.modelNumber = element("modelNumber", in: document)
        description.serialNumber = element("serialNumber", in: document)
        description.presentationURL = element("presentationURL", in: document)
        // The root deviceType is more specific than the ST we searched with.
        if let type = element("deviceType", in: document) { description.deviceType = type }
    }

    /// First occurrence of `<name>…</name>`, unescaped.
    ///
    /// A five-field lookup over a document this small does not justify pulling in
    /// XMLParser and its delegate.
    private static func element(_ name: String, in document: String) -> String? {
        guard let open = document.range(of: "<\(name)>", options: .caseInsensitive),
              let close = document.range(of: "</\(name)>",
                                         options: .caseInsensitive,
                                         range: open.upperBound..<document.endIndex)
        else { return nil }

        let value = document[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
