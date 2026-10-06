//
//  WiFiSurveySection.swift
//  AssetOnBoard
//
//  The list of Wi-Fi networks in range — the one view in this app whose data
//  cannot come from the device it is running on.
//

import SwiftUI

struct WiFiSurveySection: View {
    let client: WiFiSurveyClient
    let hotspotHelper: HotspotHelperScanner
    let onRefresh: () -> Void

    /// Prefer whichever source actually produced networks. The on-device
    /// helper wins when it has anything, because it needs no Mac.
    private var networks: [WiFiNetwork] {
        hotspotHelper.networks.isEmpty ? (client.survey?.networks ?? []) : hotspotHelper.networks
    }

    var body: some View {
        Section {
            if !networks.isEmpty {
                if hotspotHelper.networks.isEmpty, client.survey?.locationGranted == false {
                    WithheldNamesBanner()
                }
                ForEach(Array(networks.enumerated()), id: \.offset) { _, network in
                    WiFiNetworkRow(network: network)
                }
            } else {
                SurveyStatusRow(client: client, hotspotHelper: hotspotHelper, onRefresh: onRefresh)
            }
        } header: {
            HStack {
                Text("Networks in range")
                if !networks.isEmpty {
                    Text(verbatim: "(\(networks.count))")
                }
                Spacer()
                if client.isBusy {
                    ProgressView().controlSize(.mini)
                } else if !networks.isEmpty {
                    Button("Rescan", action: onRefresh)
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            }
        } footer: {
            if let survey = client.survey, !survey.networks.isEmpty {
                let radios = survey.networks.count
                let distinct = survey.distinctNetworkCount
                Text(verbatim: distinct > 0
                     ? "\(radios) radios broadcasting \(distinct) network name\(distinct == 1 ? "" : "s"), strongest first. Surveyed by \(survey.hostName) on \(survey.interface) — iOS cannot perform this scan itself."
                     : "\(radios) radios in range, strongest first. Surveyed by \(survey.hostName) — iOS cannot perform this scan itself.")
            }
        }
    }
}

// MARK: - Rows

private struct WiFiNetworkRow: View {
    let network: WiFiNetwork

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                Image(systemName: network.isOpen ? "wifi" : "wifi.square.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(network.isCurrent ? Color.teal : .secondary)
                SignalBars(strength: network.signalStrength)
            }
            .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: network.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(network.ssid == nil ? .secondary : .primary)
                        .lineLimit(1)
                    if network.isCurrent {
                        Text("Joined")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.teal.opacity(0.18), in: Capsule())
                            .foregroundStyle(.teal)
                    }
                    if network.isOpen {
                        Text("Open")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                Text(verbatim: network.radioSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let bssid = network.bssid {
                        Text(verbatim: bssid.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.teal)
                    }
                    if let vendor = network.vendor {
                        Text(verbatim: vendor)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(network.rssi)")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                Text("dBm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Status

private struct SurveyStatusRow: View {
    let client: WiFiSurveyClient
    let hotspotHelper: HotspotHelperScanner
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if client.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac survey helper")
                        .font(.caption.weight(.semibold))
                    Text(verbatim: client.state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if client.state == .noHelper {
                        Text(verbatim: "swift run -c release aobscand")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemFill),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .textSelection(.enabled)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("On-device scan (NEHotspotHelper)")
                    .font(.caption.weight(.semibold))
                Text("A separate route, and not affected by any permission you can grant — this one needs an entitlement from Apple.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: hotspotHelper.status.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !client.isBusy {
                Button(action: onRefresh) {
                    Label("Look for a survey helper", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch client.state {
        case .noHelper: "desktopcomputer.trianglebadge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        default: "wifi.exclamationmark"
        }
    }
}

private struct WithheldNamesBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.orange)
            Text("Network names are being withheld. macOS releases an SSID only to a process with location access, because a name and BSSID together identify a physical place. Grant Location Services to the helper's terminal and rescan — signal, channel and security are unaffected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
