//
//  RoomScanner.swift
//  AssetOnBoard
//
//  Finds assets in a photograph of a room.
//
//  Three passes over one image, because no single one is sufficient:
//
//    1. A COCO object detector gives boxes and classes — where things are, and
//       roughly what they are. It is the weakest of the three for this purpose,
//       because COCO has no class for a router, an access point, a printer or a
//       switch, which is most of what this app inventories.
//    2. Text recognition reads what is printed on them. For asset onboarding
//       this is usually the most valuable pass: a model number or asset tag is
//       worth more in a register than a bounding box.
//    3. Barcode detection reads asset tags directly, where an estate uses them.
//
//  The results are then joined to the network inventory, which is the only
//  thing here that knows a device's address. A photo cannot see an IP.
//

import Foundation
import Vision
import CoreML
import UIKit
import Observation

@Observable
final class RoomScanner {

    enum ModelState: Equatable {
        case notLoaded
        case ready(name: String)
        case missing
        case failed(String)

        var message: String {
            switch self {
            case .notLoaded: "Preparing the detector…"
            case .ready(let name): "Detector: \(name)"
            case .missing:
                "No object-detection model is bundled. Text and barcode reading still work; object boxes need the Core ML model added to the target."
            case .failed(let reason): reason
            }
        }

        var isUsable: Bool { if case .ready = self { true } else { false } }
    }

