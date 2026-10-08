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
//  being followed, and only unmatched detections open a new track. How that
//  matching is decided lives in AssetTrackingEngine, which has no ARKit in it
//  and can be tested. What lives here is everything that needs the device:
//
//    · ARKit's world tracking, which is what makes "the same place" mean
//      something. The camera's pose is known in one coordinate frame for the
//      whole sweep, so a detection can be pinned to a point in the room and,
//      when the camera comes back, asked whether it is looking at that point.
//    · Placement. A box in the picture is a direction, not a position; the
//      depth has to come from somewhere. Without LiDAR that is a raycast onto
//      a surface ARKit has estimated, or the feature points it has mapped in
//      that part of the view — gathered across frames, because any one frame
//      has too few.
//    · Vision, running the detector and the text and barcode readers.
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
//    · One analysis pass runs at a time. A frame that arrives while one is in
//      flight is skipped rather than queued, so a device slower than the
//      interval backs off by itself instead of queueing work it cannot catch
//      up on.
//    · The track list is not observable. Republishing a few hundred tracks to
//      SwiftUI several times a second cost more than the detection did.
//

import Foundation
import ARKit
import AVFoundation
import Combine
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
    /// Published so the overlay can map boxes onto the right aspect.
    private(set) var deviceOrientation: SweepOrientation = .portrait
    /// False when no Core ML model loaded, so only text and barcodes run.
    private(set) var hasDetector = false
    /// True while ARKit cannot vouch for the camera's pose — the first second
    /// or two, a fast pan, a blank wall. Nothing is pinned until it can.
    private(set) var trackingLimited = false

    /// Prints what the sweep is actually doing, for a device console.
    ///
    /// A sweep fails silently by nature: the viewfinder looks identical whether
    /// frames are flowing, the detector is finding things, or the raycasts are
    /// landing. These counters separate those three.
    @ObservationIgnored var diagnostics = SweepDiagnostics()

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
    /// Per-frame hook. RealityKit owns the ARSession delegate, so this is the
    /// supported way to do work on every frame.
    private var frameSubscription: AnyCancellable?
    private var context: SweepContext?

    init() {
        // Before the view ever reaches a window: otherwise RealityKit runs a
        // default session of its own first and reconfigures ours — discarding
        // `initialWorldMap`, so nothing relocalises.
        arView.automaticallyConfigureSession = false
    }

    // MARK: - Lifecycle

    /// Opens the camera and begins sweeping.
    ///
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
        trackingLimited = false
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
        hasDetector = detector != nil
        diagnostics = SweepDiagnostics()
        diagnostics.begin(hasDetector: detector != nil,
                          knownAssets: known.count,
                          relocalising: worldMap != nil)

        arView.automaticallyConfigureSession = false

        let configuration = ARWorldTrackingConfiguration()
        // Detected planes are what `.existingPlaneGeometry` raycasts land on;
        // `.estimatedPlane` fits its own to the feature points around the ray.
        // Placement tries both, so both are worth having.
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none
        // On a LiDAR device the mesh gives far better placement than estimated
        // planes, especially for hardware on open shelving.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if let worldMap { configuration.initialWorldMap = worldMap }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        // Frames come from RealityKit's scene update, not from ARSessionDelegate.
        //
        // ARView installs itself as the session's delegate and relies on being
        // it. Taking that over looks like it works — the camera still renders —
        // but the callback never fires, so nothing is ever analysed and the
        // sweep silently finds nothing. `SceneEvents.Update` is the supported
        // per-frame hook and leaves ARView's own delegate alone.
        let analysisQueue = self.analysisQueue
        nonisolated(unsafe) let session = self.session
        frameSubscription = AnyCancellable(
            arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            guard let self, let frame = session.currentFrame else { return }
            let now = Date()
            let tracking = frame.camera.trackingState
            let limited: Bool
            if case .normal = tracking { limited = false } else { limited = true }
            Task { @MainActor in
                self.diagnostics.framesReceived += 1
                if limited { self.diagnostics.limitedFrames += 1 }
                self.noteTracking(tracking)
            }

            // Feature points are gathered from every frame, not only the ones
            // analysed. Any one frame has a few hundred, scattered; a box on a
            // monitor often holds fewer than the three a placement needs. Three
            // seconds of them is a cloud dense enough to land on. They are in
            // world space, so frames pile up without any bookkeeping.
            if !limited, let cloud = frame.rawFeaturePoints {
                context.accumulate(points: cloud.points, identifiers: cloud.identifiers, at: now)
            }

            guard let job = context.claim(now: now) else { return }

            // The frame must not leave this callback. ARKit hands out buffers
            // from a small pool, and holding one across the few hundred
            // milliseconds Vision takes starves the capture pipeline until the
            // camera stalls — which looks exactly like detecting the first
            // frame and then freezing. So: copy the image, take the camera as
            // plain numbers, and let the frame go.
            guard let image = Self.copy(frame.capturedImage) else {
                context.release(job, finishedAt: Date())
                return
            }
            let snapshot = CameraSnapshot(transform: frame.camera.transform,
                                          intrinsics: frame.camera.intrinsics,
                                          resolution: frame.camera.imageResolution)
            let features = limited ? [] : context.featurePoints(at: now)
            nonisolated(unsafe) let buffer = image
            analysisQueue.async {
                let detected = context.analyse(buffer, job: job)
                var placed = Self.place(detected, from: snapshot, features: features,
                                        using: session, orientation: job.orientation,
                                        trackingLimited: limited)
                placed.timestamp = now
                // Free the slot before hopping back. Without this the sweep
                // claims once and never again: every later frame is refused,
                // so nothing reaches a second sighting and nothing is ever
                // confirmed — one frame of boxes, then a dead viewfinder.
                context.release(job, finishedAt: Date())
                Task { @MainActor in self.absorb(placed) }
            }
        })

        startedAt = Date()
        state = .sweeping
    }

    /// Tells the sweep how the device is being held.
    ///
    /// Called as the interface rotates. Everything downstream depends on it:
    /// what Vision is shown, and where in the room a detection is pinned.
    func update(orientation: SweepOrientation) {
        context?.orientation = orientation
        if deviceOrientation != orientation { deviceOrientation = orientation }
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
        frameSubscription?.cancel()
        frameSubscription = nil
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
        trackingLimited = false
        relocalization = .notRequested
        state = .idle
    }

    // MARK: - Frames

    /// Works out where in the room each detection is.
    ///
    /// The query is built from the frame the detection actually came from, not
    /// from wherever the camera is by the time analysis finishes — a pan during
    /// those few hundred milliseconds would otherwise throw the ray far enough
    /// off to matter at a half-metre matching radius.
    ///
    /// Nothing is placed while tracking is limited. ARKit says the pose then
    /// "may not be accurate or consistent", and a pin at a wrong position is
    /// worse than no pin: it is a duplicate waiting to happen.
    nonisolated private static func place(_ frame: FrameDetections,
                                          from camera: CameraSnapshot,
                                          features: [SIMD3<Float>],
                                          using session: ARSession,
                                          orientation: SweepOrientation,
                                          trackingLimited: Bool) -> FrameDetections {
        var placed = frame
        placed.camera = camera
        placed.orientation = orientation
        placed.trackingLimited = trackingLimited
        guard !trackingLimited else { return placed }

        for index in placed.objects.indices {
            let box = placed.objects[index].box
            placed.raycastsFired += 1

            // 1. Raycasts onto real geometry, where there is any. Five rays
            //    rather than one, because the one through the centre of a
            //    chair goes through the gap in its back and lands on the wall;
            //    the engine then picks the hit worth believing. On a device
            //    without LiDAR a ray only lands where ARKit has estimated a
            //    plane or detected one — pointed at a desk from close range,
            //    that is often nowhere.
            var hits: [SIMD3<Float>] = []
            for point in AssetTrackingEngine.raycastPoints(forVisionBox: box, orientation: orientation) {
                // The ray is built from the pose of the frame the detection came
                // from, not from wherever the camera is now, so a pan during
                // analysis does not drag the pin with it.
                let ray = camera.ray(through: point)
                for target in [ARRaycastQuery.Target.estimatedPlane, .existingPlaneGeometry] {
                    let query = ARRaycastQuery(origin: ray.origin,
                                               direction: ray.direction,
                                               allowing: target,
                                               alignment: .any)
                    guard let result = session.raycast(query).first else { continue }
                    let t = result.worldTransform.columns.3
                    hits.append(SIMD3<Float>(t.x, t.y, t.z))
                    break
                }
            }
            let distances = hits.map { simd_distance($0, camera.position) }
            if let chosen = AssetTrackingEngine.representativeIndex(ofDistances: distances) {
                placed.objects[index].worldPosition = hits[chosen]
                placed.raycastsHit += 1
                continue
            }

            // 2. Otherwise the feature points inside the detection's box. They
            //    exist wherever there is visible texture, which is most of a
            //    room and nearly all of the hardware worth onboarding.
            let rect = AssetTrackingEngine.imageRect(forVisionBox: box, orientation: orientation)
            guard let position = AssetTrackingEngine.position(forImageRect: rect,
                                                              featurePoints: features,
                                                              camera: camera)
            else { continue }
            placed.objects[index].worldPosition = position
            placed.featurePlacements += 1
        }
        return placed
    }

    /// Copies a frame's image so the frame itself can be released at once.
    ///
    /// ARKit's buffers are bi-planar YUV; both planes are copied row by row
    /// because the source stride is not necessarily the destination's.
    nonisolated private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)

        var destination: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, format, attributes, &destination) == kCVReturnSuccess,
              let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planes = max(CVPixelBufferGetPlaneCount(source), 1)
        for plane in 0..<planes {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let into = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            else { return nil }
            let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let intoStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let bytes = min(fromStride, intoStride)
            for row in 0..<rows {
                memcpy(into.advanced(by: row * intoStride),
                       from.advanced(by: row * fromStride),
                       bytes)
            }
        }
        return destination
    }

    private func noteTracking(_ tracking: ARCamera.TrackingState) {
        let limited: Bool
        if case .normal = tracking { limited = false } else { limited = true }
        if limited != trackingLimited { trackingLimited = limited }

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
                                    knownAssets: relocalization == .located ? knownAssets : [])
        diagnostics.record(frame, counts: engine.counts, relocalization: relocalization)
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
    /// How the device was held when the pass was claimed. Read once, so Vision
    /// and placement agree even if the interface rotates mid-pass.
    let orientation: SweepOrientation
    /// Identifies this claim, so a pass declared stuck and superseded cannot
    /// release the slot its successor now holds.
    let token: Int
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

    /// How long a pass may hold the slot before it is assumed dead.
    ///
    /// Belt and braces: forgetting to release once cost a whole sweep, and the
    /// symptom — a viewfinder that looks alive but analyses nothing — gives no
    /// hint of the cause.
    private let stuckTimeout: TimeInterval = 5

    private let lock = NSLock()
    private var busy = false
    private var claimedAt = Date.distantPast
    private var currentToken = 0
    private var lastObjectPass = Date.distantPast
    private var lastTextPass = Date.distantPast
    private var heldOrientation: SweepOrientation = .portrait
    private var cloud = FeatureCloud()

    /// How the device is held. Read on the analysis queue, written from the
    /// main actor when the interface rotates.
    var orientation: SweepOrientation {
        get { lock.withLock { heldOrientation } }
        set { lock.withLock { heldOrientation = newValue } }
    }

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

    // MARK: Feature cloud

    func accumulate(points: [SIMD3<Float>], identifiers: [UInt64], at now: Date) {
        lock.withLock { cloud.add(points: points, identifiers: identifiers, at: now) }
    }

    /// A snapshot of the recent cloud, for one placement pass.
    func featurePoints(at now: Date) -> [SIMD3<Float>] {
        lock.withLock { cloud.points(at: now) }
    }

    // MARK: Slot

    /// Claims the analysis slot when a pass is due, describing what to run.
    ///
    /// Returns nil while one is already in flight, so a device slower than the
    /// interval backs off on its own rather than queueing work it can never
    /// catch up on.
    func claim(now: Date) -> AnalysisJob? {
        lock.withLock {
            if busy, now.timeIntervalSince(claimedAt) > stuckTimeout { busy = false }
            guard !busy, now.timeIntervalSince(lastObjectPass) >= objectInterval else { return nil }
            busy = true
            claimedAt = now
            currentToken += 1
            let includesText = now.timeIntervalSince(lastTextPass) >= textInterval
            if includesText { lastTextPass = now }
            return AnalysisJob(includesText: includesText,
                               orientation: heldOrientation,
                               token: currentToken)
        }
    }

    /// Frees the slot, timing the next pass from when this one *ended*.
    ///
    /// A pass that was written off as stuck and then finishes after all must
    /// not free a slot that now belongs to its successor.
    func release(_ job: AnalysisJob, finishedAt: Date) {
        lock.withLock {
            guard job.token == currentToken else { return }
            busy = false
            lastObjectPass = finishedAt
        }
    }

    // MARK: Vision

    /// Runs the due passes on one frame and returns plain values.
    ///
    /// Vision's observation types are classes and not Sendable, so none of them
    /// cross back to the main actor — only the structs built here do.
    func analyse(_ buffer: CVPixelBuffer, job: AnalysisJob) -> FrameDetections {
        var result = FrameDetections()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer,
                                            orientation: job.orientation.exif,
                                            options: [:])

        var requests: [VNRequest] = []
        if let objectRequest { requests.append(objectRequest) }
        if job.includesText {
            requests.append(textRequest)
            requests.append(barcodeRequest)
        }
        guard !requests.isEmpty else { return result }
        try? handler.perform(requests)

        if let observations = objectRequest?.results as? [VNRecognizedObjectObservation] {
            var objects: [ObjectDetection] = []
            for observation in observations {
                guard let top = observation.labels.first,
                      Double(top.confidence) >= threshold else { continue }
                if COCOAssetCatalog.personClasses.contains(top.identifier.lowercased()) {
                    result.people += 1
                    continue
                }
                // Only electrical equipment is inventoried. A chair or a
                // bottle is dropped here, before it can open a track or
                // draw a box.
                guard COCOAssetCatalog.isElectrical(top.identifier) else { continue }
                let name = COCOAssetCatalog.displayName(for: top.identifier)
                // Runner-up classes nearly as likely as the winner ride along.
                // A desk monitor is "tv" in one frame and "laptop" in the next;
                // the engine uses these to see that as one object, not two.
                // Labels arrive strongest first, so the first three electrical
                // ones above the bar are the ones worth carrying.
                var alternates: [String] = []
                for label in observation.labels.dropFirst()
                where Double(label.confidence) >= 0.4 * Double(top.confidence) {
                    guard COCOAssetCatalog.isElectrical(label.identifier) else { continue }
                    let other = COCOAssetCatalog.displayName(for: label.identifier)
                    if other != name, !alternates.contains(other) { alternates.append(other) }
                    if alternates.count == 3 { break }
                }
                objects.append(ObjectDetection(
                    label: name,
                    category: COCOAssetCatalog.category(for: top.identifier) ?? .other,
                    confidence: Double(top.confidence),
                    box: observation.boundingBox,
                    alternateLabels: alternates))
            }
            // The model suppresses duplicate boxes within a class, not across
            // classes: one screen can come back as both "tv" and "laptop".
            result.objects = AssetTrackingEngine.suppressDuplicates(objects)
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

// MARK: - Diagnostics

/// Counters printed periodically while a sweep runs.
///
/// Debug builds only: this exists to make a device console answer "where did it
/// stop?" without a debugger attached.
@MainActor
struct SweepDiagnostics {
    var framesReceived = 0
    /// Frames ARKit delivered while unable to vouch for the pose.
    var limitedFrames = 0
    private var passes = 0
    private var objects = 0
    private var texts = 0
    private var barcodes = 0
    private var raycastsFired = 0
    private var raycastsHit = 0
    private var featurePlacements = 0
    private var limitedPasses = 0
    private var lastReport = Date.distantPast
    private var labels: [String: Int] = [:]

    mutating func begin(hasDetector: Bool, knownAssets: Int, relocalising: Bool) {
        Self.startLog()
        report("sweep start · detector=\(hasDetector ? "yes" : "NONE") "
               + "· known=\(knownAssets) · relocalising=\(relocalising)")
        lastReport = Date()
    }

    mutating func record(_ frame: FrameDetections,
                         counts: (confirmed: Int, tracked: Int, known: Int, unplaced: Int),
                         relocalization: RoomVideoSweeper.Relocalization) {
        passes += 1
        objects += frame.objects.count
        texts += frame.texts.count
        barcodes += frame.barcodes.count
        raycastsFired += frame.raycastsFired
        raycastsHit += frame.raycastsHit
        featurePlacements += frame.featurePlacements
        if frame.trackingLimited { limitedPasses += 1 }
        for object in frame.objects { labels[object.label, default: 0] += 1 }

        guard Date().timeIntervalSince(lastReport) >= 2 else { return }
        lastReport = Date()
        let top = labels.sorted { $0.value > $1.value }.prefix(4)
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        report("frames=\(framesReceived) passes=\(passes) objects=\(objects) "
               + "text=\(texts) codes=\(barcodes) "
               + "raycast=\(raycastsHit)/\(raycastsFired) features=\(featurePlacements) "
               + "limited=\(limitedFrames)f/\(limitedPasses)p "
               + "tracks=\(counts.tracked) confirmed=\(counts.confirmed) unplaced=\(counts.unplaced) "
               + "reloc=\(relocalization) \(top.isEmpty ? "" : "· " + top)")
    }

    private func report(_ message: String) {
        #if DEBUG
        let line = "[sweep] \(message)"
        print(line)
        // Also kept on disk: a device console only shows what was streaming at
        // the time, and the interesting part of a sweep happens while nobody is
        // watching a terminal. Pull it with Tools/pull-sweep-log.sh.
        SweepDiagnostics.append(line)
        #endif
    }

    /// Where the sweep log lands inside the app container.
    static var logURL: URL {
        URL.documentsDirectory.appendingPathComponent("sweep-log.txt")
    }

    static func startLog() {
        #if DEBUG
        try? "sweep log \(Date().formatted(date: .abbreviated, time: .standard))\n"
            .write(to: logURL, atomically: true, encoding: .utf8)
        #endif
    }

    private static func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
