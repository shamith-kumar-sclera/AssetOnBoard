//
//  OnboardingCoordinator.swift
//  AssetOnBoard
//
//  One button, every scan, one list.
//
//  The four scanners stay independent — each tab still drives its own — and this
//  sequences them into a single pass and correlates the results. The ordering is
//  not arbitrary:
//
//    · Bluetooth listens throughout. It is passive radio, it contends with
//      nothing, and the longer it runs the more advertisements it hears, so it
//      starts first and stops last.
//    · The network scan runs next, because the access-point scan interrogates
//      addresses the network scan found and has nothing to work with until it
//      has finished.
//    · Room captures are folded in as they stand. A photograph needs someone to
//      point the phone, so the button cannot take one; what it can do is make
//      sure everything already shot ends up in the same list and the same file.
//

import Foundation
import Observation

@Observable
final class OnboardingCoordinator {

    enum Stage: Equatable {
        case idle
        case listening
        case sweeping
        case infrastructure
        case correlating
        case finished
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Ready"
            case .listening: "Listening for Bluetooth"
            case .sweeping: "Scanning the network"
            case .infrastructure: "Identifying infrastructure"
            case .correlating: "Matching devices across scans"
            case .finished: "Done"
            case .failed(let message): message
            }
        }

        var isRunning: Bool {
            switch self {
            case .listening, .sweeping, .infrastructure, .correlating: true
            case .idle, .finished, .failed: false
            }
        }
    }

    // MARK: - Observable state

    private(set) var stage: Stage = .idle
    private(set) var progress: Double = 0
    private(set) var statusDetail = ""
    private(set) var assets: [UnifiedAsset] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    /// Bluetooth needs a window of its own even when the network scan is quick,
    /// or a fast sweep would stop it before it had heard anything.
    private let minimumListenWindow: TimeInterval = 8

    private var runTask: Task<Void, Never>?

    var isRunning: Bool { stage.isRunning }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Assets an inventory would actually carry — furniture and bare beacons out.
    var onboardableAssets: [UnifiedAsset] { assets.filter(\.kind.isOnboardable) }

    var countsByChannel: [AssetChannel: Int] {
        var counts: [AssetChannel: Int] = [:]
        for asset in assets {
            for channel in asset.seenBy { counts[channel, default: 0] += 1 }
        }
        return counts
    }

    /// How many rows exist only because two scans were matched to each other.
    var mergedCount: Int { assets.filter(\.isCorroborated).count }

    // MARK: - Running

    func run(network: NetworkScanner,
             bluetooth: BluetoothScanner,
             accessPoints: AccessPointScanner,
             room: RoomScanner,
             depth: ScanDepth) {
        guard !isRunning else { return }
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.execute(network: network,
                                bluetooth: bluetooth,
                                accessPoints: accessPoints,
                                room: room,
                                depth: depth)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        guard isRunning else { return }
        stage = .finished
        finishedAt = Date()
        statusDetail = "Stopped"
    }

    func reset() {
        stop()
        assets = []
        stage = .idle
        progress = 0
        statusDetail = ""
        startedAt = nil
        finishedAt = nil
    }

    private func execute(network: NetworkScanner,
                         bluetooth: BluetoothScanner,
                         accessPoints: AccessPointScanner,
                         room: RoomScanner,
                         depth: ScanDepth) async {
        startedAt = Date()
        finishedAt = nil
        progress = 0

        // ---- Bluetooth, running underneath everything else ------------------
        stage = .listening
        statusDetail = "Starting Bluetooth…"
        bluetooth.prepare()
        // The central manager needs a moment to reach poweredOn after being
        // created, and startScan is a no-op before it does.
        try? await Task.sleep(for: .milliseconds(600))
        bluetooth.startScan()
        let listeningSince = Date()

        guard !Task.isCancelled else { return finish(cancelled: true) }

        // ---- The network ----------------------------------------------------
        stage = .sweeping
        statusDetail = "Sweeping the network…"
        progress = 0.05
        await network.scan(depth: depth)

        guard !Task.isCancelled else { return finish(cancelled: true) }
        progress = 0.7

        // ---- Infrastructure --------------------------------------------------
        stage = .infrastructure
        statusDetail = "Asking routers to identify themselves…"
        await accessPoints.scan(networkScanner: network, bluetoothScanner: bluetooth)

        guard !Task.isCancelled else { return finish(cancelled: true) }
        progress = 0.9

        // ---- Give Bluetooth its minimum window -------------------------------
        let listened = Date().timeIntervalSince(listeningSince)
        if listened < minimumListenWindow {
            stage = .listening
            statusDetail = "Listening for Bluetooth…"
            try? await Task.sleep(for: .seconds(minimumListenWindow - listened))
        }
        bluetooth.stopScan()

        // ---- Merge ------------------------------------------------------------
        stage = .correlating
        statusDetail = "Matching devices across scans…"
        progress = 0.95
        correlate(network: network, bluetooth: bluetooth, accessPoints: accessPoints, room: room)
        finish(cancelled: false)
    }

    private func finish(cancelled: Bool) {
        finishedAt = Date()
        progress = 1
        stage = .finished
        statusDetail = cancelled
            ? "Stopped — \(assets.count) asset\(assets.count == 1 ? "" : "s") kept"
            : summary
    }

    private var summary: String {
        let total = onboardableAssets.count
        let merged = mergedCount
        var text = "\(total) asset\(total == 1 ? "" : "s")"
        if merged > 0 { text += " · \(merged) seen by more than one scan" }
        return text
    }

    // MARK: - Correlation

    /// Rebuilds the unified list from whatever the scanners currently hold.
    ///
    /// Separate from the run so a room photograph taken after the scan, or a
    /// Bluetooth tab left listening, folds into the list without re-sweeping.
    func correlate(network: NetworkScanner,
                   bluetooth: BluetoothScanner,
                   accessPoints: AccessPointScanner,
                   room: RoomScanner) {
        assets = AssetCorrelator.correlate(networkDevices: network.devices,
                                           bluetoothDevices: bluetooth.devices,
                                           accessPoints: accessPoints.accessPoints,
                                           captures: room.captures)
        if !isRunning { statusDetail = summary }
    }
}
