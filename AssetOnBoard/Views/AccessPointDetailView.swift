//
//  AccessPointDetailView.swift
//  AssetOnBoard
//

import SwiftUI

struct AccessPointDetailView: View {
    let accessPoint: AccessPoint

    var body: some View {
        List {
            Section("Identity") {
                DetailRow(label: "Role", value: accessPoint.kind.rawValue)
                if let ssid = accessPoint.ssid { DetailRow(label: "Network name", value: ssid) }
                if let model = accessPoint.model { DetailRow(label: "Model", value: model) }
                if let vendor = accessPoint.vendor { DetailRow(label: "Manufacturer", value: vendor) }
                if let number = accessPoint.upnp?.modelNumber {
                    DetailRow(label: "Model number", value: number)
                }
                if let serial = accessPoint.upnp?.serialNumber {
                    DetailRow(label: "Serial number", value: serial, monospaced: true)
                }
            }

            if accessPoint.isRadioOnly {
                Section {
                    if let evidence = accessPoint.detectionEvidence {
                        DetailRow(label: "Identified by", value: evidence)
                    }
                    if let confidence = accessPoint.detectionConfidence {
                        DetailRow(label: "Confidence", value: "\(Int(confidence * 100))%")
                    }
                    if let rssi = accessPoint.rssi {
                        DetailRow(label: "Bluetooth signal", value: "\(rssi) dBm")
                    }
                } header: {
                    Text("Overheard, not scanned")
                } footer: {
                    Text("This access point is in Bluetooth range but not on your network, so it has no IP address here. It was recognised from the setup beacon its radio broadcasts — iOS cannot read its SSID, its Wi-Fi signal strength or its channel.")
                }
            }

            Section("Addresses") {
                if let ip = accessPoint.ipAddress {
                    DetailRow(label: "IP address", value: ip.description, monospaced: true)
                    DetailRow(label: "Scope", value: ip.isPrivate ? "Private (RFC 1918)" : "Public")
                }
                if let mac = accessPoint.macAddress {
                    DetailRow(label: "MAC address", value: mac.description, monospaced: true)
                    if let source = accessPoint.macSource {
                        DetailRow(label: "Obtained via", value: source)
                    }
                    if mac.isLocallyAdministered {
                        Text("Randomised (locally administered) address — no manufacturer can be derived from it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No MAC address available. iOS exposes hardware addresses only for the access point you are joined to, or for hosts that volunteer one over NetBIOS, Bonjour or SNMP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if accessPoint.signalStrength != nil || accessPoint.roundTripTime != nil || accessPoint.isSecure != nil {
                Section("Link") {
                    if let strength = accessPoint.signalStrength {
                        DetailRow(label: "Signal strength", value: "\(Int(strength * 100))%")
                    }
                    if let secure = accessPoint.isSecure {
                        DetailRow(label: "Security", value: secure ? "Secured" : "Open")
                    }
                    if let rtt = accessPoint.roundTripTime {
                        DetailRow(label: "Response time", value: String(format: "%.1f ms", rtt * 1000))
                    }
                    if let hop = accessPoint.hopNumber {
                        DetailRow(label: "Hop number", value: "\(hop)")
                    }
                }
            }

            if let upnp = accessPoint.upnp {
                Section {
                    if let name = upnp.friendlyName { DetailRow(label: "Friendly name", value: name) }
                    if let type = upnp.deviceType { DetailRow(label: "Device type", value: type) }
                    if let server = upnp.server { DetailRow(label: "Server", value: server) }
                    if let url = upnp.presentationURL { DetailRow(label: "Admin page", value: url) }
                } header: {
                    Text("Self-reported (UPnP)")
                } footer: {
                    Text("Read from the device's own UPnP description document.")
                }
            }

            if !accessPoint.hostnames.isEmpty {
                Section("Names") {
                    ForEach(Array(accessPoint.hostnames.enumerated()), id: \.offset) { _, name in
                        Text(verbatim: name).font(.subheadline)
                    }
                }
            }

            if !accessPoint.managementServices.isEmpty {
                Section("Management interfaces") {
                    ForEach(accessPoint.managementServices, id: \.self) { service in
                        Label(service, systemImage: "slider.horizontal.3")
                            .font(.subheadline)
                    }
                }
            }

            if !accessPoint.openPorts.isEmpty {
                Section("Open ports") {
                    Text(verbatim: accessPoint.openPorts.map(String.init).joined(separator: ", "))
                        .font(.subheadline.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(accessPoint.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
