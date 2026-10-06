//
//  DiscoveredSubnetsSection.swift
//  AssetOnBoard
//
//  The networks the app worked out exist, and how it knows.
//

import SwiftUI

struct DiscoveredSubnetsSection: View {
    let scanner: NetworkScanner
    /// Sweep one subnet on its own, from a tap on its row.
    let onScanSubnet: (IPv4Subnet) -> Void

    var body: some View {
        Section {
            if scanner.discoveredSubnets.isEmpty {
                EmptySubnetsRow(scanner: scanner)
            } else {
                ForEach(scanner.discoveredSubnets) { discovered in
                    Button {
                        onScanSubnet(discovered.subnet)
                    } label: {
                        SubnetRow(discovered: discovered,
                                  isActive: scanner.activeSubnet == discovered.subnet,
                                  deviceCount: scanner.devices.filter {
                                      discovered.subnet.contains($0.ip)
                                  }.count)
                    }
                    .buttonStyle(.plain)
                    .disabled(scanner.isScanning)
                }
            }
        } header: {
            HStack {
                Text("Subnets")
                if !scanner.discoveredSubnets.isEmpty {
                    Text(verbatim: "(\(scanner.discoveredSubnets.count))")
                }
                Spacer()
                if scanner.isDiscoveringSubnets {
                    ProgressView().controlSize(.mini)
                } else if scanner.isScanning, scanner.scansAllSubnets,
                          scanner.completedSubnets < scanner.discoveredSubnets.count {
                    Text(verbatim: "\(scanner.completedSubnets)/\(scanner.discoveredSubnets.count) swept")
                        .foregroundStyle(.secondary)
                } else if scanner.isScanning, let active = scanner.activeSubnet {
                    Text(verbatim: "sweeping \(active)")
                        .foregroundStyle(.secondary)
                } else if !scanner.discoveredSubnets.isEmpty {
                    Button("Refresh") { scanner.discoverSubnets() }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                        .disabled(scanner.isScanning)
                }
            }
        } footer: {
            if !scanner.discoveredSubnets.isEmpty {
                Text("Tap a subnet to sweep just that one. Found by reading this device's interfaces, asking the router for its routing table over SNMP, tracing the route out, and pinging the address a router would occupy in each neighbouring /24 — at whatever host number this network's own gateway uses, which is almost always the number the others use too. Only the network you are joined to has a mask this device knows for certain; the rest are assumed to be /24 unless the router said otherwise.")
            }
        }
    }
}

private struct EmptySubnetsRow: View {
    let scanner: NetworkScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if scanner.isDiscoveringSubnets {
                Text(verbatim: scanner.subnetDiscoveryDetail.isEmpty
                     ? "Looking for networks…" : scanner.subnetDiscoveryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Which other networks exist here is not something iOS will tell an app — only the one you are joined to. This works the rest out by tracing the route out, asking the router over SNMP, and pinging the address a router would occupy in each neighbouring /24.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    scanner.discoverSubnets()
                } label: {
                    Label("Find subnets", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(scanner.isScanning)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SubnetRow: View {
    let discovered: DiscoveredSubnet
    let isActive: Bool
    let deviceCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.16))
                Image(systemName: discovered.primarySource.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: discovered.subnet.description)
                        .font(.subheadline.weight(.semibold).monospaced())
                    if discovered.isLocal {
                        Text("This network")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.teal.opacity(0.18), in: Capsule())
                            .foregroundStyle(.teal)
                    }
                }
                Text(verbatim: discovered.sourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let router = discovered.router {
                    Text(verbatim: "Router \(router)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                if isActive {
                    ProgressView().controlSize(.mini)
                } else if deviceCount > 0 {
                    Text(verbatim: "\(deviceCount)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text("devices")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "\(Int(discovered.confidence * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch discovered.primarySource {
        case .localInterface: .teal
        case .snmpConnected, .snmpRoute: .orange
        case .tracerouteHop: .purple
        case .probedGateway: .blue
        case .bonjour: .indigo
        }
    }
}
