//
//  RoomSpatialIndex.swift
//  AssetOnBoard
//
//  Remembers where each asset is, so a second sweep of the same room does not
//  onboard everything a second time.
//
//  The frame-to-frame tracking in RoomVideoSweeper only survives one sweep: a
//  track is matched by where its box was a moment ago, and that evidence is
//  gone the instant the session ends. Walk the same room tomorrow and every
//  printer is new again.
//
//  What persists instead is a position. ARKit builds a map of the room while
//  the sweep runs; each detection is raycast onto real geometry and stored as a
//  point in that map's coordinate frame. Re-running the sweep with the saved
//  map loaded puts the device back in the same frame, so an asset found within
//  half a metre of a stored one, wearing the same label, is that asset — not a
//  new one.
//
//  Deliberately local. ARCore Cloud Anchors solve the same problem by hosting
//  the map on Google's servers, which would mean a third-party SDK, a network
//  round trip and room geometry leaving the device — for an app whose camera
//  permission string promises the opposite. An ARWorldMap is a file; it can
//  still be handed to another device when that is wanted.
//

import Foundation
import simd

/// One asset, pinned to a point in a room.
nonisolated struct SpatialAsset: Identifiable, Codable, Sendable, Hashable {
    var id = UUID()
    /// The detector's class name, kept verbatim so matching is predictable.
    var label: String
    var category: AssetCategory
    /// Metres, in the room map's coordinate frame.
    var position: SIMD3<Float>
    var barcodes: [String] = []
    var recognizedText: [String] = []
    var onboardedAt = Date()
    var lastSeenAt = Date()
    /// How many sweeps have seen it, not how many frames.
    var visits = 1

    /// The strongest identifier this asset carries, for display.
    var tag: String? {
        barcodes.first ?? recognizedText.first { candidate in
            candidate.contains(where: \.isLetter) && candidate.contains(where: \.isNumber)
        }
    }
}

/// One room: the assets pinned in it, plus the ARKit map they are pinned to.
///
/// The map itself is a large binary and lives in its own file beside this.
nonisolated struct RoomRecord: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var assets: [SpatialAsset] = []
    var createdAt = Date()
    var updatedAt = Date()
    /// False until a sweep manages to save a world map for it, which is what
    /// makes the next sweep able to relocalise.
    var hasWorldMap = false

    var displayName: String { name.isEmpty ? "Untitled room" : name }
}

/// Whether a detection is something new or something already on the register.
nonisolated enum SpatialMatch: Sendable, Equatable {
    case new
    case known(id: UUID, reason: String)

    var isKnown: Bool { if case .known = self { true } else { false } }
}

