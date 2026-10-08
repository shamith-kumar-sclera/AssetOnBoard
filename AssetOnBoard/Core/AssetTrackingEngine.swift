//
//  AssetTrackingEngine.swift
//  AssetOnBoard
//
//  Deciding which detections are the same object.
//
//  Split out of RoomVideoSweeper for one reason: this is the part that can be
//  wrong in ways nobody notices. A bad merge silently drops a device from the
//  register; a bad split onboards it twice. The sweeper around it needs ARKit,
//  a camera and a Metal view, none of which exist in a test — this needs none
//  of them, so it can be exercised directly.
//
//  The question it answers, for every detection in every frame, is "which
//  object already being followed is this?" — and the evidence is ranked by how
//  much it can be trusted on a phone without LiDAR, where a world position is
//  a bearing the camera is sure of plus a depth it mostly guessed:
//
//    1. A shared barcode. An asset tag is an identity.
//    2. Where a pinned object *would appear in this frame*. Projecting a pin
//       back into the picture is insensitive to depth error, which is the
//       dominant error here: a laptop placed a metre too deep still projects
//       onto the laptop. A depth-plausibility gate keeps two screens in line
//       with each other apart.
//    3. Distance between two world positions, for sightings taken from the
//       same side of the room where the guess is consistent.
//    4. Where an *unpinned* object was last seen, from the camera it was seen
//       with — so an object the camera could never place is still recognised
//       when the camera comes back to the same spot, and reclaimed as soon as
//       a placement finally lands where its box was.
//    5. Box overlap between consecutive frames, the fallback for everything
//       else, and only while the camera has not turned away.
//
//  Two rules protect the opposite error. A track is claimed by at most one
//  detection per frame, so two monitors side by side cannot both feed one
//  track; and two objects seen apart in a single frame are recorded as
//  distinct, so no later placement noise can fuse them.
//

import Foundation
import CoreGraphics
import ImageIO
import simd

/// How the device is being held.
///
/// This matters twice over, and getting it wrong breaks both halves of a sweep.
/// ARKit hands over the camera's own landscape frame and never rotates it —
/// unlike an AVCaptureConnection, which can be asked to. Pass that to Vision
/// unrotated while the phone is upright and every object in it is lying on its
/// side, so the detector finds nothing. Then, because Vision reports boxes in
/// whatever frame it was given, the same mistake aims each raycast at the wrong
/// part of the room.
nonisolated enum SweepOrientation: String, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// What Vision needs to see the captured frame the right way up.
    var exif: CGImagePropertyOrientation {
        switch self {
        case .portrait: .right
        case .portraitUpsideDown: .left
        case .landscapeLeft: .down
        case .landscapeRight: .up
        }
    }

    /// True when the upright image is taller than it is wide.
    var isPortrait: Bool { self == .portrait || self == .portraitUpsideDown }

    /// A point in the captured landscape frame, as the user sees it.
    ///
    /// Both sides use a top-left origin; only the rotation differs.
    func upright(fromCaptured point: CGPoint) -> CGPoint {
        switch self {
        case .portrait: CGPoint(x: 1 - point.y, y: point.x)
        case .portraitUpsideDown: CGPoint(x: point.y, y: 1 - point.x)
        case .landscapeLeft: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .landscapeRight: point
        }
    }

    /// The inverse: back from what the user sees to what ARKit captured.
    func captured(fromUpright point: CGPoint) -> CGPoint {
        switch self {
        case .portrait: CGPoint(x: point.y, y: 1 - point.x)
        case .portraitUpsideDown: CGPoint(x: 1 - point.y, y: point.x)
        case .landscapeLeft: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .landscapeRight: point
        }
    }

    /// A captured-frame point in Vision's space: upright, origin bottom-left.
    func visionPoint(fromCaptured point: CGPoint) -> CGPoint {
        let up = upright(fromCaptured: point)
        return CGPoint(x: up.x, y: 1 - up.y)
    }
}