    enum Phase: Equatable {
        case idle
        case detecting
        case readingText
        case matching
        case finished
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Ready"
            case .detecting: "Looking for objects"
            case .readingText: "Reading labels"
            case .matching: "Matching to network devices"
            case .finished: "Done"
            case .failed(let message): message
            }
        }
    }

    private(set) var modelState: ModelState = .notLoaded
    private(set) var phase: Phase = .idle
    private(set) var captures: [RoomCapture] = []
    /// People seen but deliberately not inventoried.
    private(set) var lastPeopleCount = 0

    var isBusy: Bool {
        switch phase {
        case .detecting, .readingText, .matching: true
        default: false
        }
    }

    /// Detections below this are dropped. COCO models are confident about
    /// furniture and vague about everything else, so this is not generous.
    var confidenceThreshold: Double = 0.25

    private var detector: VNCoreMLModel?

    /// The loaded detector, for the video sweeper to reuse.
    ///
    /// Compiling and loading a Core ML model costs a second or two; a sweep
    /// should not pay it again for the same file.
    var detectorModel: VNCoreMLModel? { detector }

    /// Names to look for in the bundle, best first.
    ///
    /// Plain YOLO. It knows the 80 COCO classes — laptops, screens, keyboards,
    /// phones, chairs — and nothing beyond them, so a printer or an access point
    /// is invisible to it and the text pass is what carries those.
    private static let candidateModelNames = ["yolo11m", "yolov8m", "yolo11s", "yolov8s"]

    // MARK: - Model loading

    /// Compiles and loads the bundled detector, if one was added to the target.
    ///
    /// Loaded by name rather than through the Core ML generated class so the app
    /// builds and runs with no model present — the other two passes still work.
    func loadModel() {
        guard modelState == .notLoaded else { return }

        for name in Self.candidateModelNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                    ?? Bundle.main.url(forResource: name, withExtension: "mlpackage")
            else { continue }

            do {
                let configuration = MLModelConfiguration()
                // Neural Engine where available, GPU otherwise.
                configuration.computeUnits = .all
                let model = try MLModel(contentsOf: url, configuration: configuration)
                detector = try VNCoreMLModel(for: model)
                modelState = .ready(name: name)
                return
            } catch {
                modelState = .failed("Could not load \(name): \(error.localizedDescription)")
                return
            }
        }
        modelState = .missing
    }

    // MARK: - Analysis

    func analyse(image: UIImage, roomName: String, networkDevices: [NetworkDevice]) async {
        loadModel()
        guard let cgImage = image.cgImage else {
            phase = .failed("That image could not be read.")
            return
        }

        let started = Date()
        var capture = RoomCapture(roomName: roomName)
        capture.imageWidth = cgImage.width
        capture.imageHeight = cgImage.height

        let handler = VNImageRequestHandler(cgImage: cgImage,
                                            orientation: image.cgImagePropertyOrientation,
                                            options: [:])

        // ---- 1. Objects -----------------------------------------------------
        phase = .detecting
        var assets: [DetectedAsset] = []
        var people = 0

        if let detector {
            let request = VNCoreMLRequest(model: detector)
            // Letterbox rather than crop: a router at the edge of the frame
            // should not be cut away before the model sees it.
            request.imageCropAndScaleOption = .scaleFit

            if let observations = try? await perform(request, with: handler) as? [VNRecognizedObjectObservation] {
                for observation in observations {
                    guard let top = observation.labels.first,
                          Double(top.confidence) >= confidenceThreshold else { continue }

                    if COCOAssetCatalog.personClasses.contains(top.identifier.lowercased()) {
                        people += 1
                        continue
                    }
                    // The same gate the sweep applies: furniture and the rest
                    // of what COCO can see are not assets and are not kept.
                    guard COCOAssetCatalog.isElectrical(top.identifier) else { continue }
                    let category = COCOAssetCatalog.category(for: top.identifier) ?? .other
                    assets.append(DetectedAsset(
                        rawLabel: COCOAssetCatalog.displayName(for: top.identifier),
                        category: category,
                        confidence: Double(top.confidence),
                        boundingBox: observation.boundingBox,
                        source: .objectDetector
                    ))
                }
            }
        }
        lastPeopleCount = people

        // ---- 2. Text and barcodes -------------------------------------------
        phase = .readingText
        var looseText: [String] = []

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        // Model numbers and serials are not words; the language model hurts here.
        textRequest.usesLanguageCorrection = false

        if let observations = try? await perform(textRequest, with: handler) as? [VNRecognizedTextObservation] {
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence > 0.3 else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 3 else { continue }
                assign(text: text, box: observation.boundingBox, to: &assets, otherwise: &looseText)
            }
        }

        let barcodeRequest = VNDetectBarcodesRequest()
        if let observations = try? await perform(barcodeRequest, with: handler) as? [VNBarcodeObservation] {
            for observation in observations {
                guard let payload = observation.payloadStringValue else { continue }
                if let index = indexOfAsset(containing: observation.boundingBox, in: assets) {
                    assets[index].barcodes.append(payload)
                } else {
                    // A tag on a wall with no object around it is still an asset.
                    assets.append(DetectedAsset(rawLabel: "Asset tag",
                                                category: .other,
                                                confidence: Double(observation.confidence),
                                                boundingBox: observation.boundingBox,
                                                source: .barcode,
                                                barcodes: [payload]))
                }
            }
        }

        // ---- 3. Join to what the network already knows ----------------------
        phase = .matching
        for index in assets.indices {
            crossReference(&assets[index], against: networkDevices)
        }

        capture.assets = assets.sorted { $0.overallConfidence > $1.overallConfidence }
        capture.looseText = looseText
        capture.processingTime = Date().timeIntervalSince(started)
        capture.source = .photo

        captures.insert(capture, at: 0)
        phase = .finished
    }

    /// Records a finished video sweep as a capture.
    ///
    /// The sweeper has already done detection and the cross-frame counting; what
    /// is left is the pass a photograph also gets — tying what was read off the
    /// hardware to a device the network scan found. That link is informational:
    /// the correlator never merges a camera record into a network row.
    func recordSweep(assets: [DetectedAsset],
                     roomName: String,
                     duration: TimeInterval,
                     framesAnalysed: Int,
                     peopleSeen: Int,
                     networkDevices: [NetworkDevice]) {
        phase = .matching
        var matched = assets
        for index in matched.indices {
            crossReference(&matched[index], against: networkDevices)
        }

        var capture = RoomCapture(roomName: roomName)
        capture.assets = matched.sorted { $0.overallConfidence > $1.overallConfidence }
        capture.processingTime = duration
        capture.source = .videoSweep
        capture.framesAnalysed = framesAnalysed
        capture.sweepDuration = duration

        lastPeopleCount = peopleSeen
        captures.insert(capture, at: 0)
        phase = .finished
    }

    func remove(_ capture: RoomCapture) {
        captures.removeAll { $0.id == capture.id }
    }

    func reset() {
        captures.removeAll()
        phase = .idle
        lastPeopleCount = 0
    }

    // MARK: - Joining passes

    /// Files a piece of text against whichever object encloses it.
    private func assign(text: String,
                        box: CGRect,
                        to assets: inout [DetectedAsset],
                        otherwise looseText: inout [String]) {
        if let index = indexOfAsset(containing: box, in: assets) {
            assets[index].recognizedText.append(text)
        } else {
            looseText.append(text)
        }
    }

    /// The smallest object whose box contains the centre of `box`.
    ///
    /// Smallest wins because a label on a laptop sits inside both the laptop's
    /// box and the desk's, and the laptop is the useful answer.
    private func indexOfAsset(containing box: CGRect, in assets: [DetectedAsset]) -> Int? {
        let centre = CGPoint(x: box.midX, y: box.midY)
        return assets.indices
            .filter { assets[$0].boundingBox.contains(centre) }
            .min { assets[$0].boundingBox.area < assets[$1].boundingBox.area }
    }

    /// Ties a photographed object to a device the network scan already found.
    ///
    /// Text is the strong signal — a model string read off the case matching a
    /// device's advertised model is close to proof. Category alone is weak and
    /// only used when exactly one candidate exists, because "there is a laptop
    /// in this photo and eleven on the network" identifies nothing.
    private func crossReference(_ asset: inout DetectedAsset, against devices: [NetworkDevice]) {
        guard !devices.isEmpty else { return }

        for text in asset.recognizedText where text.count >= 4 {
            let needle = text.lowercased()
            if let match = devices.first(where: { device in
                [device.modelName, device.modelIdentifier, device.vendor, device.hostnames.first]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(needle) || needle.contains($0) }
            }) {
                asset.matchedDeviceIP = match.ip
                asset.matchedDeviceName = match.displayName
                asset.matchReason = "Text “\(text)” matches \(match.displayName)"
                return
            }
        }

        let candidates = devices.filter { networkCategory(for: asset.category).contains($0.category) }
        if candidates.count == 1, let only = candidates.first {
            asset.matchedDeviceIP = only.ip
            asset.matchedDeviceName = only.displayName
            asset.matchReason = "Only \(only.category.rawValue.lowercased()) on the network"
        }
    }

    private func networkCategory(for category: AssetCategory) -> Set<DeviceCategory> {
        switch category {
        case .display: [.tv]
        case .computer: [.computer]
        case .phone: [.phone, .tablet]
        case .printer: [.printer]
        case .networkGear: [.router, .accessPoint]
        default: []
        }
    }

    // MARK: - Vision plumbing

    /// Runs one request on the shared handler off the main actor.
    private func perform(_ request: VNRequest,
                         with handler: VNImageRequestHandler) async throws -> [Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    continuation.resume(returning: request.results ?? [])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Helpers

nonisolated extension UIImage {
    /// Vision needs the EXIF orientation; UIImage carries its own enum.
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
