//
//  RoomVideoSweeper.swift
//  AssetOnBoard
//
//  Inventories a room by walking through it with the camera running.
//
//  A photograph catches whatever fits in one frame from one angle. A sweep sees
//  the whole room, gets close enough to several things in turn for their labels
//  to be legible, and does not require anyone to decide in advance what to point
//  at. For onboarding that is the difference between reading three model numbers
//  and reading thirty.
//
//  The hard part is not detection but counting. One printer visible for twelve
//  seconds is roughly forty frames; a register wants one row. So detections are
//  not collected, they are *tracked*: each is matched against an object already
//  being followed, and only unmatched detections open a new track. Matching runs
//  strongest-evidence-first:
//
//    1. A shared barcode. An asset tag is an identity, so it re-joins a track
//       even after the camera has looked away and come back.
//    2. Overlap with a track's last known box, for the same class. This is what
//       carries a slow pan, where an object drifts a little between frames.
//
//  Nothing here merges two *different* objects: two laptops side by side hold
//  separate boxes and stay separate tracks. The cost of that choice is the
//  opposite error — pan away from a desk and back, and an untagged object with
//  no legible text may open a second track. Barcodes and model numbers close
//  that gap, and they are what the register wants anyway.
//
//  Keeping the viewfinder smooth while all that runs takes four things, and
//  losing any one of them brings the stutter back:
//
//    · The capture callback analyses nothing. It hands the frame to another
//      queue and returns, so AVFoundation stays free to deliver and drop frames
//      rather than waiting on Vision behind a blocked delegate.
//    · Text recognition runs on a slower cadence than object detection. Reading
//      a label costs several times what finding a box does, and a model number
//      does not need re-reading four times a second.
//    · The next pass is timed from when the last one *finished*, so a busy
//      device backs off by itself instead of queueing work it cannot catch up on.
//    · The track list is not observable. Republishing a few hundred tracks to
//      SwiftUI several times a second cost more than the detection did.
//

import Foundation
import ARKit
import AVFoundation
import RealityKit
import Vision
import Observation
import simd

@MainActor
@Observable
final class RoomVideoSweeper {

