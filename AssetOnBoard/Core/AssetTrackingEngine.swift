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
//  Two kinds of evidence, strongest first:
//
//    1. A world position. Two detections within half a metre wearing the same
//       label are the same object however the box moved, which is what lets the
//       camera look away from a desk and back without counting it twice.
//    2. Box overlap. The fallback for anything the raycast could not place on
//       real geometry, and all there was before ARKit.
//

import Foundation
import CoreGraphics
import simd

/// The tracking core: frames in, one entry per physical object out.
nonisolated struct AssetTrackingEngine {

    /// Overlap needed to call a detection the same object as an existing track.
    static let matchIoU: CGFloat = 0.3
    /// How long a track stays open for re-matching after it was last seen.
    static let trackTimeout: TimeInterval = 2.5
    /// An unconfirmed track this stale was a flicker. Dropping it keeps the
    /// matching loop short over a long sweep.
    static let noiseTimeout: TimeInterval = 5

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

    func overlayBoxes(visible: Set<UUID>) -> [OverlayBox] {
        tracks.compactMap { track in
            guard visible.contains(track.id) else { return nil }
            return OverlayBox(id: track.id,
                              label: track.knownAssetID == nil
                                  ? track.label : "\u{2713} \(track.label)",
                              box: track.box,
                              isRelevant: track.category.isInventoryRelevant,
                              isKnown: track.knownAssetID != nil)
        }
    }

    /// Converts a Vision box to the normalized point ARKit wants for a raycast.
    ///
    /// Two conventions differ at once. Vision reports an upright, portrait-
    /// oriented box with a bottom-left origin, because it was handed the frame
    /// with an orientation. ARKit wants a point in the *captured* image, which
    /// is landscape with a top-left origin. Going from one to the other undoes
    /// the 90-degree clockwise rotation that makes the stored frame look upright.
    static func imagePoint(forVisionBox box: CGRect) -> CGPoint {
        // Upright, top-left origin.
        let upright = CGPoint(x: box.midX, y: 1 - box.midY)
        // Undo the display rotation: stored.x = upright.y, stored.y = 1 - upright.x
        return CGPoint(x: upright.y, y: 1 - upright.x)
    }

    /// Folds one analysed frame in, returning the tracks it actually saw.
    mutating func absorb(_ frame: FrameDetections,
                         knownAssets: [SpatialAsset] = [],
                         at now: Date = Date()) -> Set<UUID> {
        var seenThisFrame: Set<UUID> = []

        for detection in frame.objects {
            if let index = matchIndex(for: detection, now: now) {
                tracks[index].record(detection, at: now)
                seenThisFrame.insert(tracks[index].id)
            } else {
                let track = AssetTrack(detection: detection, at: now)
                seenThisFrame.insert(track.id)
                tracks.append(track)
            }
        }

        // Text and barcodes attach to whichever object encloses them, exactly as
        // they do for a still photograph.
        for item in frame.texts {
            guard let index = enclosingTrackIndex(for: item.box, among: seenThisFrame) else { continue }
            tracks[index].text.insert(item.value)
        }
        for item in frame.barcodes {
            if let index = tracks.firstIndex(where: { $0.barcodes.contains(item.value) }) {
                // A tag already seen identifies its track outright, wherever the
                // camera has wandered since.
                tracks[index].lastSeen = now
                tracks[index].sightings += 1
                seenThisFrame.insert(tracks[index].id)
            } else if let index = enclosingTrackIndex(for: item.box, among: seenThisFrame) {
                tracks[index].barcodes.insert(item.value)
            } else {
                // A tag on a wall with nothing recognised around it is still an
                // asset, and often the only identifier in the room.
                let track = AssetTrack(barcode: item.value, box: item.box, at: now)
                seenThisFrame.insert(track.id)
                tracks.append(track)
            }
        }

        tracks.removeAll { !$0.isConfirmed && now.timeIntervalSince($0.lastSeen) > Self.noiseTimeout }
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

    /// The track this detection continues, if any.
    ///
    /// A world position is the better evidence when both sides have one: it is
    /// the same object in the same place, whatever the box did, which is what
    /// finally fixes panning away from a desk and back creating a second track.
    /// Overlap is the fallback for anything the raycast could not place.
    private func matchIndex(for detection: ObjectDetection, now: Date) -> Int? {
        if let position = detection.worldPosition {
            var nearest: (index: Int, distance: Float)?
            for index in tracks.indices where tracks[index].label == detection.label {
                guard let existing = tracks[index].worldPosition else { continue }
                let gap = RoomSpatialIndex.distance(existing, position)
                guard gap <= RoomSpatialIndex.defaultRadius else { continue }
                if nearest == nil || gap < nearest!.distance { nearest = (index, gap) }
            }
            if let nearest { return nearest.index }
        }

        var best: (index: Int, overlap: CGFloat)?
        for index in tracks.indices {
            // Cheapest rejections first: over a long sweep most tracks are stale
            // or the wrong class, and neither test touches geometry.
            guard now.timeIntervalSince(tracks[index].lastSeen) <= Self.trackTimeout,
                  tracks[index].label == detection.label
            else { continue }
            let overlap = intersectionOverUnion(tracks[index].box, detection.box)
            guard overlap >= Self.matchIoU else { continue }
            if best == nil || overlap > best!.overlap { best = (index, overlap) }
        }
        return best?.index
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

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.area > 0 else { return 0 }
        let union = lhs.area + rhs.area - intersection.area
        return union > 0 ? intersection.area / union : 0
    }}

// MARK: - Values

nonisolated struct ObjectDetection: Sendable {
    let label: String
    let category: AssetCategory
    let confidence: Double
    let box: CGRect
    /// Where the raycast put it, when it found a surface at all.
    var worldPosition: SIMD3<Float>?
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
}

/// One box on the viewfinder. Equatable so an unchanged overlay redraws nothing.
nonisolated struct OverlayBox: Sendable, Equatable, Identifiable {
    let id: UUID
    let label: String
    let box: CGRect
    let isRelevant: Bool
    /// Already on the room's register, so it is shown but not onboarded again.
    var isKnown = false
}

/// One object followed across frames.
nonisolated struct AssetTrack: Identifiable, Sendable {
    let id = UUID()
    var label: String
    var category: AssetCategory
    var bestConfidence: Double
    /// Most recent box, which is what the next frame is matched against.
    var box: CGRect
    var sightings = 1
    var text: Set<String> = []
    var barcodes: Set<String> = []
    var firstSeen: Date
    var lastSeen: Date
    /// Where this object is in the room, once a raycast has placed it.
    ///
    /// Averaged over sightings: a single raycast can land on an edge or slip
    /// past onto the wall behind, and the mean of a dozen is far steadier than
    /// any one of them.
    var worldPosition: SIMD3<Float>?
    private var positionSamples = 0
    /// Set when this turns out to be something the room already had.
    var knownAssetID: UUID?
    var knownReason: String?

    init(detection: ObjectDetection, at time: Date) {
        label = detection.label
        category = detection.category
        bestConfidence = detection.confidence
        box = detection.box
        firstSeen = time
        lastSeen = time
        add(position: detection.worldPosition)
    }

    init(barcode: String, box: CGRect, at time: Date) {
        label = "Asset tag"
        category = .other
        bestConfidence = 0.9
        self.box = box
        barcodes = [barcode]
        firstSeen = time
        lastSeen = time
    }

    mutating func record(_ detection: ObjectDetection, at time: Date) {
        bestConfidence = max(bestConfidence, detection.confidence)
        box = detection.box
        sightings += 1
        lastSeen = time
        add(position: detection.worldPosition)
    }

    /// Folds a new raycast into the running mean.
    mutating func add(position: SIMD3<Float>?) {
        guard let position else { return }
        guard let current = worldPosition else {
            worldPosition = position
            positionSamples = 1
            return
        }
        positionSamples += 1
        let n = Float(positionSamples)
        worldPosition = current + (position - current) / n
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

