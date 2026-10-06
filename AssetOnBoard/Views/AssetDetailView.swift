//
//  AssetDetailView.swift
//  AssetOnBoard
//

import SwiftUI

struct AssetDetailView: View {
    let asset: DetectedAsset

    var body: some View {
        List {
            Section("Identity") {
                DetailRow(label: "Detected as", value: asset.rawLabel)
                DetailRow(label: "Category", value: asset.category.rawValue)
                DetailRow(label: "Found by", value: asset.source.rawValue)
                DetailRow(label: "Detector confidence", value: "\(Int(asset.confidence * 100))%")
                if asset.overallConfidence > asset.confidence {
                    DetailRow(label: "With corroboration",
                              value: "\(Int(asset.overallConfidence * 100))%")
                }
            }

            if let ip = asset.matchedDeviceIP {
                Section {
                    DetailRow(label: "Device", value: asset.matchedDeviceName ?? "—")
                    DetailRow(label: "IP address", value: ip.description, monospaced: true)
                    if let reason = asset.matchReason {
                        DetailRow(label: "Matched because", value: reason)
                    }
                } header: {
                    Text("Network device")
                } footer: {
                    Text("This object was tied to a device the Wi-Fi scan found. The photo supplies the physical location; the scan supplies the address — neither knows both on its own.")
                }
            }

            if !asset.barcodes.isEmpty {
                Section("Barcodes") {
                    ForEach(asset.barcodes, id: \.self) { code in
                        Text(verbatim: code)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            if !asset.recognizedText.isEmpty {
                Section {
                    ForEach(Array(asset.recognizedText.enumerated()), id: \.offset) { _, text in
                        Text(verbatim: text)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Text on this object (\(asset.recognizedText.count))")
                } footer: {
                    if let model = asset.likelyModelString {
                        Text(verbatim: "Most identifier-shaped string: \(model)")
                    }
                }
            }

            Section("Position in frame") {
                DetailRow(label: "Bounding box",
                          value: String(format: "x %.2f, y %.2f, w %.2f, h %.2f",
                                        asset.boundingBox.minX, asset.boundingBox.minY,
                                        asset.boundingBox.width, asset.boundingBox.height),
                          monospaced: true)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(asset.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CaptureDetailView: View {
    let capture: RoomCapture

    var body: some View {
        List {
            Section("Capture") {
                DetailRow(label: "Room", value: capture.roomName.isEmpty ? "Untitled" : capture.roomName)
                DetailRow(label: "Taken", value: capture.capturedAt.formatted())
                DetailRow(label: "Image", value: "\(capture.imageWidth) × \(capture.imageHeight)")
                DetailRow(label: "Processing", value: String(format: "%.2f s", capture.processingTime))
            }

            Section("Assets (\(capture.assets.count))") {
                ForEach(capture.assets) { asset in
                    NavigationLink {
                        AssetDetailView(asset: asset)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: asset.displayName).font(.subheadline.weight(.medium))
                            Text(verbatim: asset.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(capture.roomName.isEmpty ? "Capture" : capture.roomName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Camera

/// UIImagePickerController in camera mode.
///
/// PhotosPicker covers the library; taking a new photo still needs this.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
