//
//  AccessPointsView.swift
//  AssetOnBoard
//
//  Access points and routers: the joined AP, LAN infrastructure, upstream hops.
//

import SwiftUI

struct AccessPointsView: View {
    let scanner: AccessPointScanner
    let networkScanner: NetworkScanner
    let bluetoothScanner: BluetoothScanner

    var body: some View {
        NavigationStack {
            List {
                Section { JoinedNetworkCard(scanner: scanner) }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)

                if shouldShowPermissionPrompt {
                    Section { LocationPermissionRow(scanner: scanner) }
                }

                Section {
                    ControlPanel(scanner: scanner,
                                 networkScanner: networkScanner,
                                 bluetoothScanner: bluetoothScanner)
                }

                WiFiSurveySection(client: scanner.survey,
                                  hotspotHelper: scanner.hotspotHelper) {
                    Task { await scanner.survey.refresh() }
                }

                if !scanner.networkInfrastructure.isEmpty {
                    Section("On this network (\(scanner.networkInfrastructure.count))") {
                        ForEach(scanner.sortedAccessPoints.filter { !$0.isRadioOnly }) { point in
                            NavigationLink {
                                AccessPointDetailView(accessPoint: point)
                            } label: {
                                AccessPointRow(accessPoint: point)
                            }
                        }
                    }
                }

                if !scanner.nearbyRadios.isEmpty {
                    Section {
                        ForEach(scanner.sortedAccessPoints.filter(\.isRadioOnly)) { point in
                            NavigationLink {
                                AccessPointDetailView(accessPoint: point)
                            } label: {
                                AccessPointRow(accessPoint: point)
                            }
                        }
                    } header: {
                        Text("In radio range (\(scanner.nearbyRadios.count))")
                    } footer: {
                        Text("Access point hardware overheard on Bluetooth, including networks you are not joined to. Identified from the setup beacon these devices broadcast — not from a Wi-Fi scan, so there is no SSID and no signal reading for the Wi-Fi radio itself.")
                    }
                }

                if scanner.accessPoints.isEmpty {
                    Section {
                        EmptyInfrastructureRow(isScanning: scanner.isScanning,
                                               hasNetworkResults: !networkScanner.devices.isEmpty)
                    }
                }

                if !scanner.hops.isEmpty {
                    Section("Route out") {
                        ForEach(scanner.hops) { hop in
                            RouteHopRow(hop: hop)
                        }
                    }
                }

                Section {
                    Text("iOS has no API for scanning the airwaves. Listing every SSID in range needs the NEHotspotHelper entitlement, which Apple issues only to captive-network vendors, and no App Store app can read nearby network names without it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("What this tab does instead: it reads the access point you are joined to, identifies every router and AP on your subnet and makes each one state its own model over UPnP, traces the routers beyond your gateway, and listens for the Bluetooth setup beacons that access point hardware broadcasts — which is the one way to see radios that are in range but on somebody else's network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Why there is no list of SSIDs")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Access Points")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            scanner.reset()
                        } label: {
                            Label("Clear Results", systemImage: "trash")
                        }
                        .disabled(scanner.accessPoints.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task { await scanner.wifiInfo.refresh() }
        }
    }

    private var shouldShowPermissionPrompt: Bool {
        switch scanner.wifiInfo.status {
        case .needsLocationPermission, .locationDenied: true
        default: false
        }
    }
}

// MARK: - Header

private struct JoinedNetworkCard: View {
    let scanner: AccessPointScanner

    private var joined: JoinedNetwork? { scanner.wifiInfo.joined }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wifi.router.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.22)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: joined?.ssid ?? "Connected access point")
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .opacity(0.85)
                        .lineLimit(2)
                }
                Spacer()
            }

            Divider().overlay(.white.opacity(0.3))
            HStack(spacing: 0) {
                Stat(title: "AP MAC", value: joined?.bssid?.description ?? "—")
                Stat(title: "Vendor", value: joined?.vendor ?? "—")
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.teal, Color.blue],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var subtitle: String {
        if let joined {
            var parts: [String] = []
            if let secure = joined.isSecure { parts.append(secure ? "Secured" : "Open network") }
            if let strength = joined.signalStrength {
                parts.append("signal \(Int(strength * 100))%")
            }
            if parts.isEmpty { parts.append("Joined") }
            return parts.joined(separator: " · ")
        }
        return scanner.wifiInfo.status.message
    }
}

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .opacity(0.75)
            Text(verbatim: value)
                .font(.subheadline.weight(.medium).monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LocationPermissionRow: View {
    let scanner: AccessPointScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location access needed for the AP's MAC", systemImage: "location.circle")
                .font(.subheadline.weight(.semibold))
            Text(verbatim: scanner.wifiInfo.status.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            if scanner.wifiInfo.status == .needsLocationPermission {
                Button("Allow Location Access") { scanner.requestPermissions() }
                    .font(.caption.weight(.semibold))
            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Controls

private struct ControlPanel: View {
    let scanner: AccessPointScanner
    let networkScanner: NetworkScanner
    let bluetoothScanner: BluetoothScanner

    var body: some View {
        VStack(spacing: 12) {
            if scanner.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(verbatim: scanner.phase.label)
                        .font(.caption.weight(.medium))
                    Text(verbatim: scanner.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            } else if !scanner.statusDetail.isEmpty {
                Text(verbatim: scanner.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if networkScanner.devices.isEmpty {
                Text("Run a Wi-Fi scan first to identify routers and access points on your subnet. Without one this still traces the route out and listens for access points in Bluetooth range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if scanner.isScanning {
                    scanner.stop()
                } else {
                    scanner.start(networkScanner: networkScanner,
                                  bluetoothScanner: bluetoothScanner)
                }
            } label: {
                Label(scanner.isScanning ? "Stop" : "Find Access Points",
                      systemImage: scanner.isScanning ? "stop.fill" : "wifi.router")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(scanner.isScanning ? .red : .accentColor)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rows

struct AccessPointRow: View {
    let accessPoint: AccessPoint

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.16))
                Image(systemName: accessPoint.kind.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: accessPoint.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: accessPoint.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let ip = accessPoint.ipAddress {
                        Text(verbatim: ip.description)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let mac = accessPoint.macAddress {
                        Text(verbatim: mac.description)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.teal)
                    }
                    if let rtt = accessPoint.roundTripTime {
                        Text(verbatim: String(format: "%.0f ms", rtt * 1000))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if accessPoint.isRadioOnly {
                        Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.indigo)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var tint: Color {
        switch accessPoint.kind {
        case .joined: .teal
        case .gateway: .orange
        case .localInfrastructure: .blue
        case .upstreamHop: .purple
        case .nearbyRadio: .indigo
        }
    }
}

private struct RouteHopRow: View {
    let hop: RouteHop

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(hop.hopNumber)")
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: hop.address?.description ?? "No reply")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(hop.timedOut ? .secondary : .primary)
                if let address = hop.address {
                    Text(verbatim: address.isPrivate ? "Private network" : "Public internet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let rtt = hop.roundTripTime {
                Text(verbatim: String(format: "%.0f ms", rtt * 1000))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if hop.isDestination {
                Badge(text: "Target", tint: .green)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyInfrastructureRow: View {
    let isScanning: Bool
    let hasNetworkResults: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.router")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(verbatim: isScanning ? "Looking…" : "No routers identified yet")
                .font(.subheadline.weight(.medium))
            Text(verbatim: hasNetworkResults
                 ? "Tap Find Access Points to identify routers among the devices already scanned."
                 : "Run a Wi-Fi scan first, then come back — routers are identified from those results.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
