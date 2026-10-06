//
//  DeviceRow.swift
//  AssetOnBoard
//

import SwiftUI

struct DeviceRow: View {
    let device: NetworkDevice

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconTint.opacity(0.16))
                Image(systemName: device.category.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(iconTint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if device.isGateway { Badge(text: "Gateway", tint: .orange) }
                    if device.isThisDevice { Badge(text: "You", tint: .blue) }
                }
                Text(device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !device.isUnnamed {
                        Text(device.ip.description)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !device.openPorts.isEmpty {
                        Label("\(device.openPorts.count)", systemImage: "poweroutlet.type.b")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !device.bonjourServices.isEmpty {
                        Label("\(device.bonjourServices.count)", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let rtt = device.roundTripTime {
                        Text(String(format: "%.0f ms", rtt * 1000))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var iconTint: Color {
        switch device.category {
        case .router, .accessPoint: .orange
        case .computer, .server: .blue
        case .phone, .tablet, .wearable: .indigo
        case .tv, .speaker: .purple
        case .printer: .teal
        case .camera: .red
        case .nas: .brown
        case .gameConsole: .green
        case .smartHome: .yellow
        case .virtualMachine: .cyan
        case .unknown: .gray
        }
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }
}
