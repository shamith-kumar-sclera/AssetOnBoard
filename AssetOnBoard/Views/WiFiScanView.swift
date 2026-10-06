//
//  WiFiScanView.swift
//  AssetOnBoard
//
//  The Wi-Fi / LAN half of the app: sweep the local subnet and inventory it.
//


import SwiftUI

struct WiFiScanView: View {
    let scanner: NetworkScanner
    let bluetoothScanner: BluetoothScanner
    @State private var depth: ScanDepth = .standard
    @State private var searchText = ""
    @State private var categoryFilter: DeviceCategory?
    @State private var exportFile: ExportFile?
    @State private var snmpCommunity = "public"
    @State private var subnetText = ""
    @State private var scanAllSubnets = false

    private var visibleDevices: [NetworkDevice] {
        scanner.sortedDevices.filter { device in
            if let categoryFilter, device.category != categoryFilter { return false }
            guard !searchText.isEmpty else { return true }
            return device.matches(searchText)
        }
    }

    private var presentCategories: [DeviceCategory] {
        let counts = Dictionary(grouping: scanner.devices, by: \.category)
        return DeviceCategory.allCases.filter { counts[$0]?.isEmpty == false }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { NetworkHeaderCard(scanner: scanner) }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)

                if scanner.localNetworkDenied {
                    Section { LocalNetworkDeniedBanner() }
                }

                Section {
                    ScanControlPanel(scanner: scanner,
                                     depth: $depth,
                                     snmpCommunity: $snmpCommunity,
                                     subnetText: $subnetText,
                                     scanAllSubnets: $scanAllSubnets)
                }

                DiscoveredSubnetsSection(scanner: scanner) { subnet in
                    // Tapping a subnet aims the next sweep at it.
                    subnetText = subnet.description
                    scanAllSubnets = false
                    scanner.scansAllSubnets = false
                    scanner.targetSubnetOverride = subnet
                    scanner.start(depth: depth)
                }

                if !presentCategories.isEmpty {
                    Section {
                        CategoryFilterStrip(categories: presentCategories,
                                            devices: scanner.devices,
                                            selection: $categoryFilter)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Section {
                    if visibleDevices.isEmpty {
                        EmptyStateRow(isScanning: scanner.isScanning,
                                      hasScanned: scanner.phase == .finished,
                                      isFiltered: !searchText.isEmpty || categoryFilter != nil)
                    } else {
                        ForEach(visibleDevices) { device in
                            NavigationLink {
                                DeviceDetailView(device: device)
                            } label: {
                                DeviceRow(device: device)
                            }
                        }
                    }
                } header: {
                    if !scanner.devices.isEmpty {
                        HStack {
                            Text("Devices")
                            Spacer()
                            Text("\(visibleDevices.count) of \(scanner.devices.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("AssetOnBoard")
            .searchable(text: $searchText, prompt: "Name, IP, vendor, service")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            export(as: .excel)
                        } label: {
                            Label("Export Excel (.xlsx)", systemImage: "tablecells")
                        }
                        .disabled(scanner.devices.isEmpty)

                        Button {
                            export(as: .json)
                        } label: {
                            Label("Export JSON", systemImage: "curlybraces")
                        }
                        .disabled(scanner.devices.isEmpty)

                        Button(role: .destructive) {
                            scanner.reset()
                            categoryFilter = nil
                        } label: {
                            Label("Clear Results", systemImage: "trash")
                        }
                        .disabled(scanner.devices.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(url: file.url)
            }
            .task {
                scanner.startPassiveDiscovery()
                // The list is cheap and is the first thing worth seeing.
                if scanner.discoveredSubnets.isEmpty { scanner.discoverSubnets() }
            }
            .refreshable { scanner.refreshInterface() }
        }
    }

    private enum ExportFormat { case excel, json }

    private func export(as format: ExportFormat) {
        // Prefer the finished report, but fall back to a live snapshot so a
        // scan that was stopped early can still be exported.
        guard let report = scanner.lastReport ?? scanner.currentReport(depth: depth) else { return }
        do {
            let data: Data
            let name: String
            switch format {
            case .excel:
                data = DeviceExporter.workbook(for: report,
                                               bluetoothDevices: bluetoothScanner.sortedDevices)
                name = DeviceExporter.filename(for: report)
            case .json:
                data = try report.jsonData()
                name = DeviceExporter.filename(for: report)
                    .replacingOccurrences(of: ".xlsx", with: ".json")
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            exportFile = nil
        }
    }
}

// MARK: - Header

private struct NetworkHeaderCard: View {
    let scanner: NetworkScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: scanner.interfaceInfo?.kind.symbolName ?? "wifi.slash")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.22)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(scanner.interfaceInfo?.kind.rawValue ?? "Not connected")
                        .font(.headline)
                    // Built as an explicit String: inferring LocalizedStringKey
                    // here would interpolate IPv4 via its debug description.
                    let endpoint: String = scanner.interfaceInfo
                        .map { "\($0.name) · \($0.address.description)" }
                        ?? "Join a Wi-Fi or Ethernet network"
                    Text(verbatim: endpoint)
                        .font(.subheadline)
                        .opacity(0.85)
                }
                Spacer()
            }

