//
//  DetectedAsset.swift
//  AssetOnBoard
//
//  One thing seen in a photograph of a room.
//
//  Deliberately not called a device: an object detector reports what something
//  looks like, which is a weaker claim than anything the network tabs make. A
//  row here means "a printer-shaped object was visible", not "a printer exists
//  at 10.2.30.45". Where the two can be joined, `matchedDevice` records it and
//  the confidence rises accordingly.
//

import Foundation
import CoreGraphics

nonisolated extension CGRect {
    /// Used to pick the smallest box enclosing a label, in both the photo pass
    /// and the video sweep.
    var area: CGFloat { width * height }
}

nonisolated enum AssetDetectionSource: String, Sendable, Codable, Hashable {
    case objectDetector = "Object detector"
    case sceneClassifier = "Scene classifier"
    case textRecognition = "Label text"
    case barcode = "Barcode"

    var symbolName: String {
        switch self {
        case .objectDetector: "viewfinder"
        case .sceneClassifier: "sparkle.magnifyingglass"
        case .textRecognition: "text.viewfinder"
        case .barcode: "barcode.viewfinder"
        }
    }
}

nonisolated enum AssetCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case display = "Display"
    case computer = "Computer"
    case peripheral = "Peripheral"
    case phone = "Phone"
    case networkGear = "Network Equipment"
    case printer = "Printer"
    case appliance = "Appliance"
    case furniture = "Furniture"
    case other = "Other"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .display: "display"
        case .computer: "laptopcomputer"
        case .peripheral: "keyboard"
        case .phone: "iphone"
        case .networkGear: "wifi.router"
        case .printer: "printer"
        case .appliance: "oven"
        case .furniture: "chair"
        case .other: "cube"
        }
    }

    /// Whether this is something an IT asset register would actually carry.
    ///
    /// Furniture is detected and shown because it helps a human recognise the
    /// room, but it is not what the export is for.
    var isInventoryRelevant: Bool {
        switch self {
        case .display, .computer, .peripheral, .phone, .networkGear, .printer: true
        case .appliance, .furniture, .other: false
        }
    }
}

nonisolated struct DetectedAsset: Identifiable, Sendable, Codable, Hashable {
    var id = UUID()
    /// The class name the model emitted, kept verbatim so the UI never implies
    /// more precision than the model offered.
    var rawLabel: String
    var category: AssetCategory
    var confidence: Double
    /// Normalised, origin bottom-left — Vision's convention, not UIKit's.
    var boundingBox: CGRect
    var source: AssetDetectionSource

    /// Text found inside this object's bounds: model numbers, asset tags.
    var recognizedText: [String] = []
    var barcodes: [String] = []
    /// How many analysed frames saw this object.
    ///
    /// Always 1 for a photograph. A video sweep counts, and a thing seen across
    /// twenty frames is far less likely to be a reflection than one seen once.
    var sightings: Int = 1

    /// A network device this object was matched to, when one could be found.
    var matchedDeviceIP: IPv4?
    var matchedDeviceName: String?
    var matchReason: String?

    var displayName: String {
        if let matchedDeviceName { return matchedDeviceName }
        // A model string read off the case is the better title for a device —
        // "M404dn" beats "Printer". For anything that is not inventory, it is
        // just whatever text happened to be printed on it, and the class name
        // is the more honest label.
        if category.isInventoryRelevant, let model = likelyModelString { return model }
        return rawLabel.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var subtitle: String {
        var parts: [String] = []
        // When the title became a model string, say what it actually is.
        if displayName != rawLabel { parts.append(rawLabel) }
        parts.append(category.rawValue)
        if matchedDeviceIP != nil { parts.append("matched to network device") }
        if !barcodes.isEmpty { parts.append("\(barcodes.count) barcode\(barcodes.count == 1 ? "" : "s")") }
        else if !recognizedText.isEmpty { parts.append("\(recognizedText.count) text item\(recognizedText.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The most model-number-looking string found on the object.
    ///
    /// Asset labels are mostly noise — "CAUTION", "100-240V" — so this prefers
    /// strings that mix letters and digits and are long enough to be an
    /// identifier rather than a word.
    var likelyModelString: String? {
        recognizedText
            .filter { candidate in
                let hasLetter = candidate.contains(where: \.isLetter)
                let hasDigit = candidate.contains(where: \.isNumber)
                return hasLetter && hasDigit && candidate.count >= 5 && candidate.count <= 32
            }
            .max { $0.count < $1.count }
    }

    /// Detector confidence, raised when an independent signal agreed.
    var overallConfidence: Double {
        var score = confidence
        if matchedDeviceIP != nil { score = min(1, score + 0.25) }
        if !barcodes.isEmpty { score = min(1, score + 0.1) }
        // Repeated sightings across a sweep are corroboration of a kind a single
        // photograph cannot offer, and they cost nothing to count.
        if sightings >= 5 { score = min(1, score + 0.1) }
        else if sightings >= 2 { score = min(1, score + 0.05) }
        return score
    }
}

/// How a capture was taken.
nonisolated enum CaptureSource: String, Sendable, Codable {
    case photo = "Photo"
    case videoSweep = "Video sweep"

    var symbolName: String {
        switch self {
        case .photo: "camera.fill"
        case .videoSweep: "video.fill"
        }
    }
}

/// One capture — a photograph or a sweep — and everything found in it.
nonisolated struct RoomCapture: Identifiable, Sendable, Codable {
    var id = UUID()
    var capturedAt = Date()
    /// Free-text room name the user typed, for the export.
    var roomName: String = ""
    var assets: [DetectedAsset] = []
    /// Text found anywhere in the frame, not attributable to one object.
    var looseText: [String] = []
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    /// How long the whole vision pass took, for the UI to be honest about cost.
    var processingTime: TimeInterval = 0
    var source: CaptureSource = .photo
    /// Frames actually analysed, for a sweep. Zero for a photograph.
    var framesAnalysed: Int = 0
    /// Wall-clock length of the sweep.
    var sweepDuration: TimeInterval = 0

    var inventoryAssets: [DetectedAsset] {
        assets.filter { $0.category.isInventoryRelevant }
    }
}