    enum State: Equatable {
        case idle
        case preparing
        case sweeping
        case finished
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Ready"
            case .preparing: "Starting the camera…"
            case .sweeping: "Sweeping"
            case .finished: "Done"
            case .failed(let message): message
            }
        }

        var isActive: Bool { self == .sweeping || self == .preparing }
    }

    /// Whether the device has found its place in a room it has swept before.
    ///
    /// Until it has, positions are in a fresh coordinate frame and mean nothing
    /// to the saved register, so nothing may be matched against it.
    enum Relocalization: Equatable {
        /// A new room, or one with no saved map. Everything found is new.
        case notRequested
        case searching
        case located
        case failed

        var label: String {
            switch self {
            case .notRequested: ""
            case .searching: "Point at something you scanned last time…"
            case .located: "Room recognised"
            case .failed: "Could not recognise the room — everything will be onboarded as new"
            }
        }
    }

    // MARK: - Observable state

    // Everything SwiftUI reads here is a scalar or a short array. The track list
    // is deliberately not observable: it is the working set, not the display
    // model, and publishing it per frame was most of the main-thread cost.
    private(set) var state: State = .idle
    private(set) var framesAnalysed = 0
    private(set) var peopleSeen = 0
    private(set) var confirmedCount = 0
    private(set) var trackedCount = 0
    private(set) var startedAt: Date?
    /// Boxes to draw over the viewfinder right now.
    private(set) var overlayBoxes: [OverlayBox] = []
    /// Assets this sweep found that the room already had on its register.
    private(set) var knownCount = 0
    /// Confirmed tracks the raycast could not place in the room.
    private(set) var unplacedCount = 0
    private(set) var relocalization: Relocalization = .notRequested

    /// The tracking core, deliberately free of ARKit so it can be tested.
    @ObservationIgnored private(set) var engine = AssetTrackingEngine()
    var tracks: [AssetTrack] { engine.tracks }
    /// What the room already knows, loaded before the sweep starts.
    @ObservationIgnored private var knownAssets: [SpatialAsset] = []

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    var confirmedAssets: [DetectedAsset] { engine.confirmedAssets }
    /// Only what the room has not seen before, which is what gets onboarded.
    var newAssets: [DetectedAsset] { engine.newAssets }
    /// Everything confirmed, in the form the room register consumes.
    var sweptAssets: [SweptAsset] { engine.sweptAssets }

    var newCount: Int { engine.newAssets.count }

    // MARK: - Tuning

    // MARK: - Capture

    /// Renders the camera and owns the ARKit session.
    ///
    /// RealityKit's view is used purely as a camera preview — nothing is added
    /// to its scene. It is here because it renders the feed and holds the
    /// session, and hand-rolling either would be work for its own sake.
    let arView = ARView(frame: .zero)
    var session: ARSession { arView.session }

    /// Receives frames. Kept free of real work so delivery never backs up.
    private let captureQueue = DispatchQueue(label: "com.sclera.assetonboard.sweep.capture",
                                             qos: .userInitiated)
    /// Where Vision actually runs.
    private let analysisQueue = DispatchQueue(label: "com.sclera.assetonboard.sweep.vision",
                                              qos: .userInitiated)
    private var relay: FrameRelay?
    private var context: SweepContext?

    // MARK: - Lifecycle

    /// Opens the camera and begins sweeping.
    ///
    /// - Parameter detector: the Core ML model RoomScanner already loaded,
    ///   shared rather than loaded a second time. The text and barcode passes
    ///   run with or without it.
    /// - Parameters:
    ///   - detector: the Core ML model RoomScanner already loaded, shared rather
    ///     than loaded a second time. Text and barcodes run with or without it.
    ///   - known: what this room already has on its register. Anything matched
    ///     against it is reported rather than onboarded again.
    ///   - worldMap: the room's saved ARKit map. With one, the session tries to
    ///     relocalise and positions line up with `known`; without one, every
    ///     position is in a fresh frame and nothing can be matched.
    func start(detector: VNCoreMLModel?,
               confidenceThreshold: Double,
               known: [SpatialAsset] = [],
               worldMap: ARWorldMap? = nil) async {
        guard !state.isActive else { return }

        state = .preparing
        engine.reset()
        overlayBoxes = []
        framesAnalysed = 0
        peopleSeen = 0
        confirmedCount = 0
        trackedCount = 0
        knownCount = 0
        unplacedCount = 0
        knownAssets = known
        relocalization = worldMap == nil ? .notRequested : .searching

        guard ARWorldTrackingConfiguration.isSupported else {
            state = .failed("This device cannot track its position, so a sweep cannot place assets in the room.")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            state = .failed("Camera access is off. Turn it on in Settings to sweep a room.")
            return
        }

        let context = SweepContext(detector: detector, threshold: confidenceThreshold)
        self.context = context

        let configuration = ARWorldTrackingConfiguration()
        // Planes are what a raycast lands on; without them a detection has no
        // surface to be placed against and stays unplaced.
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none
        // On a LiDAR device the mesh gives far better placement than estimated
        // planes, especially for hardware on open shelving.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if let worldMap { configuration.initialWorldMap = worldMap }

        // The session and the analysis context are captured here, on the main
        // actor, so the per-frame callback never has to reach back for them.
        let sessionRef = self.session
        let analysisQueue = self.analysisQueue
        let relay = FrameRelay { [weak self] frame in
            guard let self else { return }
            let tracking = frame.camera.trackingState
            Task { @MainActor in self.noteTracking(tracking) }

            guard let job = context.claim(now: Date()) else { return }
            // Ownership of the frame passes to the analysis queue: the delegate
            // has returned by then, and `claim` allows one pass at a time.
            let captured = frame
            nonisolated(unsafe) let session = sessionRef
            analysisQueue.async {
                let detected = context.analyse(captured.capturedImage, job: job)
                let placed = Self.place(detected, in: captured, using: session)
                Task { @MainActor in self.absorb(placed) }
            }
        }
        self.relay = relay
        session.delegate = relay
        session.delegateQueue = captureQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        startedAt = Date()
        state = .sweeping
    }

    /// Asks ARKit for the map of what has been seen so far.
    ///
    /// Saved at the end of a sweep so the next one can relocalise. It can fail
    /// when too little of the room has been mapped, which is why the caller has
    /// to cope with nil rather than assume.
    func currentWorldMap() async -> ARWorldMap? {
        await withCheckedContinuation { continuation in
            session.getCurrentWorldMap { map, _ in continuation.resume(returning: map) }
        }
    }

    /// Ends the sweep and returns what it confirmed.
    @discardableResult
    func stop() -> [DetectedAsset] {
        session.pause()
        if state.isActive { state = .finished }
        return confirmedAssets
    }

    func reset() {
        stop()
        engine.reset()
        overlayBoxes = []
        framesAnalysed = 0
        peopleSeen = 0
        confirmedCount = 0
        trackedCount = 0
        startedAt = nil
        context = nil
        knownAssets = []
        knownCount = 0
        unplacedCount = 0
        relocalization = .notRequested
        state = .idle
    }

    // MARK: - Frames

    /// Raycasts each detection onto real geometry to get a world position.
    ///
    /// The query is built from the frame the detection actually came from, not
    /// from wherever the camera is by the time analysis finishes — a pan during
    /// those few hundred milliseconds would otherwise throw the ray far enough
    /// off to matter at a half-metre matching radius.
    nonisolated private static func place(_ frame: FrameDetections,
                                          in arFrame: ARFrame,
                                          using session: ARSession) -> FrameDetections {
        var placed = frame
        for index in placed.objects.indices {
            let point = AssetTrackingEngine.imagePoint(forVisionBox: placed.objects[index].box)
            // Existing geometry first: on a LiDAR device that is the mesh, which
            // is accurate. Estimated planes are the fallback everywhere else.
            let query = arFrame.raycastQuery(from: point,
                                             allowing: .estimatedPlane,
                                             alignment: .any)
            guard let result = session.raycast(query).first else { continue }
            let t = result.worldTransform.columns.3
            placed.objects[index].worldPosition = SIMD3<Float>(t.x, t.y, t.z)
        }
        return placed
    }

    private func noteTracking(_ tracking: ARCamera.TrackingState) {
        guard relocalization != .notRequested else { return }
        switch tracking {
        case .normal:
            if relocalization != .located { relocalization = .located }
        case .limited(.relocalizing):
            if relocalization == .failed { relocalization = .searching }
        default:
            break
        }
    }

    // MARK: - Tracking

    func absorb(_ frame: FrameDetections) {
        framesAnalysed += 1
        peopleSeen = max(peopleSeen, frame.people)
        // Matching against the register is only meaningful once the session has
        // relocalised: before that the positions are in a fresh coordinate
        // frame that has nothing to do with the one the register was written
        // in, and matching against it would pair assets by coincidence.
        let visible = engine.absorb(frame,
                                    knownAssets: relocalization == .located ? knownAssets : [],
                                    at: Date())
        publish(visible: visible)
    }

    /// Pushes the small display values, and only when they actually changed.
    ///
    /// `updateUIView` runs on every parent re-render, including the clock tick
    /// once a second, so an unchanged overlay has to cost nothing.
    private func publish(visible: Set<UUID>) {
        let boxes = engine.overlayBoxes(visible: visible)
        if boxes != overlayBoxes { overlayBoxes = boxes }

        let counts = engine.counts
        if counts.confirmed != confirmedCount { confirmedCount = counts.confirmed }
        if counts.tracked != trackedCount { trackedCount = counts.tracked }
        if counts.known != knownCount { knownCount = counts.known }
        if counts.unplaced != unplacedCount { unplacedCount = counts.unplaced }
    }

}

