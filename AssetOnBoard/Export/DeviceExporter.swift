//
//  DeviceExporter.swift
//  AssetOnBoard
//
//  Turns a scan into an Excel workbook.
//
//  The first sheet is the inventory: every device the scan found, one row each,
//  carrying every field the probes were able to establish. Scan analytics sit in
//  a block to the right of that table rather than on a sheet of their own, so
//  the device list is what opens first and stays the focus.
//
//  Ports, advertised services and certificates are genuinely one-to-many, so
//  each row summarises them inline *and* the full detail gets its own sheet.
//

import Foundation

nonisolated enum DeviceExporter {

    /// Builds the workbook bytes for a completed (or in-progress) scan.
    ///
    /// Bluetooth results live on their own sheet rather than being merged into
    /// the network inventory: the two share no identifier, since iOS exposes a
    /// MAC for neither BLE peripherals nor most Wi-Fi hosts.
    static func workbook(for report: ScanReport?,
                         bluetoothDevices: [BluetoothDevice] = []) -> Data {
        let sheets = detailSheets(report: report, bluetoothDevices: bluetoothDevices)
        return XLSXWorkbook(sheets: sheets.isEmpty ? [emptySheet()] : sheets).data()
    }

    /// Every sheet this exporter produces, for a caller that wants to put its
    /// own summary in front of them.
    ///
    /// The combined inventory export leads with one row per physical asset and
    /// appends these behind it as the working.
    static func detailSheets(report: ScanReport?,
                             bluetoothDevices: [BluetoothDevice]) -> [XLSXSheet] {
        var sheets: [XLSXSheet] = []
        if let report { sheets.append(devicesSheet(report)) }
        if !bluetoothDevices.isEmpty { sheets.append(bluetoothSheet(bluetoothDevices)) }
        guard let report else { return sheets }

        // Empty detail sheets are noise; only include what has content.
        let ports = portsSheet(report.devices)
        if !ports.rows.isEmpty { sheets.append(ports) }
        let services = servicesSheet(report.devices)
        if !services.rows.isEmpty { sheets.append(services) }
        let certificates = certificatesSheet(report.devices)
        if !certificates.rows.isEmpty { sheets.append(certificates) }
        return sheets
    }

    private static func emptySheet() -> XLSXSheet {
        XLSXSheet(name: "Devices", columns: [XLSXColumn("No results", width: 30)], rows: [])
    }

    // MARK: - Bluetooth

    private static func bluetoothSheet(_ devices: [BluetoothDevice]) -> XLSXSheet {
        let columns = [
            XLSXColumn("#", width: 5),
            XLSXColumn("Device Name", width: 28),
            XLSXColumn("Category", width: 18),
            XLSXColumn("MAC Address", width: 19),
            XLSXColumn("MAC Source", width: 26),
            XLSXColumn("MAC Vendor", width: 22),
            XLSXColumn("MAC Confidence %", width: 16),
            XLSXColumn("Manufacturer", width: 24),
            XLSXColumn("Company ID", width: 12),
            XLSXColumn("Apple Continuity", width: 22),
            XLSXColumn("Appearance", width: 20),
            XLSXColumn("RSSI (dBm)", width: 11),
            XLSXColumn("Strongest RSSI", width: 14),
            XLSXColumn("Signal Quality", width: 14),
            XLSXColumn("Tx Power (dBm)", width: 14),
            XLSXColumn("Estimated Distance (m)", width: 20),
            XLSXColumn("Connectable", width: 12),
            XLSXColumn("Battery %", width: 10),
            XLSXColumn("Model", width: 24),
            XLSXColumn("Serial Number", width: 24),
            XLSXColumn("Hardware Revision", width: 18),
            XLSXColumn("Firmware Revision", width: 18),
            XLSXColumn("Software Revision", width: 18),
            XLSXColumn("Advertised Services", width: 40),
            XLSXColumn("Service UUIDs", width: 40),
            XLSXColumn("GATT Services", width: 40),
            XLSXColumn("Manufacturer Payload (hex)", width: 40),
            XLSXColumn("Advertisements", width: 14),
            XLSXColumn("Identifier (per-app)", width: 38),
            XLSXColumn("First Seen", width: 19),
            XLSXColumn("Last Seen", width: 19)
        ]

        let rows = devices.enumerated().map { index, device -> [XLSXCell] in
            let information = device.deviceInformation
            return [
                .integer(index + 1),
                .text(device.displayName),
                .text(device.category.rawValue),
                .text(device.macAddress?.description),
                .text(device.macSource),
                .text(device.macVendor),
                device.macConfidence.map { .integer(Int($0 * 100)) } ?? .empty,
                .text(device.manufacturerName),
                .text(device.companyIdentifier.map { String(format: "0x%04X", $0) }),
                .text(device.appleContinuityType),
                .text(device.appearanceName),
                .integer(device.rssi),
                .integer(device.bestRSSI),
                .text(device.signalStrength.rawValue),
                device.txPowerLevel.map { .integer($0) } ?? .empty,
                device.estimatedDistance.map { .number(($0 * 10).rounded() / 10) } ?? .empty,
                .boolean(device.isConnectable),
                device.batteryLevel.map { .integer($0) } ?? .empty,
                .text(information["Model"]),
                .text(information["Serial Number"]),
                .text(information["Hardware Revision"]),
                .text(information["Firmware Revision"]),
                .text(information["Software Revision"]),
                .text(device.serviceNames.joined(separator: ", ")),
                .text(device.serviceUUIDs.joined(separator: ", ")),
                .text(device.gattServices.map(\.displayName).joined(separator: ", ")),
                .text(device.manufacturerPayload?.map { String(format: "%02X", $0) }.joined(separator: " ")),
                .integer(device.advertisementCount),
                .text(device.id.uuidString),
                .date(device.firstSeen),
                .date(device.lastSeen)
            ]
        }

        return XLSXSheet(name: "Bluetooth Devices",
                         columns: columns,
                         rows: rows,
                         sideColumns: [XLSXColumn("Bluetooth Analytics", width: 30),
                                       XLSXColumn("Value", width: 20)],
                         sideRows: bluetoothAnalytics(devices))
    }

    private static func bluetoothAnalytics(_ devices: [BluetoothDevice]) -> [[XLSXCell]] {
        var rows: [[XLSXCell]] = [
            [.heading("Totals"), .empty],
            [.text("Devices seen"), .integer(devices.count)],
            [.text("Named"), .integer(devices.filter { $0.name != nil || $0.localName != nil }.count)],
            [.text("Connectable"), .integer(devices.filter(\.isConnectable).count)],
            [.text("Manufacturer known"), .integer(devices.filter { $0.manufacturerName != nil }.count)],
            [.text("MAC address recovered"), .integer(devices.filter { $0.macAddress != nil }.count)],
            [.text("Read over GATT"), .integer(devices.filter(\.isEnriched).count)]
        ]

        var categoryTally: [String: Int] = [:]
        for device in devices { categoryTally[device.category.rawValue, default: 0] += 1 }
        if !categoryTally.isEmpty {
            rows.append([])
            rows.append([.heading("By category"), .empty])
            for entry in categoryTally.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
                let row: [XLSXCell] = [.text(entry.key), .integer(entry.value)]
                rows.append(row)
            }
        }

        var vendorTally: [String: Int] = [:]
        for device in devices {
            guard let vendor = device.manufacturerName else { continue }
            vendorTally[vendor, default: 0] += 1
        }
        if !vendorTally.isEmpty {
            rows.append([])
            rows.append([.heading("Manufacturers"), .empty])
            for entry in vendorTally.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).prefix(15) {
                let row: [XLSXCell] = [.text(entry.key), .integer(entry.value)]
                rows.append(row)
            }
        }

        var serviceTally: [String: Int] = [:]
        for device in devices {
            for name in Set(device.serviceNames) { serviceTally[name, default: 0] += 1 }
        }
        if !serviceTally.isEmpty {
            rows.append([])
            rows.append([.heading("Advertised services"), .empty])
            for entry in serviceTally.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).prefix(15) {
                let row: [XLSXCell] = [.text(entry.key), .integer(entry.value)]
                rows.append(row)
            }
        }

        return rows
    }

    /// Suggested filename, e.g. `AssetOnBoard-10.2.30.0_23-2026-09-04-0907.xlsx`.
    static func filename(for report: ScanReport) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let subnet = report.subnet.replacingOccurrences(of: "/", with: "_")
        return "AssetOnBoard-\(subnet)-\(formatter.string(from: report.finishedAt)).xlsx"
    }

    // MARK: - Devices (main sheet)

    private static func devicesSheet(_ report: ScanReport) -> XLSXSheet {
        let columns = [
            XLSXColumn("#", width: 5),
            XLSXColumn("IP Address", width: 15),
            XLSXColumn("Device Name", width: 26),
            XLSXColumn("MAC Address", width: 19),
            XLSXColumn("MAC Type", width: 13),
            XLSXColumn("MAC Source", width: 14),
            XLSXColumn("Manufacturer", width: 22),
            XLSXColumn("Category", width: 18),
            XLSXColumn("Confidence %", width: 13),
            XLSXColumn("Model", width: 26),
            XLSXColumn("Model Identifier", width: 18),
            XLSXColumn("Operating System", width: 22),
            XLSXColumn("Hostname", width: 28),
            XLSXColumn("All Hostnames", width: 32),
            XLSXColumn("NetBIOS Name", width: 20),
            XLSXColumn("Workgroup", width: 16),
            XLSXColumn("NetBIOS Services", width: 24),
            XLSXColumn("Domain Controller", width: 16),
            XLSXColumn("Master Browser", width: 15),
            XLSXColumn("Is Gateway", width: 11),
            XLSXColumn("Is This Device", width: 13),
            XLSXColumn("Response Time (ms)", width: 17),
            XLSXColumn("TTL", width: 7),
            XLSXColumn("Open Port Count", width: 15),
            XLSXColumn("Open Ports", width: 40),
            XLSXColumn("Web Server", width: 26),
            XLSXColumn("Web Page Title", width: 32),
            XLSXColumn("HTTP Status", width: 11),
            XLSXColumn("Auth Realm", width: 24),
            XLSXColumn("TLS Version", width: 12),
            XLSXColumn("TLS Cipher Suite", width: 30),
            XLSXColumn("Certificate Subject", width: 30),
            XLSXColumn("Certificate Issuer", width: 28),
            XLSXColumn("Certificate Expires", width: 19),
            XLSXColumn("Service Banners", width: 50),
            XLSXColumn("Advertised Services", width: 34),
            XLSXColumn("Advertised Model", width: 24),
            XLSXColumn("Advertised Name", width: 24),
            XLSXColumn("Bonjour TXT Records", width: 60),
            XLSXColumn("Discovered By", width: 32),
            XLSXColumn("First Seen", width: 19),
            XLSXColumn("Last Seen", width: 19)
        ]

        let rows = report.devices.enumerated().map { index, device -> [XLSXCell] in
            let web = device.openPorts.first { $0.httpServer != nil || $0.httpTitle != nil }
            let tls = device.openPorts.first { !$0.certificates.isEmpty || $0.tlsVersion != nil }
            let certificate = tls?.certificates.first
            let banners = device.openPorts.compactMap { port in
                port.banner.map { "\(port.port): \($0)" }
            }.joined(separator: " | ")
            let txt = device.bonjourServices.flatMap { service in
                service.txtRecord.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            }.joined(separator: "; ")

            return [
                .integer(index + 1),
                .text(device.ip.description),
                .text(device.displayName),
                .text(device.macAddress?.description),
                macKind(device.macAddress),
                .text(macSource(device)),
                .text(device.vendor),
                .text(device.category.rawValue),
                device.confidence > 0 ? .integer(Int((device.confidence * 100).rounded())) : .empty,
                .text(device.modelName),
                .text(device.modelIdentifier),
                .text(device.operatingSystem),
                .text(device.hostnames.first),
                .text(device.hostnames.joined(separator: ", ")),
                .text(device.netbios?.computerName),
                .text(device.netbios?.workgroup),
                .text(device.netbios?.services.joined(separator: ", ")),
                .boolean(device.netbios?.isDomainController ?? false),
                .boolean(device.netbios?.isMasterBrowser ?? false),
                .boolean(device.isGateway),
                .boolean(device.isThisDevice),
                device.roundTripTime.map { .number(((($0 * 1000) * 10).rounded()) / 10) } ?? .empty,
                device.ttl.map { .integer($0) } ?? .empty,
                .integer(device.openPorts.count),
                .text(device.openPorts.map { "\($0.port)/\($0.serviceName)" }.joined(separator: ", ")),
                .text(web?.httpServer),
                .text(web?.httpTitle),
                web?.httpStatus.map { .integer($0) } ?? .empty,
                .text(web?.httpRealm),
                .text(tls?.tlsVersion),
                .text(tls?.cipherSuite),
                .text(certificate?.displayName),
                .text(certificate?.issuerCommonName ?? certificate?.issuerOrganization),
                certificate?.notAfter.map { .date($0) } ?? .empty,
                .text(banners),
                .text(device.bonjourServices.map(\.friendlyProtocolName).joined(separator: ", ")),
                .text(device.bonjourServices.compactMap(\.advertisedModel).first),
                .text(device.bonjourServices.compactMap(\.advertisedFriendlyName).first),
                .text(txt),
                .text(DiscoveryMethod.allCases
                    .filter { device.discoveryMethods.contains($0) }
                    .map(\.rawValue).joined(separator: ", ")),
                .date(device.firstSeen),
                .date(device.lastSeen)
            ]
        }

        return XLSXSheet(name: "Devices",
                         columns: columns,
                         rows: rows,
                         sideColumns: [XLSXColumn("Scan Analytics", width: 28),
                                       XLSXColumn("Value", width: 20)],
                         sideRows: analytics(report))
    }

    // MARK: - Analytics block

    private static func analytics(_ report: ScanReport) -> [[XLSXCell]] {
        let devices = report.devices
        var rows: [[XLSXCell]] = [
            [.text("Scan started"), .date(report.startedAt)],
            [.text("Scan finished"), .date(report.finishedAt)],
            [.text("Duration (seconds)"), .number((report.duration * 10).rounded() / 10)],
            [.text("Scan depth"), .text(report.depth)],
            [.text("Interface"), .text("\(report.interfaceName) (\(report.interfaceKind))")],
            [.text("Scanning device"), .text(report.localAddress.description)],
            [.text("Subnet"), .text(report.subnet)],
            [.text("Gateway"), .text(report.gateway?.description ?? "Not identified")],
            [],
            [.heading("Totals"), .empty],
            [.text("Devices found"), .integer(devices.count)],
            [.text("With MAC address"), .integer(devices.filter { $0.macAddress != nil }.count)],
            [.text("Randomised MACs"),
             .integer(devices.filter { $0.macAddress?.isLocallyAdministered == true }.count)],
            [.text("With manufacturer"), .integer(devices.filter { $0.vendor != nil }.count)],
            [.text("With a hostname"),
             .integer(devices.filter { !$0.hostnames.isEmpty || $0.netbios?.computerName != nil }.count)],
            [.text("With open ports"), .integer(devices.filter { !$0.openPorts.isEmpty }.count)],
            [.text("Identified"), .integer(devices.filter { $0.category != .unknown }.count)]
        ]

        let byCategory = DeviceCategory.allCases
            .map { category in (category.rawValue, devices.filter { $0.category == category }.count) }
            .filter { $0.1 > 0 }
        if !byCategory.isEmpty {
            rows.append([])
            rows.append([.heading("By category"), .empty])
            for entry in byCategory {
                let row: [XLSXCell] = [.text(entry.0), .integer(entry.1)]
                rows.append(row)
            }
        }

        let byMethod = DiscoveryMethod.allCases
            .map { method in (method.rawValue, devices.filter { $0.discoveryMethods.contains(method) }.count) }
            .filter { $0.1 > 0 }
        if !byMethod.isEmpty {
            rows.append([])
            rows.append([.heading("By discovery method"), .empty])
            for entry in byMethod {
                let row: [XLSXCell] = [.text(entry.0), .integer(entry.1)]
                rows.append(row)
            }
        }

        // Tallied with explicit loops: the equivalent one-line reductions push
        // the type checker past its budget.
        var portTally: [UInt16: (name: String, count: Int)] = [:]
        for device in devices {
            for port in device.openPorts {
                var entry = portTally[port.port] ?? (name: port.serviceName, count: 0)
                entry.count += 1
                portTally[port.port] = entry
            }
        }
        if !portTally.isEmpty {
            let ranked = portTally
                .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
                .prefix(15)
            rows.append([])
            rows.append([.heading("Most common open ports"), .empty])
            for entry in ranked {
                let label = "\(entry.key) \(entry.value.name)"
                let row: [XLSXCell] = [.text(label), .integer(entry.value.count)]
                rows.append(row)
            }
        }

        var vendorTally: [String: Int] = [:]
        for device in devices {
            guard let vendor = device.vendor else { continue }
            vendorTally[vendor, default: 0] += 1
        }
        if !vendorTally.isEmpty {
            let ranked = vendorTally
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(15)
            rows.append([])
            rows.append([.heading("Manufacturers"), .empty])
            for entry in ranked {
                let row: [XLSXCell] = [.text(entry.key), .integer(entry.value)]
                rows.append(row)
            }
        }

        return rows
    }

    // MARK: - Derived fields

    private static func macKind(_ mac: MACAddress?) -> XLSXCell {
        guard let mac else { return .empty }
        return .text(mac.isLocallyAdministered ? "Randomised" : "Universal")
    }

    /// Which probe actually produced the MAC, since several can supply one.
    private static func macSource(_ device: NetworkDevice) -> String? {
        guard let mac = device.macAddress else { return nil }
        if device.netbios?.macAddress == mac { return "NetBIOS" }
        if device.bonjourServices.contains(where: { $0.advertisedMAC == mac }) { return "Bonjour" }
        if device.discoveryMethods.contains(.snmp) { return "Router SNMP" }
        if device.discoveryMethods.contains(.arp) { return "ARP cache" }
        return nil
    }

    // MARK: - Detail sheets

    private static func portsSheet(_ devices: [NetworkDevice]) -> XLSXSheet {
        let columns = [
            XLSXColumn("IP Address", width: 15),
            XLSXColumn("Device", width: 26),
            XLSXColumn("MAC Address", width: 19),
            XLSXColumn("Port", width: 8),
            XLSXColumn("Service", width: 20),
            XLSXColumn("Description", width: 28),
            XLSXColumn("HTTP Status", width: 12),
            XLSXColumn("Server Header", width: 28),
            XLSXColumn("Page Title", width: 34),
            XLSXColumn("Auth Realm", width: 24),
            XLSXColumn("Redirects To", width: 30),
            XLSXColumn("TLS Version", width: 12),
            XLSXColumn("Cipher Suite", width: 30),
            XLSXColumn("Banner", width: 50),
            XLSXColumn("Response Time (ms)", width: 18)
        ]

        var rows: [[XLSXCell]] = []
        for device in devices {
            for port in device.openPorts {
                rows.append([
                    .text(device.ip.description),
                    .text(device.displayName),
                    .text(device.macAddress?.description),
                    .integer(Int(port.port)),
                    .text(port.serviceName),
                    .text(port.detail),
                    port.httpStatus.map { .integer($0) } ?? .empty,
                    .text(port.httpServer),
                    .text(port.httpTitle),
                    .text(port.httpRealm),
                    .text(port.httpRedirect),
                    .text(port.tlsVersion),
                    .text(port.cipherSuite),
                    .text(port.banner),
                    port.responseTime > 0 ? .number(((port.responseTime * 1000) * 10).rounded() / 10) : .empty
                ])
            }
        }
        return XLSXSheet(name: "Open Ports", columns: columns, rows: rows)
    }

    private static func servicesSheet(_ devices: [NetworkDevice]) -> XLSXSheet {
        let columns = [
            XLSXColumn("IP Address", width: 15),
            XLSXColumn("Device", width: 26),
            XLSXColumn("MAC Address", width: 19),
            XLSXColumn("Protocol", width: 24),
            XLSXColumn("Service Type", width: 26),
            XLSXColumn("Instance Name", width: 34),
            XLSXColumn("Port", width: 8),
            XLSXColumn("Advertised Model", width: 24),
            XLSXColumn("Advertised Name", width: 24),
            XLSXColumn("Advertised MAC", width: 19),
            XLSXColumn("TXT Records", width: 60)
        ]

        var rows: [[XLSXCell]] = []
        for device in devices {
            for service in device.bonjourServices {
                let txt = service.txtRecord
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "; ")
                rows.append([
                    .text(device.ip.description),
                    .text(device.displayName),
                    .text(device.macAddress?.description),
                    .text(service.friendlyProtocolName),
                    .text(service.serviceType),
                    .text(service.instanceName),
                    service.port.map { .integer(Int($0)) } ?? .empty,
                    .text(service.advertisedModel),
                    .text(service.advertisedFriendlyName),
                    .text(service.advertisedMAC?.description),
                    .text(txt)
                ])
            }
        }
        return XLSXSheet(name: "Advertised Services", columns: columns, rows: rows)
    }

    private static func certificatesSheet(_ devices: [NetworkDevice]) -> XLSXSheet {
        let columns = [
            XLSXColumn("IP Address", width: 15),
            XLSXColumn("Device", width: 26),
            XLSXColumn("Port", width: 8),
            XLSXColumn("Subject CN", width: 32),
            XLSXColumn("Subject Org", width: 26),
            XLSXColumn("Issuer CN", width: 32),
            XLSXColumn("Issuer Org", width: 26),
            XLSXColumn("Valid From", width: 19),
            XLSXColumn("Valid Until", width: 19),
            XLSXColumn("Expired", width: 10),
            XLSXColumn("Self-Signed", width: 12),
            XLSXColumn("Serial Number", width: 34),
            XLSXColumn("Subject Alt Names", width: 46)
        ]

        var rows: [[XLSXCell]] = []
        for device in devices {
            for port in device.openPorts {
                for certificate in port.certificates {
                    rows.append([
                        .text(device.ip.description),
                        .text(device.displayName),
                        .integer(Int(port.port)),
                        .text(certificate.subjectCommonName ?? certificate.subjectSummary),
                        .text(certificate.subjectOrganization),
                        .text(certificate.issuerCommonName),
                        .text(certificate.issuerOrganization),
                        certificate.notBefore.map { .date($0) } ?? .empty,
                        certificate.notAfter.map { .date($0) } ?? .empty,
                        .boolean(certificate.isExpired),
                        .boolean(certificate.isSelfSigned),
                        .text(certificate.serialNumber),
                        .text(certificate.subjectAlternativeNames.joined(separator: ", "))
                    ])
                }
            }
        }
        return XLSXSheet(name: "TLS Certificates", columns: columns, rows: rows)
    }
}
