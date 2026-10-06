//
//  BluetoothScanView.swift
//  AssetOnBoard
//
//  The Bluetooth half of the app: discover nearby BLE peripherals.
//

import SwiftUI

struct BluetoothScanView: View {
    let scanner: BluetoothScanner
    let networkScanner: NetworkScanner

    @State private var searchText = ""
    @State private var categoryFilter: BluetoothCategory?
    @State private var exportFile: BluetoothExportFile?

    private var visibleDevices: [BluetoothDevice] {
        scanner.sortedDevices.filter { device in
            if let categoryFilter, device.category != categoryFilter { return false }
            guard !searchText.isEmpty else { return true }
            return device.matches(searchText)
        }
    }

    private var presentCategories: [BluetoothCategory] {
        BluetoothCategory.allCases.filter { category in
            scanner.devices.contains { $0.category == category }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { RadioStatusCard(scanner: scanner) }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)

                if scanner.availability != .ready {
                    Section { AvailabilityBanner(availability: scanner.availability) }
                }

                Section { BluetoothControlPanel(scanner: scanner) }

                if !presentCategories.isEmpty {
                    Section {
                        BluetoothFilterStrip(categories: presentCategories,
                                             devices: scanner.devices,
                                             selection: $categoryFilter)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Section {
                    if visibleDevices.isEmpty {
                        BluetoothEmptyState(isScanning: scanner.isScanning,
                                            availability: scanner.availability,
                                            isFiltered: !searchText.isEmpty || categoryFilter != nil)
                    } else {
                        ForEach(visibleDevices) { device in
                            NavigationLink {
                                BluetoothDeviceDetailView(device: device, scanner: scanner)
                            } label: {
                                BluetoothDeviceRow(device: device)
                            }
                        }
                    }
                } header: {
                    if !scanner.devices.isEmpty {
                        HStack {
                            Text("Nearby devices")
                            Spacer()
                            Text("\(visibleDevices.count) of \(scanner.devices.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Bluetooth")
            .searchable(text: $searchText, prompt: "Name, manufacturer, service")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            exportWorkbook()
                        } label: {
                            Label("Export Excel (.xlsx)", systemImage: "tablecells")
                        }
                        .disabled(scanner.devices.isEmpty)

                        Toggle(isOn: Binding(
                            get: { scanner.reportsRepeatAdvertisements },
                            set: { scanner.reportsRepeatAdvertisements = $0 }
                        )) {
                            Label("Live signal updates", systemImage: "waveform")
                        }

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
                BluetoothShareSheet(url: file.url)
            }
            // Creating the central manager is what raises the iOS permission
            // prompt, so it happens when this tab is first opened rather than
            // at app launch.
            .task { scanner.prepare() }
        }
    }

    private func exportWorkbook() {
        let report = networkScanner.lastReport ?? networkScanner.currentReport(depth: .standard)
        let data = DeviceExporter.workbook(for: report, bluetoothDevices: scanner.sortedDevices)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "AssetOnBoard-Bluetooth-\(formatter.string(from: Date())).xlsx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            exportFile = BluetoothExportFile(url: url)
        } catch {
            exportFile = nil
        }
    }
}

// MARK: - Header

private struct RadioStatusCard: View {
    let scanner: BluetoothScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: scanner.isScanning
                      ? "dot.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.22)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Bluetooth LE")
                        .font(.headline)
                    Text(verbatim: headline)
                        .font(.subheadline)
                        .opacity(0.85)
                        .lineLimit(2)
                }
                Spacer()
            }

            Divider().overlay(.white.opacity(0.3))
            HStack(spacing: 0) {
                BluetoothStat(title: "Devices", value: "\(scanner.devices.count)")
                BluetoothStat(title: "Connectable",
                              value: "\(scanner.devices.filter(\.isConnectable).count)")
                BluetoothStat(title: "Named",
                              value: "\(scanner.devices.filter { $0.name != nil || $0.localName != nil }.count)")
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.blue, Color.indigo],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var headline: String {
        guard scanner.availability == .ready else { return scanner.availability.message }
        return scanner.statusDetail.isEmpty ? "Ready to scan" : scanner.statusDetail
    }
}