/// What a raycast needs from the frame a detection came from.
///
/// An ARFrame may not be held: it carries a buffer from a small pool, and
/// keeping one across an async hop starves the capture pipeline until the
/// camera stalls. These are plain values, so they can be carried anywhere.
nonisolated struct CameraSnapshot: Sendable {
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    /// Pixel dimensions the intrinsics are expressed in.
    let resolution: CGSize

    /// Where the camera is.
    var position: SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// The direction the camera looks: its own -Z, in the world.
    var forward: SIMD3<Float> {
        simd_normalize(-SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
    }

    /// How far in front of the camera a world point is, nil when behind it.
    func depth(of world: SIMD3<Float>) -> Float? {
        let inCamera = simd_inverse(transform) * SIMD4<Float>(world, 1)
        guard inCamera.z < 0 else { return nil }
        return -inCamera.z
    }

    /// Where a world point lands in the captured image, normalized.
    ///
    /// The exact inverse of `ray(through:)`. Needed because a phone without
    /// LiDAR has no mesh to raycast against, so the fallback is to ask which of
    /// ARKit's feature points fall inside a detection's box — which means
    /// projecting them.
    ///
    /// Returns nil for anything behind the camera, which would otherwise
    /// project to a perfectly plausible-looking point in front of it, and for
    /// anything so nearly beside it that the projection is meaningless.
    func project(_ world: SIMD3<Float>) -> CGPoint? {
        let inCamera = simd_inverse(transform) * SIMD4<Float>(world, 1)
        guard inCamera.z < -0.05 else { return nil }

        let depth = -inCamera.z
        let focal = SIMD2<Float>(intrinsics.columns.0.x, intrinsics.columns.1.y)
        let principal = SIMD2<Float>(intrinsics.columns.2.x, intrinsics.columns.2.y)
        let pixel = SIMD2<Float>(inCamera.x / depth, inCamera.y / inCamera.z) * focal + principal

        return CGPoint(x: CGFloat(pixel.x) / resolution.width,
                       y: CGFloat(pixel.y) / resolution.height)
    }

    /// The world-space ray through a point in the captured image.
    ///
    /// Reproduces what `ARFrame.raycastQuery` would have done, from values that
    /// outlive the frame. ARKit's camera looks down its own -Z with +Y up,
    /// while image coordinates run +Y down from the top-left, so the direction
    /// is flipped in both before being rotated into the world.
    func ray(through point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let pixel = SIMD2<Float>(Float(point.x) * Float(resolution.width),
                                 Float(point.y) * Float(resolution.height))
        let focal = SIMD2<Float>(intrinsics.columns.0.x, intrinsics.columns.1.y)
        let principal = SIMD2<Float>(intrinsics.columns.2.x, intrinsics.columns.2.y)
        let normalized = (pixel - principal) / focal

        let inCamera = simd_normalize(SIMD3<Float>(normalized.x, -normalized.y, -1))
        let rotated = transform * SIMD4<Float>(inCamera, 0)
        let origin = transform.columns.3
        return (SIMD3<Float>(origin.x, origin.y, origin.z),
                simd_normalize(SIMD3<Float>(rotated.x, rotated.y, rotated.z)))
    }

    /// The angle between two cameras' viewing directions, in radians.
    func rotation(since other: CameraSnapshot) -> Float {
        let cosine = simd_clamp(simd_dot(forward, other.forward), -1, 1)
        return acos(cosine)
    }
}

/// The tracking core: frames in, one entry per physical object out.
nonisolated struct AssetTrackingEngine {

    /// Overlap needed to call a detection the same object as an existing track.
    static let matchIoU: CGFloat = 0.3
    /// Overlap at which a detection of a *confusable* class — a "laptop" where
    /// a "tv" was a moment ago — is the same object rather than a neighbour.
    static let confusableIoU: CGFloat = 0.5

    /// How far apart two sightings may be and still be one object, in-session.
    ///
    /// Deliberately looser than the register's half-metre. That radius compares
    /// two settled positions across sweeps; this one compares a settled position
    /// against a single fresh placement, which on a phone without LiDAR comes
    /// from feature-point depth and carries real error at a few metres. Too
    /// tight and one printer becomes two every time the camera returns to it.
    /// Too loose and neighbouring hardware fuses — which is why neighbours seen
    /// apart in one frame are kept apart by evidence rather than by radius.
    static let sameObjectRadius: Float = 0.75
    /// The radius for a confusable-class match, which has no box evidence.
    static let confusableRadius: Float = 0.35
    /// How long a track stays open for box-overlap matching after it was seen.
    static let trackTimeout: TimeInterval = 2.5
    /// An unconfirmed track this stale was a flicker. Dropping it keeps the
    /// matching loop short over a long sweep.
    static let noiseTimeout: TimeInterval = 5

    /// How far outside a detection's box a pin may project and still be it,
    /// as a fraction of the box's size on each side.
    ///
    /// A pin carries lateral error too — the box centre is not the object's
    /// centre, and a placement off the bezel of a monitor is off by half its
    /// width — so demanding the pin land strictly inside a box that may be
    /// half the object's size throws away the match it exists to make.
    static let reprojectionSlack: CGFloat = 0.35
    /// A pin that projects into a box but is this many times nearer or
    /// farther than the detection's own placement is a different object in
    /// line with it, not the same one with depth error.
    static let depthRatioLimit: Float = 2.0
    /// Box overlap says nothing once the camera has turned this far since the
    /// box was recorded; a different object is simply in that part of the view.
    static let maxRotationForOverlap: Float = 20 * .pi / 180
    /// Nor once the camera has walked this far, for an object whose depth is
    /// unknown: without depth, parallax cannot be predicted.
    static let maxTranslationForBearing: Float = 0.5
    /// Depth assumed for an unpinned object when predicting where its last
    /// sighting should appear after the camera turns.
    static let assumedDepth: Float = 2
    /// How long a re-acquired track is flagged on the overlay.
    static let reacquiredHighlight: TimeInterval = 2.5
    /// Overlap at which two boxes of different classes in one frame are one
    /// object the detector named twice.
    static let duplicateBoxIoU: CGFloat = 0.7

    /// Classes the detector mixes up on one object.
    ///
    /// COCO has no "monitor", so a desk screen comes back as "tv" in one frame
    /// and "laptop" in the next. These are display names, which is what every
    /// detection carries by the time it reaches the engine.
    static let confusionGroups: [Set<String>] = [
        ["Display or TV", "Laptop", "Monitor"],
        ["Mouse", "Remote control", "Phone"],
        ["Chair", "Couch"]
    ]

    static func confusable(_ lhs: String, _ rhs: String) -> Bool {
        lhs != rhs && confusionGroups.contains { $0.contains(lhs) && $0.contains(rhs) }
    }

    private(set) var tracks: [AssetTrack] = []

    var counts: (confirmed: Int, tracked: Int, known: Int, unplaced: Int) {
        var confirmed = 0, known = 0, unplaced = 0
        for track in tracks where track.isConfirmed {
            confirmed += 1
            if track.knownAssetID != nil { known += 1 }
            if track.worldPosition == nil { unplaced += 1 }
        }
        return (confirmed, tracks.count, known, unplaced)
    }

    mutating func reset() { tracks = [] }

    /// Tracks solid enough to put in a register.
    var confirmedAssets: [DetectedAsset] {
        confirmed.map(\.asset)
    }

    /// Only what the room has not seen before, which is what gets onboarded.
    var newAssets: [DetectedAsset] {
        confirmed.filter { $0.knownAssetID == nil }.map(\.asset)
    }

    /// Everything confirmed, in the form the room register consumes.
    var sweptAssets: [SweptAsset] {
        confirmed.map {
            SweptAsset(label: $0.label,
                       category: $0.category,
                       position: $0.worldPosition,
                       barcodes: $0.barcodes.sorted(),
                       recognizedText: $0.text.sorted())
        }
    }

    private var confirmed: [AssetTrack] {
        tracks.filter(\.isConfirmed).sorted { $0.bestConfidence > $1.bestConfidence }
    }

    func overlayBoxes(visible: Set<UUID>, at now: Date = Date()) -> [OverlayBox] {
        tracks.compactMap { track in
            guard visible.contains(track.id) else { return nil }
            return OverlayBox(id: track.id,
                              label: track.knownAssetID == nil
                                  ? track.label : "\u{2713} \(track.label)",
                              box: track.box,
                              isRelevant: track.category.isInventoryRelevant,
                              isKnown: track.knownAssetID != nil,
                              isPinned: track.worldPosition != nil,
                              isReacquired: track.reacquiredAt
                                  .map { now.timeIntervalSince($0) <= Self.reacquiredHighlight } ?? false,
                              sightings: track.sightings)
        }
    }

    // MARK: - Placement helpers

    /// Places a detection from ARKit's feature points.
    ///
    /// The fallback for a device with no LiDAR, where a raycast only lands if
    /// ARKit happens to have estimated a plane there. Feature points exist
    /// wherever there is visible texture, which is most of a room.
    ///
    /// The reference depth is taken from the near third of the points rather
    /// than the middle, and points far from it are dropped. A box around a
    /// monitor also contains points on the wall behind it, and the object is,
    /// by construction, the nearest surface in its own box.
    static func position(forImageRect rect: CGRect,
                         featurePoints: [SIMD3<Float>],
                         camera: CameraSnapshot,
                         minimumPoints: Int = 3) -> SIMD3<Float>? {
        var inside: [(point: SIMD3<Float>, depth: Float)] = []
        let origin = camera.position
        for point in featurePoints {
            guard let projected = camera.project(point), rect.contains(projected) else { continue }
            inside.append((point, simd_distance(point, origin)))
        }
        guard inside.count >= minimumPoints else { return nil }

        inside.sort { $0.depth < $1.depth }
        let reference = inside[(inside.count - 1) / 3].depth
        // Keep the cluster around the reference: anything half a metre beyond
        // it is a different surface that happens to share the box.
        let near = inside.filter { abs($0.depth - reference) <= 0.5 }
        guard !near.isEmpty else { return nil }

        var sum = SIMD3<Float>(repeating: 0)
        for entry in near { sum += entry.point }
        return sum / Float(near.count)
    }

    /// Which of several raycast hits to trust, by distance from the camera.
    ///
    /// Several rays are fired into one box because a single one through the
    /// centre lands on whatever is behind a glossy screen or an open chair
    /// back. The lower median is taken: robust to a stray, and biased towards
    /// the nearer surface, which is the object rather than the wall.
    static func representativeIndex(ofDistances distances: [Float]) -> Int? {
        guard !distances.isEmpty else { return nil }
        let order = distances.indices.sorted { distances[$0] < distances[$1] }
        return order[(order.count - 1) / 2]
    }

    static func representativeDepth(_ distances: [Float]) -> Float? {
        representativeIndex(ofDistances: distances).map { distances[$0] }
    }

    /// The points inside a box worth raycasting through: the centre and four
    /// points well inside each quadrant, in captured-image space.
    static func raycastPoints(forVisionBox box: CGRect,
                              orientation: SweepOrientation) -> [CGPoint] {
        let rect = imageRect(forVisionBox: box, orientation: orientation)
        let dx = rect.width * 0.2, dy = rect.height * 0.2
        return [CGPoint(x: rect.midX, y: rect.midY),
                CGPoint(x: rect.midX - dx, y: rect.midY - dy),
                CGPoint(x: rect.midX + dx, y: rect.midY - dy),
                CGPoint(x: rect.midX - dx, y: rect.midY + dy),
                CGPoint(x: rect.midX + dx, y: rect.midY + dy)]
    }

    /// Collapses boxes the detector drew twice around one object.
    ///
    /// The model suppresses duplicates within a class but not across classes,
    /// so a screen can come back as both "tv" and "laptop" in one frame with
    /// near-identical boxes. The stronger one is kept and remembers the other
    /// name, so later frames that use it still match.
    static func suppressDuplicates(_ detections: [ObjectDetection],
                                   overlap: CGFloat = duplicateBoxIoU) -> [ObjectDetection] {
        var kept: [ObjectDetection] = []
        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            if let index = kept.firstIndex(where: { intersectionOverUnion($0.box, detection.box) >= overlap }) {
                if kept[index].label != detection.label,
                   !kept[index].alternateLabels.contains(detection.label) {
                    kept[index].alternateLabels.append(detection.label)
                }
                for label in detection.alternateLabels
                where label != kept[index].label && !kept[index].alternateLabels.contains(label) {
                    kept[index].alternateLabels.append(label)
                }
                continue
            }
            kept.append(detection)
        }
        return kept
    }

    /// A Vision box as a rectangle in captured-image space.
    ///
    /// Rotating a rect is not rotating its origin and size: the corners move,
    /// so both are mapped and the bounds rebuilt from them.
    static func imageRect(forVisionBox box: CGRect,
                          orientation: SweepOrientation) -> CGRect {
        // Vision's bottom-left origin to an upright top-left rect.
        let upright = CGRect(x: box.minX, y: 1 - box.maxY,
                             width: box.width, height: box.height)
        let corners = [CGPoint(x: upright.minX, y: upright.minY),
                       CGPoint(x: upright.maxX, y: upright.maxY)]
            .map { orientation.captured(fromUpright: $0) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: abs(xs[1] - xs[0]), height: abs(ys[1] - ys[0]))
    }

    /// Converts a Vision box to the normalized point ARKit wants for a raycast.
    ///
    /// Two conventions differ at once. Vision reports an upright box with a
    /// bottom-left origin, because it was handed the frame with an orientation.
    /// ARKit wants a point in the *captured* frame, which is landscape with a
    /// top-left origin. So: flip the origin, then undo the display rotation.
    static func imagePoint(forVisionBox box: CGRect,
                           orientation: SweepOrientation) -> CGPoint {
        let upright = CGPoint(x: box.midX, y: 1 - box.midY)
        return orientation.captured(fromUpright: upright)
    }

    // MARK: - Absorbing a frame

    /// Folds one analysed frame in, returning the tracks it actually saw.
    mutating func absorb(_ frame: FrameDetections,
                         knownAssets: [SpatialAsset] = [],
                         at time: Date? = nil) -> Set<UUID> {
        let now = time ?? frame.timestamp ?? Date()
        var seenThisFrame: Set<UUID> = []

        // Strongest claims first, so a confident box settles which track it
        // owns before a weaker one nearby gets to ask.
        let ordered = frame.objects.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.box.area > $1.box.area
        }
        for detection in ordered {
            if let index = matchIndex(for: detection, now: now, frame: frame, claimed: seenThisFrame) {
                let id = tracks[index].id
                tracks[index].record(detection, in: frame, at: now,
                                     countSighting: !seenThisFrame.contains(id))
                seenThisFrame.insert(id)
            } else if !frame.trackingLimited {
                // While ARKit is not tracking, a pose is not to be trusted and
                // a box is not to be pinned; following what is already known
                // is fine, but nothing new is opened on that evidence.
                let track = AssetTrack(detection: detection, in: frame, at: now)
                seenThisFrame.insert(track.id)
                tracks.append(track)
            }
        }

        // Two boxes in one frame that do not overlap are two objects. That is
        // the one piece of evidence placement noise can never fake, so it is
        // written down and outranks geometry from here on.
        let seenIndices = tracks.indices.filter { seenThisFrame.contains(tracks[$0].id) }
        for (n, lhs) in seenIndices.enumerated() {
            for rhs in seenIndices.dropFirst(n + 1)
            where Self.intersectionOverUnion(tracks[lhs].box, tracks[rhs].box) < Self.matchIoU {
                tracks[lhs].distinctFrom.insert(tracks[rhs].id)
                tracks[rhs].distinctFrom.insert(tracks[lhs].id)
            }
        }

        // Text and barcodes attach to whichever object encloses them, exactly as
        // they do for a still photograph.
        for item in frame.texts {
            guard let index = enclosingTrackIndex(for: item.box, among: seenThisFrame) else { continue }
            tracks[index].text.insert(item.value)
        }
        for item in frame.barcodes {
            if let index = enclosingTrackIndex(for: item.box, among: seenThisFrame) {
                // Whatever object the tag is printed on gets the tag, even if
                // another track already carries it. That is the point: two
                // tracks wearing one tag are one asset, and `coalesce` then
                // collapses them. Refreshing the older track instead would
                // leave the duplicate standing with no way back.
                tracks[index].barcodes.insert(item.value)
            } else if let index = tracks.firstIndex(where: { $0.barcodes.contains(item.value) }) {
                // No object recognised around it this time, but the tag itself
                // identifies a track the camera has seen before.
                tracks[index].lastSeen = now
                tracks[index].sightings += 1
                seenThisFrame.insert(tracks[index].id)
            } else {
                // A tag on a wall with nothing recognised around it is still an
                // asset, and often the only identifier in the room.
                let track = AssetTrack(barcode: item.value, box: item.box, at: now)
                seenThisFrame.insert(track.id)
                tracks.append(track)
            }
        }

        tracks.removeAll { !$0.isConfirmed && now.timeIntervalSince($0.lastSeen) > Self.noiseTimeout }
        let merged = coalesce()
        if !merged.isEmpty {
            // What was seen this frame may now live on under another id.
            seenThisFrame = Set(seenThisFrame.map { id in
                var survivor = id
                while let next = merged[survivor] { survivor = next }
                return survivor
            })
        }
        reconcile(with: knownAssets)
        return seenThisFrame
    }

    /// Marks tracks that turn out to be assets the room already had.
    ///
    /// Only meaningful once the session has relocalised: before that the
    /// positions are in a fresh coordinate frame that has nothing to do with
    /// the one the register was written in, and matching against it would pair
    /// assets by coincidence.
    private mutating func reconcile(with knownAssets: [SpatialAsset]) {
        guard !knownAssets.isEmpty else { return }
        for index in tracks.indices where tracks[index].knownAssetID == nil {
            guard tracks[index].isConfirmed else { continue }
            let match = RoomSpatialIndex.match(label: tracks[index].label,
                                               position: tracks[index].worldPosition,
                                               barcodes: Array(tracks[index].barcodes),
                                               against: knownAssets)
            guard case .known(let id, let reason) = match else { continue }
            tracks[index].knownAssetID = id
            tracks[index].knownReason = reason
        }
    }

    // MARK: - Merging tracks

    /// Collapses tracks that have turned out to be the same object.
    ///
    /// Matching at the moment a detection arrives cannot be enough on its own.
    /// A detection the camera could not place has no position to compare, and an
    /// early position built from one noisy sample can sit further from the truth
    /// than the matching radius — so two tracks get opened for one printer, and
    /// nothing in the old design ever took them back.
    ///
    /// Both problems cure themselves as sightings accumulate: positions converge
    /// on the real object and tags get read. This is the pass that goes back and
    /// acts on that, so revisiting a desk mid-sweep stops inflating the count.
    ///
    /// Runs until nothing more merges, because collapsing A into B can bring B
    /// within reach of C. Returns which ids were folded into which.
    private mutating func coalesce() -> [UUID: UUID] {
        var merged: [UUID: UUID] = [:]
        var didMerge = true
        while didMerge {
            didMerge = false
            search: for lhs in tracks.indices {
                for rhs in (lhs + 1)..<tracks.count {
                    guard shouldMerge(tracks[lhs], tracks[rhs]) else { continue }
                    let gone = tracks[rhs].id, survivor = tracks[lhs].id
                    tracks[lhs].absorb(tracks[rhs])
                    tracks.remove(at: rhs)
                    // Evidence that named the vanished track now names the
                    // survivor, so "seen apart from X" is not lost in a merge.
                    for index in tracks.indices where tracks[index].distinctFrom.contains(gone) {
                        tracks[index].distinctFrom.remove(gone)
                        if tracks[index].id != survivor { tracks[index].distinctFrom.insert(survivor) }
                    }
                    merged[gone] = survivor
                    didMerge = true
                    break search
                }
            }
        }
        return merged
    }

    /// Whether two tracks describe one object.
    ///
    /// Deliberately the same evidence the register uses across sweeps: a shared
    /// asset tag is identity outright, and otherwise it takes the same label in
    /// the same place. Two laptops seen side by side in one frame stay two
    /// whatever their positions do afterwards.
    private func shouldMerge(_ lhs: AssetTrack, _ rhs: AssetTrack) -> Bool {
        if !lhs.barcodes.isEmpty, !lhs.barcodes.isDisjoint(with: rhs.barcodes) { return true }
        // Seen apart in one frame: two objects, however alike. This outranks a
        // shared model number because a dual-monitor desk is two of one model.
        if lhs.distinctFrom.contains(rhs.id) || rhs.distinctFrom.contains(lhs.id) { return false }
        // A model number read off two tracks is the same claim a barcode makes,
        // a little weaker. Only identifier-shaped strings count: "Dell" appears
        // on every monitor in the building, "P2419H" on one.
        if !Self.identifiers(in: lhs.text).isDisjoint(with: Self.identifiers(in: rhs.text)) {
            return true
        }

        guard let relation = Self.labelRelation(lhs, rhs) else { return false }
        let radius = relation == .exact ? Self.sameObjectRadius : Self.confusableRadius
        let slack = relation == .exact ? Self.reprojectionSlack : 0

        switch (lhs.worldPosition, rhs.worldPosition) {
        case (.some, .some):
            guard let gap = lhs.estimate.distance(to: rhs.estimate) else { return false }
            return gap <= radius
        case (.some(let position), nil):
            // One placed, one not: ask whether the placed one would have
            // appeared in the other's last box, from the camera that saw it.
            return rhs.contains(worldPoint: position, slack: slack)
        case (nil, .some(let position)):
            return lhs.contains(worldPoint: position, slack: slack)
        default:
            return false
        }
    }

    /// Text specific enough to identify one unit rather than a product line.
    ///
    /// The same test `DetectedAsset.likelyModelString` already trusts — letters
    /// and digits together, long enough not to be a word — plus two of its own:
    /// at least two digits and no spaces, because "CORE i7" and "Windows 11" are
    /// printed on every laptop in the building and "M404dn" on one printer.
    private static func identifiers(in text: Set<String>) -> Set<String> {
        Set(text.filter { candidate in
            candidate.count >= 5 && candidate.count <= 32
                && candidate.contains(where: \.isLetter)
                && candidate.filter(\.isNumber).count >= 2
                && !candidate.contains(where: \.isWhitespace)
        })
    }

    // MARK: - Matching a detection

    /// How a detection's class relates to a track's.
    enum LabelRelation: Equatable {
        /// The track has worn this very label before.
        case exact
        /// A class the detector is known to confuse with the track's.
        case confusable
    }

    private static func labelRelation(_ detection: ObjectDetection, _ track: AssetTrack) -> LabelRelation? {
        if track.labelCounts[detection.label] != nil { return .exact }
        if detection.alternateLabels.contains(track.label)
            || track.alternates.contains(detection.label)
            || confusable(detection.label, track.label) {
            return .confusable
        }
        return nil
    }

    private static func labelRelation(_ lhs: AssetTrack, _ rhs: AssetTrack) -> LabelRelation? {
        if !Set(lhs.labelCounts.keys).isDisjoint(with: rhs.labelCounts.keys) { return .exact }
        if lhs.alternates.contains(rhs.label) || rhs.alternates.contains(lhs.label)
            || confusable(lhs.label, rhs.label) {
            return .confusable
        }
        return nil
    }

    /// The track this detection continues, if any.
    ///
    /// Evidence is tried strongest first; see the file comment for why this
    /// order. `claimed` holds the tracks a detection earlier in this frame has
    /// already taken: a physical object appears once per frame, so a claimed
    /// track is off limits unless this box lies on top of the one that claimed
    /// it — the detector having drawn the same object twice.
    private func matchIndex(for detection: ObjectDetection,
                            now: Date,
                            frame: FrameDetections,
                            claimed: Set<UUID>) -> Int? {
        let camera = frame.camera
        let position = frame.trackingLimited ? nil : detection.worldPosition
        let detectionDepth = position.flatMap { camera?.depth(of: $0) }

        func eligible(_ index: Int) -> Bool {
            !claimed.contains(tracks[index].id)
                || Self.intersectionOverUnion(tracks[index].box, detection.box) >= Self.matchIoU
        }

        // 1. Where would each pinned object appear in this frame?
        if let camera {
            var best: (index: Int, offset: CGFloat)?
            for index in tracks.indices where eligible(index) {
                guard let relation = Self.labelRelation(detection, tracks[index]),
                      let world = tracks[index].worldPosition,
                      let projected = camera.project(world) else { continue }
                let point = frame.orientation.visionPoint(fromCaptured: projected)
                let slack = relation == .exact ? Self.reprojectionSlack : 0
                guard let offset = Self.offset(of: point, within: detection.box, slack: slack) else { continue }
                // Two screens in line with each other both project into the
                // nearer one's box; only depth tells them apart.
                if let detectionDepth, let trackDepth = camera.depth(of: world) {
                    let ratio = max(detectionDepth, trackDepth) / max(min(detectionDepth, trackDepth), 0.01)
                    guard ratio <= Self.depthRatioLimit else { continue }
                }
                if best == nil || offset < best!.offset { best = (index, offset) }
            }
            if let best { return best.index }
        }

        // 2. A placed detection near a placed track.
        if let position {
            var nearest: (index: Int, distance: Float)?
            for index in tracks.indices where eligible(index)
                && Self.labelRelation(detection, tracks[index]) == .exact {
                guard let gap = tracks[index].estimate.distance(to: position),
                      gap <= Self.sameObjectRadius else { continue }
                if nearest == nil || gap < nearest!.distance { nearest = (index, gap) }
            }
            if let nearest { return nearest.index }
        }

        // 3. A placed detection landing where an unpinned track was last seen,
        //    judged from the camera that saw it. No time limit: the question
        //    is purely geometric, and it is what finally lets an object the
        //    camera could not place be recognised once it can be.
        if let position {
            for index in tracks.indices where eligible(index) && tracks[index].worldPosition == nil {
                guard let relation = Self.labelRelation(detection, tracks[index]) else { continue }
                let slack = relation == .exact ? Self.reprojectionSlack : 0
                if tracks[index].contains(worldPoint: position, slack: slack) { return index }
            }
        }

        // 4. Neither side has a position. If both cameras are known and the
        //    phone has not walked off, turn the last sighting to face this
        //    camera and see whether the boxes line up.
        if let camera {
            var best: (index: Int, overlap: CGFloat)?
            for index in tracks.indices where eligible(index) && tracks[index].worldPosition == nil {
                guard let relation = Self.labelRelation(detection, tracks[index]),
                      let predicted = tracks[index].predictedBox(in: camera, orientation: frame.orientation)
                else { continue }
                let needed = relation == .exact ? Self.matchIoU : Self.confusableIoU
                let overlap = Self.intersectionOverUnion(predicted, detection.box)
                guard overlap >= needed else { continue }
                if best == nil || overlap > best!.overlap { best = (index, overlap) }
            }
            if let best { return best.index }
        }

        // 5. Plain box overlap with a recent sighting. Not excluded for claimed
        //    tracks: a second box the detector drew on one object folds in here.
        var best: (index: Int, overlap: CGFloat)?
        for index in tracks.indices {
            // Cheapest rejections first: over a long sweep most tracks are stale
            // or the wrong class, and neither test touches geometry.
            guard now.timeIntervalSince(tracks[index].lastSeen) <= Self.trackTimeout,
                  let relation = Self.labelRelation(detection, tracks[index])
            else { continue }
            // A box means nothing after the camera has turned away from it.
            if let camera, let last = tracks[index].lastCamera,
               camera.rotation(since: last) > Self.maxRotationForOverlap { continue }
            let needed = relation == .exact ? Self.matchIoU : Self.confusableIoU
            let overlap = Self.intersectionOverUnion(tracks[index].box, detection.box)
            guard overlap >= needed else { continue }
            if best == nil || overlap > best!.overlap { best = (index, overlap) }
        }
        return best?.index
    }

    /// How far a point sits from a box's centre, in units of the box's half
    /// size, or nil when it is outside the box grown by `slack` on each side.
    static func offset(of point: CGPoint, within box: CGRect, slack: CGFloat) -> CGFloat? {
        let halfWidth = box.width / 2, halfHeight = box.height / 2
        guard halfWidth > 0, halfHeight > 0 else { return nil }
        let dx = abs(point.x - box.midX) / halfWidth
        let dy = abs(point.y - box.midY) / halfHeight
        let limit = 1 + 2 * slack
        guard dx <= limit, dy <= limit else { return nil }
        return hypot(dx, dy)
    }

    /// The smallest box containing the centre of `box`, among tracks this frame
    /// actually saw.
    ///
    /// Smallest wins for the same reason it does in a photograph: a label on a
    /// laptop sits inside both the laptop's box and the desk's.
    private func enclosingTrackIndex(for box: CGRect, among visible: Set<UUID>) -> Int? {
        let centre = CGPoint(x: box.midX, y: box.midY)
        return tracks.indices
            .filter { visible.contains(tracks[$0].id) && tracks[$0].box.contains(centre) }
            .min { tracks[$0].box.area < tracks[$1].box.area }
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.area > 0 else { return 0 }
        let union = lhs.area + rhs.area - intersection.area
        return union > 0 ? intersection.area / union : 0
    }
}

