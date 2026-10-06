//
//  AssetCorrelator.swift
//  AssetOnBoard
//
//  Decides which records from four different scans describe the same object.
//
//  This is the hard part of a combined inventory, and it is hard because the one
//  identifier that would settle it is the one iOS withholds. CoreBluetooth
//  substitutes a per-app UUID for a peripheral's hardware address, so a phone
//  seen on Wi-Fi and the same phone seen on Bluetooth share, at first glance,
//  nothing at all. What is left is evidence rather than proof:
//
//    1. The same MAC on both sides. Proof, when BLEMACExtractor managed to
//       recover one from what the device published about itself.
//    2. Adjacent MACs under one OUI. A combo chipset is issued a block of
//       addresses and hands neighbouring ones to its Wi-Fi and Bluetooth radios,
//       so the two differ by a step or two in the last octet. Strong, and the
//       only thing that works for hardware that publishes no BLE MAC at all.
//    3. The same distinctive name on both sides. Weaker, and restricted
//       accordingly — see `isDistinctive`.
//
//  Every join is recorded with the evidence that produced it, because a wrong
//  merge removes a device from the register rather than duplicating it, and that
//  is the failure nobody notices.
//
//  Three rules keep the weaker signals honest. Name and adjacency matching only
//  ever join records from *different* scans: two network hosts with the same
//  name are two printers, not one printed twice. Nothing merges two records that
//  each carry a different MAC, since distinct hardware addresses are the one
//  thing that positively rules identity out. And anything out of a room
//  photograph stays on its own row, whatever else it resembles — a detector
//  describes a shape, not a device, and that is not evidence of identity.
//

import Foundation

