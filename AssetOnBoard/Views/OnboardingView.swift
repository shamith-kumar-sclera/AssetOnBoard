//
//  OnboardingView.swift
//  AssetOnBoard
//
//  The single screen: scan everything, see one list, export one file.
//

import SwiftUI

struct OnboardingView: View {
    let coordinator: OnboardingCoordinator
    let networkScanner: NetworkScanner
    let bluetoothScanner: BluetoothScanner
    let accessPointScanner: AccessPointScanner
    let roomScanner: RoomScanner
    /// Sends the user to the Room tab to photograph something.
    let onAddRoomPhoto: () -> Void

    @State private var depth: ScanDepth = .standard
    @State private var searchText = ""
    @State private var kindFilter: AssetKind?
    @State private var showsOnboardableOnly = true
    @State private var exportFile: OnboardingExportFile?

    private var visibleAssets: [UnifiedAsset] {
        let base = showsOnboardableOnly ? coordinator.onboardableAssets : coordinator.assets
        return base.filter { asset in
            if let kindFilter, asset.kind != kindFilter { return false }
            guard !searchText.isEmpty else { return true }
            return asset.matches(searchText)
        }
    }

    /// Live progress, read from whichever scanner is actually working.
    ///
    /// The coordinator only publishes at stage boundaries, and the network sweep
    /// between two of them can run for minutes — long enough that a bar sitting
    /// at 5% reads as a hang rather than as work.
    private var liveProgress: Double {
        switch coordinator.stage {
        case .sweeping: 0.05 + networkScanner.progress * 0.65
        case .infrastructure: 0.7 + (accessPointScanner.isScanning ? 0.1 : 0.2)
        default: coordinator.progress
        }
    }

    private var liveDetail: String {
        let detail: String = switch coordinator.stage {
        case .sweeping: networkScanner.statusDetail
        case .infrastructure: accessPointScanner.statusDetail
        default: coordinator.statusDetail
        }
        return detail.isEmpty ? coordinator.stage.label : detail
    }

    /// What the header counts while a run is in flight, before anything is merged.
    private var liveAssetCount: Int {
        coordinator.isRunning && coordinator.assets.isEmpty
            ? networkScanner.devices.count + bluetoothScanner.devices.count
            : coordinator.onboardableAssets.count
    }

    private var presentKinds: [AssetKind] {
        let base = showsOnboardableOnly ? coordinator.onboardableAssets : coordinator.assets
        let counts = Dictionary(grouping: base, by: \.kind)
        return AssetKind.allCases.filter { counts[$0]?.isEmpty == false }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    InventoryHeaderCard(coordinator: coordinator,
                                        assetCount: liveAssetCount,
                                        detail: liveDetail)
                }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                Section { controls }

                if !coordinator.assets.isEmpty {
                    Section {
                        ForEach(visibleAssets) { asset in
                            NavigationLink {
                                UnifiedAssetDetailView(asset: asset)
                            } label: {
                                UnifiedAssetRow(asset: asset)
                            }
                        }
                    } header: {
                        assetsHeader
                    } footer: {
                        if coordinator.mergedCount > 0 {
                            Text("\(coordinator.mergedCount) asset\(coordinator.mergedCount == 1 ? " was" : "s were") seen by more than one radio and merged into a single row. Open one to see what matched it, or check the Merge Evidence sheet in the export. Photographed objects are always listed separately.")
                        }
                    }
                } else if !coordinator.isRunning {
                    Section { EmptyInventoryRow() }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Onboarding")
            .searchable(text: $searchText, prompt: "Name, IP, MAC, vendor, room")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            export()
                        } label: {
                            Label("Export inventory (.xlsx)", systemImage: "tablecells")
                        }
                        .disabled(coordinator.assets.isEmpty)

                        Button(action: onAddRoomPhoto) {
                            Label("Add a room photo", systemImage: "camera")
                        }

                        Divider()

                        Button {
                            coordinator.correlate(network: networkScanner,
                                                  bluetooth: bluetoothScanner,
                                                  accessPoints: accessPointScanner,
                                                  room: roomScanner)
                        } label: {
                            Label("Re-match without scanning", systemImage: "arrow.triangle.merge")
                        }
                        .disabled(coordinator.isRunning)

