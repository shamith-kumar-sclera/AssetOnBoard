//
//  RoomScanView.swift
//  AssetOnBoard
//
//  Onboarding assets from a photograph of a room.
//

import SwiftUI
import PhotosUI

struct RoomScanView: View {
    let scanner: RoomScanner
    let networkScanner: NetworkScanner

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var roomName = ""
    @State private var showingCamera = false
    @State private var showingSweep = false
    @State private var showsBoxes = true
    @State private var sweeper = RoomVideoSweeper()
    @State private var store = RoomStore()
    /// Which saved room the next sweep continues. Nil sweeps a new one.
    @State private var selectedRoomID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CaptureCard(image: image,
                                capture: scanner.captures.first,
                                showsBoxes: $showsBoxes)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                Section {
                    if store.rooms.isEmpty {
                        TextField("Room name (optional)", text: $roomName)
                            .textInputAutocapitalization(.words)
                    } else {
                        Picker("Room", selection: $selectedRoomID) {
                            Text("New room").tag(UUID?.none)
                            ForEach(store.rooms) { room in
                                Text(verbatim: "\(room.displayName) · \(room.assets.count)")
                                    .tag(UUID?.some(room.id))
                            }
                        }
                        if selectedRoomID == nil {
                            TextField("Room name (optional)", text: $roomName)
                                .textInputAutocapitalization(.words)
                        }
                    }

                    Button {
                        showingSweep = true
                    } label: {
                        Label("Video Sweep", systemImage: "video.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scanner.isBusy)

                    HStack(spacing: 10) {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)

                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Choose", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(scanner.isBusy)

                    Text(verbatim: sweepExplanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if scanner.isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(verbatim: scanner.phase.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                DetectorStatusSection(scanner: scanner)

                if let capture = scanner.captures.first {
                    ResultsSection(capture: capture, peopleCount: scanner.lastPeopleCount)
                }

                if scanner.captures.count > 1 {
                    Section("Earlier captures") {
                        ForEach(scanner.captures.dropFirst()) { capture in
                            NavigationLink {
                                CaptureDetailView(capture: capture)
                            } label: {
                                CaptureSummaryRow(capture: capture)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Room")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            scanner.reset()
                            image = nil
                        } label: {
                            Label("Clear Captures", systemImage: "trash")
                        }
                        .disabled(scanner.captures.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task { scanner.loadModel() }
            .onDisappear { sweeper.reset() }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { captured in
                    image = captured
                    analyse(captured)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showingSweep) {
                RoomSweepView(sweeper: sweeper,
                              scanner: scanner,
                              networkScanner: networkScanner,
                              roomName: roomName,
                              store: store,
                              existingRoomID: selectedRoomID) {
                    // The sweep produced its own capture; the still preview from
                    // an earlier photo would be a misleading thing to leave up.
                    image = nil
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let loaded = UIImage(data: data) else { return }
                    image = loaded
                    analyse(loaded)
                }
            }
        }
    }

    private var sweepExplanation: String {
        guard let id = selectedRoomID, let room = store.room(id) else {
            return "A sweep walks the room with the camera running and counts each object once, however many frames it appears in. It remembers where each asset was, so sweeping this room again onboards only what is new."
        }
        guard room.hasWorldMap else {
            return "\(room.displayName) has \(room.assets.count) asset\(room.assets.count == 1 ? "" : "s") but no saved map, so this sweep cannot recognise where it is. Everything found will be onboarded again."
        }
        return "Continues \(room.displayName), which already has \(room.assets.count) asset\(room.assets.count == 1 ? "" : "s"). Point the camera at something you scanned last time so the room can be recognised; anything already on the register is reported, not onboarded again."
    }

    private func analyse(_ image: UIImage) {
        Task {
            await scanner.analyse(image: image,
                                  roomName: roomName,
                                  networkDevices: networkScanner.devices)
        }
    }
}

// MARK: - Capture preview

private struct CaptureCard: View {
    let image: UIImage?
    let capture: RoomCapture?
    @Binding var showsBoxes: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let image {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)

                        if showsBoxes, let capture {
                            BoxOverlay(assets: capture.assets,
                                       imageSize: image.size,
                                       viewSize: geometry.size)
                        }
                    }
                }
                .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let capture, !capture.assets.isEmpty {
                    Toggle("Show detection boxes", isOn: $showsBoxes)
                        .font(.caption)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Photograph a room to inventory what is in it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Get close enough that labels are legible — a device across the room is a handful of pixels and will not be recognised.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            }
        }
    }
}

/// Draws detection boxes over the image, in the image's own coordinate space.
private struct BoxOverlay: View {
    let assets: [DetectedAsset]
    let imageSize: CGSize
    let viewSize: CGSize

    var body: some View {
        // The image is aspect-fit, so work out the letterboxed rect first.
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let offset = CGPoint(x: (viewSize.width - drawn.width) / 2,
                             y: (viewSize.height - drawn.height) / 2)

        ForEach(assets) { asset in
            // Vision's origin is bottom-left; SwiftUI's is top-left.
            let box = asset.boundingBox
            let rect = CGRect(x: offset.x + box.minX * drawn.width,
                              y: offset.y + (1 - box.maxY) * drawn.height,
                              width: box.width * drawn.width,
                              height: box.height * drawn.height)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(tint(for: asset), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)

                Text(verbatim: asset.rawLabel)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(tint(for: asset), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(y: -12)
            }
            .position(x: rect.midX, y: rect.midY)
        }
    }

    private func tint(for asset: DetectedAsset) -> Color {
        asset.category.isInventoryRelevant ? .green : .secondary
    }
}

// MARK: - Sections

private struct DetectorStatusSection: View {
    let scanner: RoomScanner

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: scanner.modelState.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(scanner.modelState.isUsable ? .green : .orange)
                Text(verbatim: scanner.modelState.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Detector")
        } footer: {
            Text("The detector is trained on COCO, which has no class for a router, access point, printer, switch, NAS or server — so it will not find most of what the Wi-Fi tab does. Reading model numbers and asset tags off the hardware is the pass that carries this feature, and it runs regardless.")
        }
    }
}

private struct ResultsSection: View {
    let capture: RoomCapture
    let peopleCount: Int

    var body: some View {
        if capture.assets.isEmpty {
            Section {
                Text("Nothing recognised in that photo. Try moving closer, or framing fewer things at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Assets")
            }
        } else {
            Section {
                ForEach(capture.assets) { asset in
                    NavigationLink {
                        AssetDetailView(asset: asset)
                    } label: {
                        AssetRow(asset: asset)
                    }
                }
            } header: {
                HStack {
                    Text("Assets (\(capture.assets.count))")
                    Spacer()
                    Text(verbatim: String(format: "%.1fs", capture.processingTime))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    let relevant = capture.inventoryAssets.count
                    Text(verbatim: "\(relevant) of \(capture.assets.count) are things an asset register would carry; the rest are furniture and context.")
                    if peopleCount > 0 {
                        Text(verbatim: "\(peopleCount) \(peopleCount == 1 ? "person was" : "people were") detected and deliberately not recorded.")
                    }
                }
            }

            if !capture.looseText.isEmpty {
                Section("Text not tied to an object (\(capture.looseText.count))") {
                    Text(verbatim: capture.looseText.prefix(25).joined(separator: " · "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Rows

private struct AssetRow: View {
    let asset: DetectedAsset

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.16))
                Image(systemName: asset.category.symbolName)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: asset.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: asset.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let reason = asset.matchReason {
                    Text(verbatim: reason)
                        .font(.caption2)
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text(verbatim: "\(Int(asset.overallConfidence * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var tint: Color {
        asset.matchedDeviceIP != nil ? .teal
            : asset.category.isInventoryRelevant ? .blue : .secondary
    }
}

private struct CaptureSummaryRow: View {
    let capture: RoomCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: capture.roomName.isEmpty ? "Untitled room" : capture.roomName)
                .font(.subheadline.weight(.semibold))
            Text(verbatim: "\(capture.inventoryAssets.count) assets · \(capture.capturedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