// MARK: - Values

nonisolated struct ObjectDetection: Sendable {
    let label: String
    let category: AssetCategory
    let confidence: Double
    let box: CGRect
    /// Where the raycast put it, when it found a surface at all.
    var worldPosition: SIMD3<Float>?
    /// Other classes the detector found nearly as likely for this box, as
    /// display names. A screen is "tv" in one frame and "laptop" in the next;
    /// carrying the runner-up is what lets the next frame recognise it.
    var alternateLabels: [String] = []
}

nonisolated struct BoxedString: Sendable {
    let value: String
    let box: CGRect
}

nonisolated struct FrameDetections: Sendable {
    var objects: [ObjectDetection] = []
    var texts: [BoxedString] = []
    var barcodes: [BoxedString] = []
    var people = 0
    /// How many raycasts were fired for this frame, and how many found a
    /// surface. A sweep that detects plenty but places nothing is a different
    /// problem from one that detects nothing, and the counts tell them apart.
    var raycastsFired = 0
    var raycastsHit = 0
    /// Placed from feature points because no raycast landed.
    var featurePlacements = 0
    /// The pose this frame was taken from, when there was one.
    ///
    /// Carried so a detection the camera could not place can still be matched
    /// against a track that *is* placed, by asking where that track should
    /// appear in this frame — and the other way round.
    var camera: CameraSnapshot?
    var orientation: SweepOrientation = .portrait
    /// True while ARKit reports limited tracking: the pose may be wrong, so
    /// nothing in this frame is pinned and nothing new is opened on it.
    var trackingLimited = false
    /// When the frame was captured, so timeouts run on camera time rather
    /// than on whenever analysis happened to finish.
    var timestamp: Date?
}