                        Button(role: .destructive) {
                            coordinator.reset()
                        } label: {
                            Label("Clear results", systemImage: "trash")
                        }
                        .disabled(coordinator.isRunning || coordinator.assets.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(url: file.url)
            }
            // Photographs taken after a scan should appear without re-sweeping.
            .onChange(of: roomScanner.captures.count) { _, _ in
                guard !coordinator.isRunning, !coordinator.assets.isEmpty else { return }
                coordinator.correlate(network: networkScanner,
                                      bluetooth: bluetoothScanner,
                                      accessPoints: accessPointScanner,
                                      room: roomScanner)
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Depth", selection: $depth) {
                ForEach(ScanDepth.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(coordinator.isRunning)

            if coordinator.isRunning {
                ProgressView(value: liveProgress)
                    .tint(.accentColor)
                Text(verbatim: liveDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if coordinator.isRunning {
                    coordinator.stop()
                    networkScanner.stop()
                    accessPointScanner.stop()
                    bluetoothScanner.stopScan()
                } else {
                    coordinator.run(network: networkScanner,
                                    bluetooth: bluetoothScanner,
                                    accessPoints: accessPointScanner,
                                    room: roomScanner,
                                    depth: depth)
                }
            } label: {
                Label(coordinator.isRunning ? "Stop" : "Scan Everything",
                      systemImage: coordinator.isRunning ? "stop.fill" : "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.isRunning ? .red : .accentColor)

            Text("Runs the network sweep, the access-point scan and a Bluetooth listen together, then merges anything the same device answered on. Room photographs already taken are listed too, each as its own asset — a detector describes a shape, not a device, so those are never merged into a network row. The camera needs you to point it, so it is not part of the automatic run.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var assetsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Assets")
                Text(verbatim: "(\(visibleAssets.count))")
                Spacer()
                Toggle("Onboardable only", isOn: $showsOnboardableOnly)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if presentKinds.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        KindChip(title: "All", isSelected: kindFilter == nil) { kindFilter = nil }
                        ForEach(presentKinds) { kind in
                            KindChip(title: kind.rawValue,
                                     symbol: kind.symbolName,
                                     isSelected: kindFilter == kind) {
                                kindFilter = kindFilter == kind ? nil : kind
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Export

    private func export() {
        let report = networkScanner.lastReport ?? networkScanner.currentReport(depth: depth)
        let data = OnboardingExporter.workbook(assets: coordinator.assets,
                                               report: report,
                                               bluetoothDevices: bluetoothScanner.sortedDevices,
                                               accessPoints: accessPointScanner.accessPoints,
                                               captures: roomScanner.captures,
                                               startedAt: coordinator.startedAt,
                                               finishedAt: coordinator.finishedAt)
        let name = OnboardingExporter.filename(at: coordinator.finishedAt ?? Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            exportFile = OnboardingExportFile(url: url)
        } catch {
            exportFile = nil
        }
    }
}

// MARK: - Header

private struct InventoryHeaderCard: View {
    let coordinator: OnboardingCoordinator
    /// Merged assets once a run has finished, raw sightings while one is live.
    let assetCount: Int
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.22)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Site Inventory")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(verbatim: coordinator.isRunning ? detail : coordinator.stage.label)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer()
            }

            Divider().overlay(.white.opacity(0.3))

            HStack(alignment: .top) {
                statistic(coordinator.isRunning && coordinator.assets.isEmpty ? "FOUND" : "ASSETS",
                          "\(assetCount)")
                Spacer()
                statistic("MERGED", "\(coordinator.mergedCount)")
                Spacer()
                statistic("TIME", coordinator.duration.map { "\(Int($0.rounded()))s" } ?? "—")
            }

            if !coordinator.assets.isEmpty {
                HStack(spacing: 10) {
                    ForEach(AssetChannel.allCases) { channel in
                        let count = coordinator.countsByChannel[channel] ?? 0
                        if count > 0 {
                            Label("\(count)", systemImage: channel.symbolName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func statistic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(verbatim: value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}

private struct EmptyInventoryRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing scanned yet")
                .font(.subheadline.weight(.semibold))
            Text("Tap Scan Everything. The network sweep, access-point scan and Bluetooth listen run together, and anything the same device answered on ends up as one row rather than three.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Rows

private struct KindChip: View {
    let title: String
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.caption2) }
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                        in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }
}

private struct UnifiedAssetRow: View {
    let asset: UnifiedAsset

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: asset.kind.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: asset.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if asset.isCorroborated {
                        Text("\(asset.seenBy.count) scans")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(verbatim: asset.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                ForEach(asset.seenBy.sorted { $0.rawValue < $1.rawValue }) { channel in
                    Image(systemName: channel.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

private struct UnifiedAssetDetailView: View {
    let asset: UnifiedAsset

    var body: some View {
        List {
            Section("Identity") {
                row("Name", asset.name)
                row("Type", asset.kind.rawValue)
                row("Manufacturer", asset.vendor)
                row("Model", asset.model)
                row("Operating system", asset.operatingSystem)
                row("SSID", asset.ssid)
                row("Confidence", "\(Int((asset.confidence * 100).rounded()))%")
            }

            if !asset.ipAddresses.isEmpty || !asset.macAddresses.isEmpty {
                Section("Addresses") {
                    ForEach(asset.ipAddresses, id: \.self) { address in
                        row("IP", address.description, monospaced: true)
                    }
                    ForEach(asset.macAddresses, id: \.self) { mac in
                        row("MAC", mac.description, monospaced: true)
                    }
                    ForEach(asset.hostnames, id: \.self) { hostname in
                        row("Hostname", hostname, monospaced: true)
                    }
                }
            }

            Section("Seen by") {
                ForEach(asset.seenBy.sorted { $0.rawValue < $1.rawValue }) { channel in
                    Label(channel.rawValue, systemImage: channel.symbolName)
                }
            }

            if !asset.mergeEvidence.isEmpty {
                Section {
                    ForEach(asset.mergeEvidence, id: \.self) { reason in
                        Text(verbatim: reason).font(.caption)
                    }
                } header: {
                    Text("Why these were merged")
                } footer: {
                    Text("A merge is the one step that can remove a device from the register rather than duplicate it, so the reason is kept for every one.")
                }
            }

            if !asset.rooms.isEmpty || !asset.assetTags.isEmpty {
                Section("Physical") {
                    ForEach(asset.rooms, id: \.self) { room in row("Room", room) }
                    ForEach(asset.assetTags, id: \.self) { tag in
                        row("Asset tag", tag, monospaced: true)
                    }
                }
            }

            if !asset.openPorts.isEmpty {
                Section("Open ports") {
                    Text(verbatim: asset.openPorts.map(String.init).joined(separator: ", "))
                        .font(.caption.monospaced())
                }
            }

            if !asset.services.isEmpty {
                Section("Services") {
                    ForEach(asset.services, id: \.self) { service in
                        Text(verbatim: service).font(.caption)
                    }
                }
            }
        }
        .navigationTitle(asset.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?, monospaced: Bool = false) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: value)
                    .font(monospaced ? .body.monospaced() : .body)
                    .multilineTextAlignment(.trailing)
            }
            .font(.callout)
        }
    }
}

// MARK: - Export plumbing

private struct OnboardingExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