private struct BluetoothStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .opacity(0.75)
            Text(verbatim: value)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AvailabilityBanner: View {
    let availability: BluetoothScanner.Availability

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: availability.symbolName)
            }
            .font(.subheadline.weight(.semibold))

            Text(verbatim: availability.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            if availability == .unauthorised,
               let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch availability {
        case .unauthorised: "Bluetooth permission needed"
        case .poweredOff: "Bluetooth is off"
        case .unsupported: "Bluetooth unavailable"
        default: "Preparing"
        }
    }
}

// MARK: - Controls

private struct BluetoothControlPanel: View {
    let scanner: BluetoothScanner

    var body: some View {
        VStack(spacing: 12) {
            if scanner.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(verbatim: scanner.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let duration = scanner.lastScanDuration {
                Text(verbatim: String(format: "Last scan ran for %.0f seconds", duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Devices appear as they broadcast. Some advertise only every few seconds, so give a scan 20-30 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                scanner.isScanning ? scanner.stopScan() : scanner.startScan()
            } label: {
                Label(scanner.isScanning ? "Stop Scan" : "Scan for Devices",
                      systemImage: scanner.isScanning ? "stop.fill" : "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(scanner.isScanning ? .red : .accentColor)
            .disabled(scanner.availability != .ready)
        }
        .padding(.vertical, 4)
    }
}

private struct BluetoothFilterStrip: View {
    let categories: [BluetoothCategory]
    let devices: [BluetoothDevice]
    @Binding var selection: BluetoothCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", symbol: "square.grid.2x2",
                     count: devices.count, isOn: selection == nil) { selection = nil }
                ForEach(categories) { category in
                    let count = devices.filter { $0.category == category }.count
                    chip(title: category.rawValue, symbol: category.symbolName,
                         count: count, isOn: selection == category) {
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
                Text(verbatim: title).font(.caption.weight(.medium))
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

private struct BluetoothEmptyState: View {
    let isScanning: Bool
    let availability: BluetoothScanner.Availability
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isScanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(verbatim: title)
                .font(.subheadline.weight(.medium))
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var title: String {
        if availability != .ready { return "Bluetooth unavailable" }
        if isScanning { return "Listening…" }
        if isFiltered { return "No matches" }
        return "Nothing scanned yet"
    }

    private var message: String {
        if availability != .ready { return availability.message }
        if isScanning { return "Nearby devices appear as soon as they advertise." }
        if isFiltered { return "Try a different search term or category." }
        return "Tap Scan for Devices to look for Bluetooth LE peripherals nearby."
    }
}

// MARK: - Row

struct BluetoothDeviceRow: View {
    let device: BluetoothDevice

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.indigo.opacity(0.16))
                Image(systemName: device.category.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(.indigo)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: device.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if device.isConnectable { Badge(text: "Connectable", tint: .green) }
                }
                Text(verbatim: device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    SignalBars(strength: device.signalStrength)
                    if let mac = device.macAddress {
                        Text(verbatim: mac.description)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.teal)
                    }
                    Text(verbatim: "\(device.rssi) dBm")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if let distance = device.estimatedDistance {
                        Text(verbatim: String(format: "~%.1f m", distance))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let battery = device.batteryLevel {
                        Label("\(battery)%", systemImage: "battery.100")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

struct SignalBars: View {
    let strength: BluetoothDevice.SignalStrength

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= strength.bars ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(3 + bar * 2))
            }
        }
        .frame(height: 11, alignment: .bottom)
    }

    private var tint: Color {
        switch strength {
        case .excellent, .good: .green
        case .fair: .orange
        case .weak: .red
        }
    }
}

// MARK: - Plumbing

struct BluetoothExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct BluetoothShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension BluetoothDevice {
    /// Matches the search box against every identifying string we hold.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        var haystack: [String] = [displayName, subtitle, category.rawValue, id.uuidString]
        haystack.append(contentsOf: [name, localName, manufacturerName, macVendor,
                                     macAddress?.description, appleContinuityType,
                                     appearanceName].compactMap { $0 })
        haystack.append(contentsOf: serviceNames)
        haystack.append(contentsOf: deviceInformation.values)
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}
