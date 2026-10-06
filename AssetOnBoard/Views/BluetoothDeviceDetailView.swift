//
//  BluetoothDeviceDetailView.swift
//  AssetOnBoard
//
//  Everything a BLE peripheral advertised, plus whatever GATT revealed.
//

import SwiftUI

struct BluetoothDeviceDetailView: View {
    let device: BluetoothDevice
    let scanner: BluetoothScanner

    /// Re-read from the scanner so live RSSI and GATT results keep updating.
    private var current: BluetoothDevice {
        scanner.devices.first { $0.id == device.id } ?? device
    }

    var body: some View {
        List {
            Section { header }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

            Section("Signal") {
                DetailRow(label: "RSSI", value: "\(current.rssi) dBm")
                DetailRow(label: "Strongest seen", value: "\(current.bestRSSI) dBm")
                DetailRow(label: "Quality", value: current.signalStrength.rawValue)
                if let txPower = current.txPowerLevel {
                    DetailRow(label: "Advertised Tx power", value: "\(txPower) dBm")
                }
                if let distance = current.estimatedDistance {
                    DetailRow(label: "Estimated distance", value: String(format: "~%.1f m", distance))
                }
            }

            Section("Identity") {
                if let name = current.name { DetailRow(label: "Device name", value: name) }
                if let localName = current.localName, localName != current.name {
                    DetailRow(label: "Advertised name", value: localName)
                }
                if let manufacturer = current.manufacturerName {
                    DetailRow(label: "Manufacturer", value: manufacturer)
                }
                if let company = current.companyIdentifier {
                    DetailRow(label: "Company ID",
                              value: String(format: "0x%04X", company),
                              monospaced: true)
                }
                if let continuity = current.appleContinuityType {
                    DetailRow(label: "Apple Continuity", value: continuity)
                }
                if let appearance = current.appearanceName {
                    DetailRow(label: "Appearance", value: appearance)
                }
                DetailRow(label: "Connectable", value: current.isConnectable ? "Yes" : "No")
                DetailRow(label: "Identifier", value: current.id.uuidString, monospaced: true)
            }

            Section("Hardware address") {
                if let mac = current.macAddress {
                    DetailRow(label: "MAC address", value: mac.description, monospaced: true)
                    if let source = current.macSource {
                        DetailRow(label: "Recovered from", value: source)
                    }
                    if let vendor = current.macVendor {
                        DetailRow(label: "Registered to", value: vendor)
                    }
                    if let confidence = current.macConfidence {
                        DetailRow(label: "Confidence", value: "\(Int(confidence * 100))%")
                    }
                    if mac.isLocallyAdministered {
                        Text("Randomised (locally administered) address — the device generated it rather than the IEEE assigning it, so it identifies no manufacturer and will change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("This device published its own address. iOS did not supply it — CoreBluetooth never exposes a peripheral's hardware address.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No hardware address available. iOS never exposes a Bluetooth peripheral's address, and this device does not publish its own in its System ID, service data or name. The identifier above is generated per app and rotates, so it cannot recognise this device elsewhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if current.isConnectable && !current.isEnriched {
                        Text("Connecting and reading GATT below may reveal one — the System ID characteristic usually encodes it.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !current.deviceInformation.isEmpty || current.batteryLevel != nil {
                Section("Device information") {
                    if let battery = current.batteryLevel {
                        DetailRow(label: "Battery", value: "\(battery)%")
                    }
                    ForEach(BluetoothAssignedNumbers.deviceInformationCharacteristics, id: \.uuid) { entry in
                        if let value = current.deviceInformation[entry.label] {
                            DetailRow(label: entry.label, value: value)
                        }
                    }
                }
            }

            if !current.serviceUUIDs.isEmpty {
                Section("Advertised services (\(current.serviceUUIDs.count))") {
                    ForEach(current.serviceUUIDs, id: \.self) { uuid in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: BluetoothAssignedNumbers.serviceName(for: uuid) ?? "Unknown service")
                                .font(.subheadline.weight(.medium))
                            Text(verbatim: uuid)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let payload = current.manufacturerPayload, !payload.isEmpty {
                Section("Manufacturer payload") {
                    Text(verbatim: payload.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("Deeper inspection") {
                if current.isEnriched {
                    Label("Connected and read", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else if let error = current.enrichmentError {
                    Label {
                        Text(verbatim: error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Button {
                        scanner.enrich(current)
                    } label: {
                        Label("Connect and read GATT", systemImage: "arrow.down.circle")
                    }
                    .disabled(!current.isConnectable || scanner.availability != .ready)
                }

                if !current.isConnectable {
                    Text("This device only broadcasts; it will not accept a connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !current.gattServices.isEmpty {
                Section("GATT services (\(current.gattServices.count))") {
                    ForEach(current.gattServices) { service in
                        GATTServiceRow(service: service)
                    }
                }
            }

            Section {
                DetailRow(label: "First seen",
                          value: current.firstSeen.formatted(date: .omitted, time: .standard))
                DetailRow(label: "Last seen",
                          value: current.lastSeen.formatted(date: .omitted, time: .standard))
                DetailRow(label: "Advertisements", value: "\(current.advertisementCount)")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: current.category.symbolName)
                .font(.system(size: 30))
                .foregroundStyle(.indigo)
                .frame(width: 62, height: 62)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.indigo.opacity(0.14)))

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: current.displayName)
                    .font(.title3.weight(.semibold))
                Text(verbatim: current.category.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    SignalBars(strength: current.signalStrength)
                    Text(verbatim: "\(current.rssi) dBm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct GATTServiceRow: View {
    let service: GATTServiceRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: service.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(verbatim: service.uuid)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !service.characteristics.isEmpty {
                    Button {
                        withAnimation(.snappy) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(service.characteristics.count)")
                                .font(.caption2)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(service.characteristics) { characteristic in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: characteristic.displayName)
                                .font(.caption.weight(.medium))
                            if let value = characteristic.value, !value.isEmpty {
                                Text(verbatim: value)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                            Text(verbatim: characteristic.properties.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}