/// One box on the viewfinder. Equatable so an unchanged overlay redraws nothing.
nonisolated struct OverlayBox: Sendable, Equatable, Identifiable {
    let id: UUID
    let label: String
    let box: CGRect
    let isRelevant: Bool
    /// Already on the room's register, so it is shown but not onboarded again.
    var isKnown = false
    /// Has a position in the room.
    var isPinned = false
    /// The camera has just come back to this after looking elsewhere, and
    /// recognised it rather than counting it again.
    var isReacquired = false
    var sightings = 1
}

/// Where an object is, built from the placements that agreed with each other.
///
/// A raycast that slips past a laptop lands on the wall behind it, metres
/// away; a plain running mean then sits in mid-air between the two and
/// matches neither. Instead the recent samples are kept and the largest group
/// within the matching radius is believed. When every sample agrees that is
/// just their mean; when one disagrees it is outvoted rather than averaged in;
/// when the early ones were wrong, the later ones take over as they outnumber
/// them. Among equal groups the nearer wins, because a ray through a box hits
/// the object or something behind it, never something in front.
nonisolated struct PositionEstimate: Sendable {
    static let capacity = 16
    static let radius = AssetTrackingEngine.sameObjectRadius

    struct Sample: Sendable {
        let position: SIMD3<Float>
        /// Distance from the camera that produced it, when known.
        let depth: Float?
    }

    private(set) var samples: [Sample] = []
    /// The believed position.
    private(set) var value: SIMD3<Float>?
    /// How many samples agree with it.
    private(set) var support = 0
    /// Every group's centre and size, largest first.
    private(set) var clusters: [(centre: SIMD3<Float>, count: Int)] = []

    mutating func add(_ position: SIMD3<Float>, depth: Float?) {
        samples.append(Sample(position: position, depth: depth))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        recompute()
    }

    mutating func merge(_ other: PositionEstimate) {
        samples.append(contentsOf: other.samples)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        recompute()
    }

    /// Distance from a point to the nearest group worth believing: the main
    /// one, or any that at least two samples agree on.
    func distance(to point: SIMD3<Float>) -> Float? {
        guard value != nil else { return nil }
        var best: Float?
        for (n, cluster) in clusters.enumerated() where n == 0 || cluster.count >= 2 {
            let gap = simd_distance(cluster.centre, point)
            if best == nil || gap < best! { best = gap }
        }
        return best
    }

    func distance(to other: PositionEstimate) -> Float? {
        guard let there = other.value else { return nil }
        return distance(to: there)
    }

    private mutating func recompute() {
        guard !samples.isEmpty else { value = nil; support = 0; clusters = []; return }
        var found: [(centre: SIMD3<Float>, count: Int, depth: Float, newest: Int)] = []
        for (n, sample) in samples.enumerated() {
            var sum = SIMD3<Float>(repeating: 0), count = 0, depth: Float = 0, newest = 0
            for (m, other) in samples.enumerated()
            where simd_distance(sample.position, other.position) <= Self.radius {
                sum += other.position
                count += 1
                depth += other.depth ?? 0
                newest = max(newest, m)
            }
            found.append((sum / Float(count), count, depth / Float(count), max(newest, n)))
        }
        found.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.newest > rhs.newest
        }
        // Collapse the groups that are the same group seen from each member.
        var distinct: [(centre: SIMD3<Float>, count: Int)] = []
        for group in found where !distinct.contains(where: { simd_distance($0.centre, group.centre) < 0.01 }) {
            distinct.append((group.centre, group.count))
        }
        clusters = distinct
        value = distinct.first?.centre
        support = distinct.first?.count ?? 0
    }
}