nonisolated enum AssetCorrelator {

    /// How far apart two MACs may sit and still be called one chipset.
    ///
    /// Vendors issue a contiguous block per device. One or two is what combo
    /// Wi-Fi/Bluetooth parts actually use; widening this starts fusing adjacent
    /// units off the same production run.
    private static let adjacentMACDistance: UInt8 = 2

    /// Names too generic to identify anything, normalised.
    ///
    /// Bare product words are the trap: two AirPods in one room both advertise
    /// "AirPods", and merging them would be exactly the silent error this is
    /// built to avoid.
    private static let genericNames: Set<String> = [
        "unnameddevice", "unknown", "unknowndevice", "device", "router", "gateway",
        "accesspoint", "printer", "speaker", "display", "monitor", "keyboard", "mouse",
        "iphone", "ipad", "ipod", "macbook", "macbookair", "macbookpro", "imac", "macmini",
        "appletv", "airpods", "airpodspro", "airpodsmax", "applewatch", "watch",
        "homepod", "thisdevice", "localhost", "android", "androiddevice", "galaxy",
        "esp32", "esphome", "raspberrypi", "chromecast", "firetv", "roku", "sonos"
    ]

    // MARK: - Entry point

    /// Merges every scan's output into one asset per physical object.
    static func correlate(networkDevices: [NetworkDevice],
                          bluetoothDevices: [BluetoothDevice],
                          accessPoints: [AccessPoint],
                          captures: [RoomCapture]) -> [UnifiedAsset] {

        // One node per input record, then repeatedly union the ones that match.
        var nodes: [UnifiedAsset] = []
        nodes += networkDevices.map { UnifiedAsset(networkDevices: [$0]) }
        nodes += bluetoothDevices.map { UnifiedAsset(bluetoothDevices: [$0]) }
        nodes += accessPoints.map { UnifiedAsset(accessPoints: [$0]) }
        nodes += captures.flatMap { capture in
            capture.assets.map {
                UnifiedAsset(roomAssets: [RoomAssetRef(asset: $0,
                                                       room: capture.roomName,
                                                       capturedAt: capture.capturedAt)])
            }
        }
        guard !nodes.isEmpty else { return [] }

        // Matching only proposes pairs; one place applies them. Letting the
        // passes mutate the disjoint set directly means two simultaneous
        // exclusive accesses to it, which Swift traps at runtime.
        var proposals: [Match] = []

        // ---- 1. Exact identifiers -----------------------------------------
        // A shared MAC or IP is identity, whichever scans produced them.
        proposals += matchesOnKey(nodes) { node in
            node.macAddresses.map { "mac:\($0)" }
        } reason: { key in
            "Same hardware address \(key.dropFirst(4))"
        }
        proposals += matchesOnKey(nodes) { node in
            node.ipAddresses.map { "ip:\($0)" }
        } reason: { key in
            "Same IP address \(key.dropFirst(3))"
        }

        // ---- 2. Cross-scan evidence ----------------------------------------
        proposals += crossScanMatches(nodes)

        // Photographed objects are never merged into anything — see the note on
        // `isPhotograph`. RoomScanner's own guess at a matching device is still
        // carried on the record, and reaches the Room Assets sheet of the
        // export, but it does not join two rows into one.

        // ---- 3. Apply ------------------------------------------------------
        var union = DisjointSet(count: nodes.count)
        var applied: [(anchor: Int, reason: String)] = []
        for match in proposals where union.union(match.lhs, match.rhs) {
            applied.append((match.lhs, match.reason))
        }

        // Roots move as unions accumulate, so evidence is attributed only once
        // every join has been made.
        var evidence: [Int: [String]] = [:]
        for entry in applied {
            evidence[union.find(entry.anchor), default: []].append(entry.reason)
        }

        // ---- 4. Collapse the groups ----------------------------------------
        var groups: [Int: UnifiedAsset] = [:]
        for (index, node) in nodes.enumerated() {
            let root = union.find(index)
            if var existing = groups[root] {
                existing.absorb(node)
                groups[root] = existing
            } else {
                groups[root] = node
            }
        }
        for (root, reasons) in evidence {
            groups[root]?.mergeEvidence = reasons
        }

        return sorted(Array(groups.values))
    }

    /// A proposed join between two records, with the reason to record for it.
    private struct Match {
        let lhs: Int
        let rhs: Int
        let reason: String
    }

    // MARK: - Matching passes

    /// Every pair of nodes that share any key from `keys`.
    private static func matchesOnKey(_ nodes: [UnifiedAsset],
                                     keys: (UnifiedAsset) -> [String],
                                     reason: (String) -> String) -> [Match] {
        var firstSeen: [String: Int] = [:]
        var matches: [Match] = []
        for (index, node) in nodes.enumerated() {
            for key in keys(node) {
                if let previous = firstSeen[key] {
                    matches.append(Match(lhs: previous, rhs: index, reason: reason(key)))
                } else {
                    firstSeen[key] = index
                }
            }
        }
        return matches
    }

    /// Pairs from *different* scans that adjacency or name says are one object.
    ///
    /// Restricted to cross-scan pairs on purpose. Within one scan these signals
    /// mean the opposite of what they mean across scans: two network hosts a MAC
    /// apart are two units on a shelf, and two peripherals advertising the same
    /// name are two of the same product.
    private static func crossScanMatches(_ nodes: [UnifiedAsset]) -> [Match] {
        var matches: [Match] = []
        for lhs in nodes.indices {
            for rhs in (lhs + 1)..<nodes.count {
                guard !isPhotograph(nodes[lhs]), !isPhotograph(nodes[rhs]) else { continue }
                guard sharesNoScan(nodes[lhs], nodes[rhs]) else { continue }
                // Two different hardware addresses is the one thing that rules
                // identity out outright, whatever else agrees.
                guard !hasConflictingMAC(nodes[lhs], nodes[rhs]) else { continue }

                if let reason = adjacencyReason(nodes[lhs], nodes[rhs]) {
                    matches.append(Match(lhs: lhs, rhs: rhs, reason: reason))
                } else if let reason = nameReason(nodes[lhs], nodes[rhs]) {
                    matches.append(Match(lhs: lhs, rhs: rhs, reason: reason))
                }
            }
        }
        return matches
    }

    /// True when the two records came from scans that do not overlap.
    private static func sharesNoScan(_ lhs: UnifiedAsset, _ rhs: UnifiedAsset) -> Bool {
        lhs.seenBy.isDisjoint(with: rhs.seenBy)
    }

    /// True for a record that came out of a room photograph.
    ///
    /// These never merge with anything. A detector reports what an object looks
    /// like, which is a weaker claim than any radio makes: two identical laptops
    /// on one desk are two rectangles, and a shape that resembles a printer is
    /// not evidence about which printer. Joining on that would put a guess about
    /// appearance on the same footing as a hardware address, and quietly remove
    /// a real device from the register when it was wrong.
    private static func isPhotograph(_ asset: UnifiedAsset) -> Bool {
        !asset.roomAssets.isEmpty
    }

    /// True when both carry MACs and none of them coincide or sit adjacent.
    private static func hasConflictingMAC(_ lhs: UnifiedAsset, _ rhs: UnifiedAsset) -> Bool {
        let left = lhs.macAddresses, right = rhs.macAddresses
        guard !left.isEmpty, !right.isEmpty else { return false }
        for a in left {
            for b in right where a == b || isAdjacent(a, b) { return false }
        }
        return true
    }

    /// The MAC-adjacency test: same OUI, same upper NIC bytes, last octet within
    /// `adjacentMACDistance`.
    private static func isAdjacent(_ lhs: MACAddress, _ rhs: MACAddress) -> Bool {
        guard lhs != rhs else { return false }
        // A randomised address is not issued from the vendor's block, so
        // adjacency says nothing about it.
        guard !lhs.isLocallyAdministered, !rhs.isLocallyAdministered else { return false }
        guard lhs.oui == rhs.oui else { return false }
        guard lhs.bytes[3] == rhs.bytes[3], lhs.bytes[4] == rhs.bytes[4] else { return false }
        let distance = lhs.bytes[5] > rhs.bytes[5]
            ? lhs.bytes[5] - rhs.bytes[5]
            : rhs.bytes[5] - lhs.bytes[5]
        return distance <= adjacentMACDistance
    }

    private static func adjacencyReason(_ lhs: UnifiedAsset, _ rhs: UnifiedAsset) -> String? {
        for a in lhs.macAddresses {
            for b in rhs.macAddresses where isAdjacent(a, b) {
                let vendor = OUIDatabase.vendor(for: a).map { " (\($0))" } ?? ""
                return "Hardware addresses \(a) and \(b) are adjacent in one vendor block\(vendor)"
            }
        }
        return nil
    }

    private static func nameReason(_ lhs: UnifiedAsset, _ rhs: UnifiedAsset) -> String? {
        let left = distinctiveNames(lhs)
        guard !left.isEmpty else { return nil }
        let right = distinctiveNames(rhs)
        for (normalised, original) in left where right[normalised] != nil {
            return "Both scans report the name “\(original)”"
        }
        return nil
    }

    /// Every name a record offers that is specific enough to identify anything,
    /// keyed by its normalised form.
    private static func distinctiveNames(_ asset: UnifiedAsset) -> [String: String] {
        var names: [String: String] = [:]
        func add(_ value: String?) {
            guard let value else { return }
            let key = normalise(value)
            guard isDistinctive(key) else { return }
            names[key] = value
        }
        for device in asset.networkDevices {
            if !device.isUnnamed { add(device.displayName) }
            device.hostnames.forEach { add(NameResolution.shortName($0)) }
            add(device.netbios?.computerName)
        }
        for device in asset.bluetoothDevices {
            add(device.name)
            add(device.localName)
        }
        for point in asset.accessPoints {
            add(point.ssid)
            point.hostnames.forEach { add(NameResolution.shortName($0)) }
        }
        return names
    }

    /// Strips everything a name can differ by while still being the same name.
    ///
    /// Bonjour writes "Shamith’s iPhone" as "Shamiths-iPhone.local", and macOS
    /// appends "(2)" when two devices claim one name; both should normalise to
    /// the same key as the Bluetooth side's "Shamith's iPhone".
    static func normalise(_ name: String) -> String {
        var text = name.lowercased()
        for suffix in [".local", ".lan", ".home", ".localdomain"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        // A trailing "(2)" or "-2" is a collision counter, not part of the name.
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
            if inside.allSatisfy(\.isNumber) { text = String(text[text.startIndex..<open]) }
        }
        let stripped = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        var result = String(String.UnicodeScalarView(stripped))
        while let last = result.last, last.isNumber, result.count > 6 {
            result.removeLast()
        }
        return result
    }

    /// Whether a normalised name identifies one object rather than a product line.
    static func isDistinctive(_ normalised: String) -> Bool {
        normalised.count >= 6
            && !genericNames.contains(normalised)
            // "iphone14pro" is still a model, not a device. A possessive or a
            // site prefix is what makes a name identify one unit, and those push
            // it past the bare product word.
            && !genericNames.contains(where: { normalised == $0 || normalised.hasPrefix($0) && normalised.count - $0.count <= 2 })
    }

    // MARK: - Helpers

    /// Most useful first: this device, then infrastructure, then corroborated
    /// assets, then everything else by address.
    private static func sorted(_ assets: [UnifiedAsset]) -> [UnifiedAsset] {
        assets.sorted { lhs, rhs in
            if lhs.isThisDevice != rhs.isThisDevice { return lhs.isThisDevice }
            let lhsInfra = lhs.kind == .router || lhs.kind == .accessPoint
            let rhsInfra = rhs.kind == .router || rhs.kind == .accessPoint
            if lhsInfra != rhsInfra { return lhsInfra }
            if lhs.isCorroborated != rhs.isCorroborated { return lhs.isCorroborated }
            switch (lhs.ipAddresses.first, rhs.ipAddresses.first) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

/// Union-find over the record list.
///
/// Correlation is transitive — a camera match to an IP, that IP's MAC matching a
/// Bluetooth MAC — so the groups have to be built by union rather than by
/// pairwise comparison against a fixed list.
nonisolated private struct DisjointSet {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var cursor = index
        while parent[cursor] != root {           // path compression
            let next = parent[cursor]
            parent[cursor] = root
            cursor = next
        }
        return root
    }

    /// Returns false when the two were already in one group.
    @discardableResult
    mutating func union(_ lhs: Int, _ rhs: Int) -> Bool {
        let a = find(lhs), b = find(rhs)
        guard a != b else { return false }
        if rank[a] < rank[b] { parent[a] = b }
        else if rank[a] > rank[b] { parent[b] = a }
        else { parent[b] = a; rank[a] += 1 }
        return true
    }
}
