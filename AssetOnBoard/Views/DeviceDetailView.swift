//
//  DeviceDetailView.swift
//  AssetOnBoard
//
//  Everything the scan learned about one host.
//

import SwiftUI

struct DeviceDetailView: View {
    let device: NetworkDevice

    var body: some View {
        List {
            Section { identityHeader }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

            Section("Network") {
                DetailRow(label: "IP address", value: device.ip.description, monospaced: true)
                if let mac = device.macAddress {
                    DetailRow(label: "MAC address", value: mac.description, monospaced: true)
                    if mac.isLocallyAdministered {
                        FootnoteRow(text: "Randomised (private) address — the manufacturer cannot be derived from it.")
                    }
                }
                if let vendor = device.vendor {
                    DetailRow(label: "Manufacturer", value: vendor)
                }
                if let rtt = device.roundTripTime {
                    DetailRow(label: "Response time", value: String(format: "%.1f ms", rtt * 1000))
                }
                if let ttl = device.ttl {
                    DetailRow(label: "TTL", value: "\(ttl)")
                }
                ForEach(Array(device.hostnames.enumerated()), id: \.offset) { index, hostname in
                    DetailRow(label: index == 0 ? "Hostname" : "Also known as", value: hostname)
                }
            }

            Section("Seen by") {
                ForEach(DiscoveryMethod.allCases.filter { device.discoveryMethods.contains($0) }) { method in
                    Label(method.rawValue, systemImage: method.symbolName)
                        .font(.subheadline)
                }
            }

            if let netbios = device.netbios {
                Section("Windows / NetBIOS") {
                    if let name = netbios.computerName { DetailRow(label: "Computer name", value: name) }
                    if let workgroup = netbios.workgroup { DetailRow(label: "Workgroup", value: workgroup) }
                    if netbios.isDomainController { DetailRow(label: "Role", value: "Domain controller") }
                    if netbios.isMasterBrowser { DetailRow(label: "Role", value: "Master browser") }
                    if !netbios.services.isEmpty {
                        DetailRow(label: "Services", value: netbios.services.joined(separator: ", "))
                    }
                }
            }

            if !device.bonjourServices.isEmpty {
                Section("Advertised services (\(device.bonjourServices.count))") {
                    ForEach(device.bonjourServices) { service in
                        BonjourServiceRow(service: service)
                    }
                }
            }

            if !device.openPorts.isEmpty {
                Section("Open ports (\(device.openPorts.count))") {
                    ForEach(device.openPorts) { port in
                        PortRow(observation: port)
                    }
                }
            }

            let certificates = device.openPorts.flatMap(\.certificates)
            if !certificates.isEmpty {
                Section("TLS certificates") {
                    ForEach(Array(certificates.enumerated()), id: \.offset) { _, certificate in
                        CertificateRow(certificate: certificate)
                    }
                }
            }

            Section {
                DetailRow(label: "First seen", value: device.firstSeen.formatted(date: .omitted, time: .standard))
                DetailRow(label: "Last seen", value: device.lastSeen.formatted(date: .omitted, time: .standard))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var identityHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: device.category.symbolName)
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 62, height: 62)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.tint.opacity(0.14)))

            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(.title3.weight(.semibold))
                Text(device.category.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let model = device.modelName {
                    Text(model).font(.caption).foregroundStyle(.secondary)
                }
                if device.confidence > 0 {
                    ConfidenceBar(value: device.confidence)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Rows

private struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: value)
                .frame(width: 70)
            Text("\(Int(value * 100))% confidence")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct FootnoteRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct BonjourServiceRow: View {
    let service: BonjourService
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.friendlyProtocolName)
                        .font(.subheadline.weight(.medium))
                    Text(service.instanceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let port = service.port {
                    Text("\(port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !service.txtRecord.isEmpty {
                    Button {
                        withAnimation(.snappy) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(service.txtRecord.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .top, spacing: 6) {
                            Text(key)
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(value.isEmpty ? "—" : value)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PortRow: View {
    let observation: PortObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(observation.port)")
                    .font(.caption.monospaced().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.16)))
                    .foregroundStyle(.green)
                Text(observation.serviceName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let status = observation.httpStatus {
                    Text("HTTP \(status)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let tls = observation.tlsVersion {
                    Text(tls).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Text(observation.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)

            if let server = observation.httpServer, observation.summary != server {
                Text("Server: \(server)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let redirect = observation.httpRedirect {
                Text("Redirects to \(redirect)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CertificateRow: View {
    let certificate: TLSCertificateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(certificate.displayName ?? "Unnamed certificate")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if certificate.isSelfSigned { Badge(text: "Self-signed", tint: .orange) }
                if certificate.isExpired { Badge(text: "Expired", tint: .red) }
            }
            if let issuer = certificate.issuerCommonName ?? certificate.issuerOrganization {
                Text("Issued by \(issuer)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notAfter = certificate.notAfter {
                Text("Valid until \(notAfter.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !certificate.subjectAlternativeNames.isEmpty {
                Text(certificate.subjectAlternativeNames.prefix(4).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