/// Feature points gathered across frames, so a box has something to be placed
/// against even when this frame's few hundred points missed it.
///
/// ARKit's points are world-space and carry stable identifiers, so the same
/// corner of a keyboard seen in twenty frames is one entry, refreshed. Points
/// not seen for a while are dropped: the cloud is a short memory, not a map.
nonisolated struct FeatureCloud: Sendable {
    private struct Entry {
        var point: SIMD3<Float>
        var seen: Date
    }

    let lifetime: TimeInterval
    let capacity: Int
    private var entries: [UInt64: Entry] = [:]

    init(lifetime: TimeInterval = 3, capacity: Int = 4000) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    var count: Int { entries.count }

    mutating func add(points: [SIMD3<Float>], identifiers: [UInt64], at now: Date) {
        for (n, point) in points.enumerated() {
            let id = n < identifiers.count ? identifiers[n] : UInt64(n) | (1 << 63)
            entries[id] = Entry(point: point, seen: now)
        }
        // Called every frame, so the trim is amortised: let the cloud overrun
        // by a quarter, then drop the stale and the oldest in one go, rather
        // than sorting the whole thing sixty times a second.
        guard entries.count > capacity + capacity / 4 else { return }
        entries = entries.filter { now.timeIntervalSince($0.value.seen) <= lifetime }
        if entries.count > capacity {
            let oldestFirst = entries.sorted { $0.value.seen < $1.value.seen }
            for (id, _) in oldestFirst.prefix(entries.count - capacity) { entries[id] = nil }
        }
    }

    /// Everything still fresh, dropping what is not.
    mutating func points(at now: Date) -> [SIMD3<Float>] {
        entries = entries.filter { now.timeIntervalSince($0.value.seen) <= lifetime }
        return entries.values.map(\.point)
    }

    mutating func removeAll() { entries.removeAll() }
}

