//
//  OnboardingExporter.swift
//  AssetOnBoard
//
//  The whole site as one workbook.
//
//  Sheet one is the deliverable: one row per physical asset, merged across every
//  scan, which is the list someone actually onboards from. The per-scan sheets
//  behind it are the working — the raw network, Bluetooth, access-point and
//  room records that fed it — so anyone can check a row rather than trust it.
//
//  Every merged row carries the evidence that merged it, for the same reason.
//  Only the radio scans merge with one another; a photographed object is always
//  its own row, and the Room Assets sheet keeps whatever the room scan thought
//  it matched without acting on it.
//

import Foundation

nonisolated enum OnboardingExporter {

    /// Builds the combined workbook.
    ///
    /// - Parameter report: the network scan, when one completed. Its detail
    ///   sheets and analytics come along, so the combined file is a superset of
    ///   what the Wi-Fi tab exports on its own.
    static func workbook(assets: [UnifiedAsset],
                         report: ScanReport?,
                         bluetoothDevices: [BluetoothDevice],
                         accessPoints: [AccessPoint],
                         captures: [RoomCapture],
                         startedAt: Date?,
                         finishedAt: Date?) -> Data {
        var sheets: [XLSXSheet] = [
            inventorySheet(assets,
                           report: report,
                           startedAt: startedAt,
                           finishedAt: finishedAt,
                           bluetoothCount: bluetoothDevices.count,
                           accessPointCount: accessPoints.count,
                           captureCount: captures.count)
        ]

        let evidence = evidenceSheet(assets)
        if !evidence.rows.isEmpty { sheets.append(evidence) }
        if !accessPoints.isEmpty { sheets.append(accessPointsSheet(accessPoints)) }
        let room = roomSheet(captures)
        if !room.rows.isEmpty { sheets.append(room) }

        // Everything the single-scan export produces, appended as the working.
        sheets += DeviceExporter.detailSheets(report: report, bluetoothDevices: bluetoothDevices)
        return XLSXWorkbook(sheets: sheets).data()
    }

    static func filename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "AssetOnBoard-Inventory-\(formatter.string(from: date)).xlsx"
    }

    // MARK: - Sheet 1: the inventory

    private static func inventorySheet(_ assets: [UnifiedAsset],
                                       report: ScanReport?,
                                       startedAt: Date?,
                                       finishedAt: Date?,
                                       bluetoothCount: Int,
                                       accessPointCount: Int,
                                       captureCount: Int) -> XLSXSheet {
        let columns = [
            XLSXColumn("#", width: 5),
            XLSXColumn("Asset Name", width: 30),
            XLSXColumn("Type", width: 18),
            XLSXColumn("Manufacturer", width: 22),
            XLSXColumn("Model", width: 24),
            XLSXColumn("IP Address", width: 15),
            XLSXColumn("MAC Address", width: 19),
            XLSXColumn("All MAC Addresses", width: 26),
            XLSXColumn("Hostname", width: 26),
            XLSXColumn("SSID", width: 20),
            XLSXColumn("Operating System", width: 20),
            XLSXColumn("Seen By", width: 30),
            XLSXColumn("Scans", width: 7),
            XLSXColumn("Confidence %", width: 13),
            XLSXColumn("Room", width: 18),
            XLSXColumn("Asset Tag / Barcode", width: 24),
            XLSXColumn("Open Ports", width: 26),
            XLSXColumn("Services", width: 34),
            XLSXColumn("Bluetooth RSSI", width: 14),
            XLSXColumn("Merged On", width: 52),
            XLSXColumn("First Seen", width: 20),
            XLSXColumn("Last Seen", width: 20)
        ]

        var rows: [[XLSXCell]] = []
        for (index, asset) in assets.enumerated() {
            let channels = asset.seenBy.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
            rows.append([
                .integer(index + 1),
                .text(asset.name),
                .text(asset.kind.rawValue),
                .text(asset.vendor),
                .text(asset.model),
                .text(asset.ipAddresses.first?.description),
                .text(asset.macAddresses.first?.description),
                .text(list(asset.macAddresses.map(\.description))),
                .text(list(asset.hostnames)),
                .text(asset.ssid),
                .text(asset.operatingSystem),
                .text(channels.joined(separator: ", ")),
                .integer(channels.count),
                .integer(Int((asset.confidence * 100).rounded())),
                .text(list(asset.rooms)),
                .text(list(asset.assetTags)),
                .text(list(asset.openPorts.map(String.init))),
                .text(list(asset.services)),
                asset.rssi.map { XLSXCell.integer($0) } ?? .empty,
                .text(list(asset.mergeEvidence, separator: " | ")),
                .date(asset.firstSeen),
                .date(asset.lastSeen)
            ])
        }

        return XLSXSheet(name: "Onboarding",
                         columns: columns,
                         rows: rows,
                         sideColumns: [XLSXColumn("Inventory Summary", width: 30),
                                       XLSXColumn("Value", width: 18)],
                         sideRows: summary(assets,
                                           report: report,
                                           startedAt: startedAt,
                                           finishedAt: finishedAt,
                                           bluetoothCount: bluetoothCount,
                                           accessPointCount: accessPointCount,
                                           captureCount: captureCount))
    }

    private static func summary(_ assets: [UnifiedAsset],
                                report: ScanReport?,
                                startedAt: Date?,
                                finishedAt: Date?,
                                bluetoothCount: Int,
                                accessPointCount: Int,
                                captureCount: Int) -> [[XLSXCell]] {
        var rows: [[XLSXCell]] = []
        if let startedAt { rows.append([.text("Scan started"), .date(startedAt)]) }
        if let finishedAt { rows.append([.text("Scan finished"), .date(finishedAt)]) }
        if let startedAt, let finishedAt {
            let seconds = finishedAt.timeIntervalSince(startedAt)
            rows.append([.text("Duration (seconds)"), .number((seconds * 10).rounded() / 10)])
        }
        if let report {
            rows.append([.text("Subnet"), .text(report.subnet)])
            rows.append([.text("Gateway"), .text(report.gateway?.description ?? "Not identified")])
            rows.append([.text("Scanning device"), .text(report.localAddress.description)])
        }

        let onboardable = assets.filter(\.kind.isOnboardable)
        rows.append([])
        rows.append([.heading("Totals"), .empty])
        rows.append([.text("Assets to onboard"), .integer(onboardable.count)])
        rows.append([.text("Rows in total"), .integer(assets.count)])
        rows.append([.text("Seen by 2+ scans"), .integer(assets.filter(\.isCorroborated).count)])
        rows.append([.text("With a MAC address"), .integer(assets.filter { !$0.macAddresses.isEmpty }.count)])
        rows.append([.text("With an IP address"), .integer(assets.filter { !$0.ipAddresses.isEmpty }.count)])
        rows.append([.text("Identified type"), .integer(assets.filter { $0.kind != .unknown }.count)])

        rows.append([])
        rows.append([.heading("Raw records in"), .empty])
        rows.append([.text("Network devices"), .integer(report?.devices.count ?? 0)])
        rows.append([.text("Bluetooth peripherals"), .integer(bluetoothCount)])
        rows.append([.text("Access points"), .integer(accessPointCount)])
        rows.append([.text("Room captures"), .integer(captureCount)])

        var byChannel: [AssetChannel: Int] = [:]
        for asset in assets {
            for channel in asset.seenBy { byChannel[channel, default: 0] += 1 }
        }
        if !byChannel.isEmpty {
            rows.append([])
            rows.append([.heading("Assets by scan"), .empty])
            for channel in AssetChannel.allCases {
                guard let count = byChannel[channel], count > 0 else { continue }
                rows.append([.text(channel.rawValue), .integer(count)])
            }
        }

        let byKind = AssetKind.allCases
            .map { kind in (kind.rawValue, assets.filter { $0.kind == kind }.count) }
            .filter { $0.1 > 0 }
        if !byKind.isEmpty {
            rows.append([])
            rows.append([.heading("By type"), .empty])
            for entry in byKind {
                rows.append([.text(entry.0), .integer(entry.1)])
            }
        }
        return rows
    }

    // MARK: - Sheet 2: how the merges were decided

    /// One row per merged asset, spelling out what joined its records.
    ///
    /// A merge is the one operation here that can lose a device rather than
    /// duplicate it, so it gets an audit trail rather than a footnote.
    private static func evidenceSheet(_ assets: [UnifiedAsset]) -> XLSXSheet {
        let columns = [
            XLSXColumn("Asset Name", width: 30),
            XLSXColumn("Type", width: 18),
            XLSXColumn("Scans Merged", width: 30),
            XLSXColumn("Evidence", width: 70),
            XLSXColumn("Network Records", width: 16),
            XLSXColumn("Bluetooth Records", width: 17),
            XLSXColumn("Access Point Records", width: 19),
            XLSXColumn("Room Records", width: 14)
        ]

        var rows: [[XLSXCell]] = []
        for asset in assets where asset.isCorroborated || !asset.mergeEvidence.isEmpty {
            let channels = asset.seenBy.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
            for (position, reason) in asset.mergeEvidence.enumerated() {
                rows.append([
                    .text(position == 0 ? asset.name : ""),
                    .text(position == 0 ? asset.kind.rawValue : ""),
                    .text(position == 0 ? channels.joined(separator: ", ") : ""),
                    .text(reason),
                    position == 0 ? .integer(asset.networkDevices.count) : .empty,
                    position == 0 ? .integer(asset.bluetoothDevices.count) : .empty,
                    position == 0 ? .integer(asset.accessPoints.count) : .empty,
                    position == 0 ? .integer(asset.roomAssets.count) : .empty
                ])
            }
            if asset.mergeEvidence.isEmpty {
                rows.append([
                    .text(asset.name),
                    .text(asset.kind.rawValue),
                    .text(channels.joined(separator: ", ")),
                    .text("Records carried the same identifier"),
                    .integer(asset.networkDevices.count),
                    .integer(asset.bluetoothDevices.count),
                    .integer(asset.accessPoints.count),
                    .integer(asset.roomAssets.count)
                ])
            }
        }
        return XLSXSheet(name: "Merge Evidence", columns: columns, rows: rows)
    }

    // MARK: - Sheet 3: access points

    private static func accessPointsSheet(_ points: [AccessPoint]) -> XLSXSheet {
        let columns = [
            XLSXColumn("#", width: 5),
            XLSXColumn("Name", width: 28),
            XLSXColumn("Kind", width: 24),
            XLSXColumn("SSID", width: 22),
            XLSXColumn("MAC Address", width: 19),
            XLSXColumn("MAC Source", width: 24),
            XLSXColumn("IP Address", width: 15),
            XLSXColumn("Manufacturer", width: 22),
            XLSXColumn("Model", width: 24),
            XLSXColumn("Hop", width: 6),
            XLSXColumn("RTT (ms)", width: 10),
            XLSXColumn("RSSI", width: 8),
            XLSXColumn("Secure", width: 9),
            XLSXColumn("Hostnames", width: 28),
            XLSXColumn("Management", width: 28),
            XLSXColumn("Open Ports", width: 24),
            XLSXColumn("UPnP Description", width: 34),
            XLSXColumn("Evidence", width: 34),
            XLSXColumn("Confidence %", width: 13)
        ]

        var rows: [[XLSXCell]] = []
        for (index, point) in points.sorted(by: { $0.kind.sortRank < $1.kind.sortRank }).enumerated() {
            rows.append([
                .integer(index + 1),
                .text(point.displayName),
                .text(point.kind.rawValue),
                .text(point.ssid),
                .text(point.macAddress?.description),
                .text(point.macSource),
                .text(point.ipAddress?.description),
                .text(point.vendor),
                .text(point.model),
                point.hopNumber.map { XLSXCell.integer($0) } ?? .empty,
                point.roundTripTime.map { XLSXCell.number(($0 * 1000 * 10).rounded() / 10) } ?? .empty,
                point.rssi.map { XLSXCell.integer($0) } ?? .empty,
                point.isSecure.map { XLSXCell.boolean($0) } ?? .empty,
                .text(list(point.hostnames)),
                .text(list(point.managementServices)),
                .text(list(point.openPorts.map(String.init))),
                .text(point.upnp?.displayName),
                .text(point.detectionEvidence),
                point.detectionConfidence.map { XLSXCell.integer(Int(($0 * 100).rounded())) } ?? .empty
            ])
        }
        return XLSXSheet(name: "Access Points", columns: columns, rows: rows)
    }

    // MARK: - Sheet 4: what the camera saw

    private static func roomSheet(_ captures: [RoomCapture]) -> XLSXSheet {
        let columns = [
            XLSXColumn("#", width: 5),
            XLSXColumn("Room", width: 22),
            XLSXColumn("Captured", width: 20),
            XLSXColumn("Capture Type", width: 14),
            XLSXColumn("Sightings", width: 10),
            XLSXColumn("Detected Object", width: 26),
            XLSXColumn("Raw Label", width: 20),
            XLSXColumn("Category", width: 20),
            XLSXColumn("Detector Confidence %", width: 20),
            XLSXColumn("Overall Confidence %", width: 19),
            XLSXColumn("Source", width: 18),
            XLSXColumn("Model String", width: 24),
            XLSXColumn("Barcodes", width: 26),
            XLSXColumn("Text On Object", width: 40),
            XLSXColumn("Matched Device", width: 18),
            XLSXColumn("Match Reason", width: 34)
        ]

        var rows: [[XLSXCell]] = []
        var counter = 0
        for capture in captures {
            for asset in capture.assets {
                counter += 1
                rows.append([
                    .integer(counter),
                    .text(capture.roomName),
                    .date(capture.capturedAt),
                    .text(capture.source.rawValue),
                    .integer(asset.sightings),
                    .text(asset.displayName),
                    .text(asset.rawLabel),
                    .text(asset.category.rawValue),
                    .integer(Int((asset.confidence * 100).rounded())),
                    .integer(Int((asset.overallConfidence * 100).rounded())),
                    .text(asset.source.rawValue),
                    .text(asset.likelyModelString),
                    .text(list(asset.barcodes)),
                    .text(list(asset.recognizedText)),
                    .text(asset.matchedDeviceIP?.description),
                    .text(asset.matchReason)
                ])
            }
        }
        return XLSXSheet(name: "Room Assets", columns: columns, rows: rows)
    }

    // MARK: - Helpers

    private static func list(_ values: [String], separator: String = ", ") -> String? {
        let cleaned = values.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: separator)
    }
}