nonisolated enum RoomSpatialIndex {

    /// How close two detections must be to be called the same object.
    ///
    /// Half a metre is roughly "the same desk position". Tighter and a printer
    /// raycast onto its front panel one day and its top the next reads as two;
    /// looser and two machines side by side in a comms room collapse into one.
    static let defaultRadius: Float = 0.5

    /// Decides whether a detection is already on the register.
    ///
    /// Matching is on the exact label rather than the category on purpose. A
    /// keyboard and a mouse are both peripherals and habitually sit 30cm apart,
    /// so category matching would merge them; the cost of the stricter rule is
    /// that a label drifting between "computer monitor" and "television" for one
    /// screen yields a duplicate, which is the error that is visible and
    /// correctable rather than the one that silently loses a device.
    static func match(label: String,
                      position: SIMD3<Float>?,
                      barcodes: [String] = [],
                      against assets: [SpatialAsset],
                      radius: Float = defaultRadius) -> SpatialMatch {
        // An asset tag is an identity and outranks geometry: the same tag means
        // the same object even if somebody moved it across the room.
        if !barcodes.isEmpty {
            for asset in assets where !asset.barcodes.isEmpty {
                if let shared = barcodes.first(where: { asset.barcodes.contains($0) }) {
                    return .known(id: asset.id, reason: "Asset tag \(shared) already onboarded")
                }
            }
        }

        // Without a position there is nothing to compare; a detection the
        // raycast could not place has to be treated as new.
        guard let position else { return .new }

        var best: (asset: SpatialAsset, distance: Float)?
        for asset in assets where asset.label == label {
            let gap = distance(asset.position, position)
            guard gap <= radius else { continue }
            if best == nil || gap < best!.distance { best = (asset, gap) }
        }
        guard let best else { return .new }
        let centimetres = Int((best.distance * 100).rounded())
        return .known(id: best.asset.id,
                      reason: "Already onboarded \(centimetres)cm away in this room")
    }

    static func distance(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        simd_distance(lhs, rhs)
    }

    /// Folds a sweep's results into a room, returning the updated room and what
    /// was genuinely new.
    ///
    /// Assets already on the register are not duplicated; they have their
    /// sighting refreshed and anything newly read off them — a barcode, a model
    /// number — merged in, because a second look is often a better look.
    static func reconcile(room: RoomRecord,
                          sweep: [SweptAsset],
                          radius: Float = defaultRadius,
                          at time: Date = Date()) -> (room: RoomRecord, added: [SpatialAsset], seen: [UUID]) {
        var updated = room
        var added: [SpatialAsset] = []
        var seen: [UUID] = []

        for item in sweep {
            switch match(label: item.label,
                         position: item.position,
                         barcodes: item.barcodes,
                         against: updated.assets,
                         radius: radius) {
            case .known(let id, _):
                guard let index = updated.assets.firstIndex(where: { $0.id == id }) else { continue }
                updated.assets[index].lastSeenAt = time
                // Only count one visit per sweep, however many detections of it
                // the sweep produced.
                if !seen.contains(id) {
                    updated.assets[index].visits += 1
                    seen.append(id)
                }
                merge(item, into: &updated.assets[index])

            case .new:
                guard let position = item.position else { continue }
                let asset = SpatialAsset(label: item.label,
                                         category: item.category,
                                         position: position,
                                         barcodes: item.barcodes,
                                         recognizedText: item.recognizedText,
                                         onboardedAt: time,
                                         lastSeenAt: time)
                updated.assets.append(asset)
                added.append(asset)
            }
        }

        updated.updatedAt = time
        return (updated, added, seen)
    }

    private static func merge(_ item: SweptAsset, into asset: inout SpatialAsset) {
        for code in item.barcodes where !asset.barcodes.contains(code) {
            asset.barcodes.append(code)
        }
        for text in item.recognizedText where !asset.recognizedText.contains(text) {
            asset.recognizedText.append(text)
        }
    }
}

/// What one sweep found about one object, before it is known to be new or not.
nonisolated struct SweptAsset: Sendable {
    var label: String
    var category: AssetCategory
    /// Nil when the raycast found no surface to put it on.
    var position: SIMD3<Float>?
    var barcodes: [String] = []
    var recognizedText: [String] = []
}

// MARK: - Storage

/// Rooms on disk.
///
/// A room is two files: a small JSON record and, beside it, the ARWorldMap
/// archive. They are separate because the map runs to tens of megabytes and
/// nothing but relocalisation ever needs to read it.
@MainActor
@Observable
final class RoomStore {

    private(set) var rooms: [RoomRecord] = []
    private(set) var lastError: String?

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? RoomStore.defaultDirectory()
        load()
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? URL.temporaryDirectory
        return base.appendingPathComponent("Rooms", isDirectory: true)
    }

    private func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func worldMapURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).worldmap")
    }

    func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: nil)
            let decoder = JSONDecoder()
            rooms = files.filter { $0.pathExtension == "json" }
                .compactMap { try? decoder.decode(RoomRecord.self, from: Data(contentsOf: $0)) }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            lastError = "Could not read saved rooms: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(_ room: RoomRecord) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(room).write(to: recordURL(room.id), options: .atomic)
            if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = room }
            else { rooms.insert(room, at: 0) }
            rooms.sort { $0.updatedAt > $1.updatedAt }
            return true
        } catch {
            lastError = "Could not save the room: \(error.localizedDescription)"
            return false
        }
    }

    func saveWorldMap(_ data: Data, for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: worldMapURL(id), options: .atomic)
            if let index = rooms.firstIndex(where: { $0.id == id }) {
                rooms[index].hasWorldMap = true
                save(rooms[index])
            }
        } catch {
            lastError = "Could not save the room map: \(error.localizedDescription)"
        }
    }

    func worldMapData(for id: UUID) -> Data? {
        try? Data(contentsOf: worldMapURL(id))
    }

    func room(_ id: UUID) -> RoomRecord? { rooms.first { $0.id == id } }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: recordURL(id))
        try? FileManager.default.removeItem(at: worldMapURL(id))
        rooms.removeAll { $0.id == id }
    }
}