/// One object followed across frames.
nonisolated struct AssetTrack: Identifiable, Sendable {
    let id = UUID()
    /// The class most of its sightings wore.
    private(set) var label: String
    private(set) var category: AssetCategory
    /// Every class this object has been reported as, and how often.
    private(set) var labelCounts: [String: Int] = [:]
    private var categories: [String: AssetCategory] = [:]
    /// Runner-up classes the detector offered for it.
    private(set) var alternates: Set<String> = []
    var bestConfidence: Double
    /// Most recent box, which is what the next frame is matched against.
    var box: CGRect
    /// The camera the box was seen with. The pair is what lets a box be
    /// turned to face a later camera, or a later placement be checked against
    /// the box.
    var lastCamera: CameraSnapshot?
    var lastOrientation: SweepOrientation = .portrait
    var sightings = 1
    var text: Set<String> = []
    var barcodes: Set<String> = []
    var firstSeen: Date
    var lastSeen: Date
    /// When the camera last came back to this after looking away.
    var reacquiredAt: Date?
    /// Tracks this one was seen apart from in a single frame: proof of two
    /// objects, which no later placement noise may undo.
    var distinctFrom: Set<UUID> = []
    /// Where this object is in the room, once placements have agreed.
    private(set) var estimate = PositionEstimate()
    var worldPosition: SIMD3<Float>? { estimate.value }
    var positionSamples: Int { estimate.support }
    /// Set when this turns out to be something the room already had.
    var knownAssetID: UUID?
    var knownReason: String?

    init(detection: ObjectDetection, in frame: FrameDetections, at time: Date) {
        label = detection.label
        category = detection.category
        labelCounts = [detection.label: 1]
        categories = [detection.label: detection.category]
        alternates = Set(detection.alternateLabels)
        bestConfidence = detection.confidence
        box = detection.box
        lastCamera = frame.camera
        lastOrientation = frame.orientation
        firstSeen = time
        lastSeen = time
        if !frame.trackingLimited { add(position: detection.worldPosition, from: frame.camera) }
    }

    init(barcode: String, box: CGRect, at time: Date) {
        label = "Asset tag"
        category = .other
        labelCounts = [label: 1]
        categories = [label: .other]
        bestConfidence = 0.9
        self.box = box
        barcodes = [barcode]
        firstSeen = time
        lastSeen = time
    }

    /// Folds a sighting in.
    ///
    /// `countSighting` is false for a second box on the same object in one
    /// frame: the box is refreshed, but one frame is one sighting.
    mutating func record(_ detection: ObjectDetection,
                         in frame: FrameDetections,
                         at time: Date,
                         countSighting: Bool = true) {
        bestConfidence = max(bestConfidence, detection.confidence)
        box = detection.box
        lastCamera = frame.camera
        lastOrientation = frame.orientation
        if countSighting {
            if time.timeIntervalSince(lastSeen) > AssetTrackingEngine.trackTimeout { reacquiredAt = time }
            sightings += 1
        }
        lastSeen = time
        labelCounts[detection.label, default: 0] += 1
        categories[detection.label] = detection.category
        alternates.formUnion(detection.alternateLabels)
        relabel()
        if !frame.trackingLimited { add(position: detection.worldPosition, from: frame.camera) }
    }

    /// Folds a new placement into the estimate.
    mutating func add(position: SIMD3<Float>?, from camera: CameraSnapshot? = nil) {
        guard let position else { return }
        estimate.add(position, depth: camera.map { simd_distance(position, $0.position) })
    }

    /// Names the track after the class most of its sightings wore. Ties keep
    /// the current name, so a label does not flap between two classes.
    private mutating func relabel() {
        guard let best = labelCounts.max(by: { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }), best.value > labelCounts[label, default: 0] else { return }
        label = best.key
        category = categories[best.key] ?? category
    }

    /// Whether a world point would have appeared in this track's last box, as
    /// seen by the camera that recorded it.
    func contains(worldPoint: SIMD3<Float>, slack: CGFloat) -> Bool {
        guard let camera = lastCamera, let projected = camera.project(worldPoint) else { return false }
        let point = lastOrientation.visionPoint(fromCaptured: projected)
        return AssetTrackingEngine.offset(of: point, within: box, slack: slack) != nil
    }

    /// Where the last box would appear to `camera`, assuming the object sits at
    /// a typical depth. Nil when the camera has moved too far for that guess
    /// to mean anything, or the spot has left the view.
    func predictedBox(in camera: CameraSnapshot, orientation: SweepOrientation) -> CGRect? {
        guard let last = lastCamera,
              simd_distance(last.position, camera.position) <= AssetTrackingEngine.maxTranslationForBearing
        else { return nil }
        let ray = last.ray(through: AssetTrackingEngine.imagePoint(forVisionBox: box,
                                                                   orientation: lastOrientation))
        let ahead = ray.origin + ray.direction * AssetTrackingEngine.assumedDepth
        guard let projected = camera.project(ahead) else { return nil }
        let centre = orientation.visionPoint(fromCaptured: projected)
        return CGRect(x: centre.x - box.width / 2, y: centre.y - box.height / 2,
                      width: box.width, height: box.height)
    }

    /// Folds another track for the same object into this one.
    mutating func absorb(_ other: AssetTrack) {
        bestConfidence = max(bestConfidence, other.bestConfidence)
        // Sightings add up: both were looking at the same thing, so the merged
        // track is as well-evidenced as the two separately.
        sightings += other.sightings
        text.formUnion(other.text)
        barcodes.formUnion(other.barcodes)
        firstSeen = min(firstSeen, other.firstSeen)
        if other.lastSeen > lastSeen {
            lastSeen = other.lastSeen
            box = other.box
            lastCamera = other.lastCamera
            lastOrientation = other.lastOrientation
        }
        switch (reacquiredAt, other.reacquiredAt) {
        case let (mine?, theirs?): reacquiredAt = max(mine, theirs)
        case (nil, let theirs?): reacquiredAt = theirs
        default: break
        }
        distinctFrom.formUnion(other.distinctFrom)
        distinctFrom.remove(id)
        distinctFrom.remove(other.id)
        for (name, count) in other.labelCounts { labelCounts[name, default: 0] += count }
        categories.merge(other.categories) { mine, _ in mine }
        alternates.formUnion(other.alternates)
        relabel()
        knownAssetID = knownAssetID ?? other.knownAssetID
        knownReason = knownReason ?? other.knownReason
        estimate.merge(other.estimate)
    }

    /// Whether this is solid enough to carry into the register.
    ///
    /// One frame of a low-confidence box is as likely to be a reflection as a
    /// device. Two sightings, or anything the camera actually *read* off the
    /// object, clears that bar.
    var isConfirmed: Bool {
        sightings >= 2 || !barcodes.isEmpty || !text.isEmpty
    }

    var asset: DetectedAsset {
        var built = DetectedAsset(rawLabel: label,
                                  category: category,
                                  confidence: bestConfidence,
                                  boundingBox: box,
                                  source: barcodes.isEmpty ? .objectDetector : .barcode,
                                  recognizedText: text.sorted(),
                                  barcodes: barcodes.sorted(),
                                  sightings: sightings)
        built.matchReason = knownReason
        return built
    }
}