// MARK: - Analysis

/// What one pass should run.
nonisolated private struct AnalysisJob: Sendable {
    /// Text and barcodes run on a slower cadence than object detection: reading
    /// a label costs several times what finding a box does, and a model number
    /// does not need re-reading four times a second.
    let includesText: Bool
}

/// Everything the capture and analysis queues need, fixed for one sweep.
///
/// Owns the Vision requests too. Rebuilding a `VNCoreMLRequest` per frame is
/// pure overhead; they are reusable, and only one pass runs at a time.
nonisolated private final class SweepContext: @unchecked Sendable {
    /// Gap between object-detection passes.
    private let objectInterval: TimeInterval = 0.25
    /// Gap between text and barcode passes.
    private let textInterval: TimeInterval = 0.8

    private let lock = NSLock()
    private var busy = false
    private var lastObjectPass = Date.distantPast
    private var lastTextPass = Date.distantPast

    private let threshold: Double
    private let objectRequest: VNCoreMLRequest?
    private let textRequest: VNRecognizeTextRequest
    private let barcodeRequest: VNDetectBarcodesRequest

    init(detector: VNCoreMLModel?, threshold: Double) {
        self.threshold = threshold
        objectRequest = detector.map { model in
            let request = VNCoreMLRequest(model: model)
            // Letterbox rather than crop: a router at the edge of the frame
            // should not be cut away before the model sees it.
            request.imageCropAndScaleOption = .scaleFit
            return request
        }
        textRequest = VNRecognizeTextRequest()
        // `.fast` rather than `.accurate`: this runs repeatedly, and a model
        // number gets read across many frames rather than one.
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        barcodeRequest = VNDetectBarcodesRequest()
    }

    /// Claims the analysis slot when a pass is due, describing what to run.
    ///
    /// Returns nil while one is already in flight, so a device slower than the
    /// interval backs off on its own rather than queueing work it can never
    /// catch up on.
    func claim(now: Date) -> AnalysisJob? {
        lock.withLock {
            guard !busy, now.timeIntervalSince(lastObjectPass) >= objectInterval else { return nil }
            busy = true
            let includesText = now.timeIntervalSince(lastTextPass) >= textInterval
            if includesText { lastTextPass = now }
            return AnalysisJob(includesText: includesText)
        }
    }

    /// Frees the slot, timing the next pass from when this one *ended*.
    func release(finishedAt: Date) {
        lock.withLock {
            busy = false
            lastObjectPass = finishedAt
        }
    }

    /// Runs the due passes on one frame and returns plain values.
    ///
    /// Vision's observation types are classes and not Sendable, so none of them
    /// cross back to the main actor — only the structs built here do.
    func analyse(_ buffer: CVPixelBuffer, job: AnalysisJob) -> FrameDetections {
        var result = FrameDetections()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])

        var requests: [VNRequest] = []
        if let objectRequest { requests.append(objectRequest) }
        if job.includesText {
            requests.append(textRequest)
            requests.append(barcodeRequest)
        }
        guard !requests.isEmpty else { return result }
        try? handler.perform(requests)

        if let observations = objectRequest?.results as? [VNRecognizedObjectObservation] {
            for observation in observations {
                guard let top = observation.labels.first,
                      Double(top.confidence) >= threshold else { continue }
                if COCOAssetCatalog.personClasses.contains(top.identifier.lowercased()) {
                    result.people += 1
                    continue
                }
                result.objects.append(ObjectDetection(
                    label: COCOAssetCatalog.displayName(for: top.identifier),
                    category: COCOAssetCatalog.category(for: top.identifier) ?? .other,
                    confidence: Double(top.confidence),
                    box: observation.boundingBox))
            }
        }

        guard job.includesText else { return result }

        if let observations = textRequest.results {
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence > 0.35 else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 3 else { continue }
                result.texts.append(BoxedString(value: text, box: observation.boundingBox))
            }
        }

        if let observations = barcodeRequest.results {
            for observation in observations {
                guard let payload = observation.payloadStringValue else { continue }
                result.barcodes.append(BoxedString(value: payload, box: observation.boundingBox))
            }
        }

        return result
    }
}

/// Forwards ARKit frames without dragging actor isolation onto the delegate.
nonisolated private final class FrameRelay: NSObject, ARSessionDelegate, @unchecked Sendable {
    private let onFrame: @Sendable (ARFrame) -> Void

    init(onFrame: @escaping @Sendable (ARFrame) -> Void) {
        self.onFrame = onFrame
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame(frame)
    }
}