            if let subnet = scanner.subnet {
                Divider().overlay(.white.opacity(0.3))
                HStack(spacing: 0) {
                    HeaderStat(title: "Subnet", value: subnet.description)
                    HeaderStat(title: "Addresses", value: "\(subnet.hostCount)")
                    HeaderStat(title: "Gateway", value: scanner.gateway?.description ?? "—")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

private struct HeaderStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .opacity(0.75)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Controls

private struct ScanControlPanel: View {
    let scanner: NetworkScanner
    @Binding var depth: ScanDepth
    @Binding var snmpCommunity: String
    @Binding var subnetText: String
    @Binding var scanAllSubnets: Bool

    var body: some View {
        VStack(spacing: 14) {
            Picker("Scan depth", selection: $depth) {
                ForEach(ScanDepth.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(scanner.isScanning)

            Text(depth.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if scanner.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: scanner.progress)
                    HStack {
                        Text(scanner.phase.label)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(scanner.statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else if case .failed(let message) = scanner.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !scanner.statusDetail.isEmpty {
                Text(scanner.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $scanAllSubnets) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan every network found")
                                .font(.caption.weight(.medium))
                            Text("Discovers the networks around this one and sweeps them all in turn.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(scanner.isScanning)

                    Text("How far to look for networks")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("How far to look for networks",
                           selection: Binding(get: { scanner.subnetSearchBreadth },
                                              set: { scanner.subnetSearchBreadth = $0 })) {
                        ForEach(SubnetDiscovery.Breadth.allCases) { breadth in
                            Text(breadth.label).tag(breadth)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(scanner.isScanning)
                    Text(scanner.subnetSearchBreadth.explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 2)

                    Text("Network to scan")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField(scanner.interfaceInfo?.subnet.description ?? "192.168.1.0/24",
                              text: $subnetText)
                        .opacity(scanAllSubnets ? 0.4 : 1)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        .disabled(scanner.isScanning || scanAllSubnets)
                    Text("Leave blank to sweep the network this device is on. Enter another network — 192.168.1.0/24, or just 192.168.1.1 for the /24 around it — to inventory a subnet on the far side of your router, such as a second SSID. It must be routable from here; mDNS and ARP do not cross a router, so names there come from reverse DNS, NetBIOS and UPnP instead.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !subnetText.trimmingCharacters(in: .whitespaces).isEmpty
                        && IPv4Subnet(cidr: subnetText) == nil {
                        Label("Not a network address the scanner can read.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Divider().padding(.vertical, 2)

                    Text("SNMP community")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("public", text: $snmpCommunity)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(scanner.isScanning)
                    Text("Asks the gateway for its ARP table, which is the only way to see MAC addresses for devices that answer neither mDNS nor NetBIOS. Most home routers have SNMP switched off; leave blank to skip.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption.weight(.medium))

            if let snmp = scanner.snmpResult {
                let summary = "SNMP: \(snmp.arpTable.count) ARP entries from the router"
                    + (scanner.snmpMACCount > 0 ? " · \(scanner.snmpMACCount) new MACs" : "")
                Label {
                    Text(verbatim: summary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if scanner.isScanning {
                    scanner.stop()
                } else {
                    let community = snmpCommunity.trimmingCharacters(in: .whitespaces)
                    scanner.snmpCommunities = community.isEmpty ? [] : [community]
                    scanner.scansAllSubnets = scanAllSubnets
                    scanner.targetSubnetOverride = scanAllSubnets ? nil : IPv4Subnet(cidr: subnetText)
                    scanner.start(depth: depth)
                }
            } label: {
                Label(scanner.isScanning ? "Stop Scan" : "Scan Network",
                      systemImage: scanner.isScanning ? "stop.fill" : "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(scanner.isScanning ? .red : .accentColor)
            .disabled(scanner.interfaceInfo == nil)
        }
        .padding(.vertical, 4)
    }
}

private struct CategoryFilterStrip: View {
    let categories: [DeviceCategory]
    let devices: [NetworkDevice]
    @Binding var selection: DeviceCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", symbol: "square.grid.2x2", count: devices.count, isOn: selection == nil) {
                    selection = nil
                }
                ForEach(categories) { category in
                    let count = devices.filter { $0.category == category }.count
                    chip(title: category.rawValue,
                         symbol: category.symbolName,
                         count: count,
                         isOn: selection == category) {
                        selection = selection == category ? nil : category
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: String, symbol: String, count: Int,
                      isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption2)
                Text(title).font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(isOn ? .white.opacity(0.3) : Color.secondary.opacity(0.18)))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.thinMaterial)))
            .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

private struct LocalNetworkDeniedBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local Network access is off", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            Text("iOS blocks all local network traffic until this app is allowed. "
                 + "Enable it in Settings › Privacy & Security › Local Network.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyStateRow: View {
    let isScanning: Bool
    let hasScanned: Bool
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isScanning ? "antenna.radiowaves.left.and.right" : "network")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var title: String {
        if isScanning { return "Listening…" }
        if isFiltered { return "No matches" }
        return hasScanned ? "No devices found" : "Nothing scanned yet"
    }

    private var message: String {
        if isScanning { return "Devices appear here as soon as they answer." }
        if isFiltered { return "Try a different search term or category." }
        return hasScanned
            ? "The network may isolate its clients from each other."
            : "Tap Scan Network to sweep your subnet."
    }
}

// MARK: - Share sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

