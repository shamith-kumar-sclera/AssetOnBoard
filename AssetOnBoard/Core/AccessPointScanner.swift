//
//  AccessPointScanner.swift
//  AssetOnBoard
//
//  Assembles the infrastructure picture from five independent sources.
//
//  No single source sees the whole path. NEHotspotNetwork knows the access point
//  this device is associated with — and is the only place an AP's own MAC comes
//  from. The subnet scan knows which hosts on the LAN are routers or APs. UPnP
//  makes those hosts state their own manufacturer and model. A TTL-limited trace
//  knows what sits beyond the gateway, out where a subnet sweep cannot reach.
//  And a Bluetooth pass overhears access-point hardware that is physically in
//  range but on somebody else's network entirely.
//
//  What is deliberately absent is a list of nearby SSIDs. iOS exposes no API for
//  scanning the airwaves; enumerating networks in range requires the
//  NEHotspotHelper entitlement, which Apple issues only to captive-network
//  vendors. Every source here is a way of answering "what access points are
//  around me?" without that entitlement, and none of them pretends to be a
//  Wi-Fi scan.
//

import Foundation
import Observation

@Observable
final class AccessPointScanner {

    enum Phase: Equatable {
        case idle
        case reading
        case surveying
        case interrogating
        case tracing
        case listening
        case finished

        var label: String {
            switch self {
            case .idle: "Ready"
            case .reading: "Reading the joined network"
            case .surveying: "Surveying networks in range"
            case .interrogating: "Asking routers to identify themselves"
            case .tracing: "Tracing the route out"
            case .listening: "Listening for nearby radios"
            case .finished: "Done"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var accessPoints: [AccessPoint] = []
    private(set) var hops: [RouteHop] = []
    private(set) var statusDetail = ""

    let wifiInfo = WiFiInfoProvider()
    /// Networks in range, surveyed by a helper on a Mac because iOS cannot.
    let survey = WiFiSurveyClient()
    /// The on-device route to the same list, dormant without Apple's entitlement.
    let hotspotHelper = HotspotHelperScanner()

    var isScanning: Bool {
        switch phase {
        case .reading, .surveying, .interrogating, .tracing, .listening: true
        case .idle, .finished: false
        }
    }

    /// Access points overheard by Bluetooth rather than found on this network.
    var nearbyRadios: [AccessPoint] { accessPoints.filter(\.isRadioOnly) }

    /// Infrastructure that is actually on, or beyond, this network.
    var networkInfrastructure: [AccessPoint] { accessPoints.filter { !$0.isRadioOnly } }

    var sortedAccessPoints: [AccessPoint] {
        accessPoints.sorted { lhs, rhs in
            if lhs.kind.sortRank != rhs.kind.sortRank { return lhs.kind.sortRank < rhs.kind.sortRank }
            return (lhs.hopNumber ?? 0) < (rhs.hopNumber ?? 0)
        }
    }

    private var scanTask: Task<Void, Never>?

    func requestPermissions() {
        wifiInfo.requestLocationPermission()
    }

    func start(networkScanner: NetworkScanner, bluetoothScanner: BluetoothScanner? = nil) {
        guard !isScanning else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.run(networkScanner: networkScanner, bluetoothScanner: bluetoothScanner)
        }
    }

    /// The same scan, but awaitable, for the combined run.
    func scan(networkScanner: NetworkScanner, bluetoothScanner: BluetoothScanner? = nil) async {
        guard !isScanning else { return }
        scanTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(networkScanner: networkScanner, bluetoothScanner: bluetoothScanner)
        }
        scanTask = task
        await task.value
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning { phase = .finished }
    }

    func reset() {
        stop()
        survey.reset()
        accessPoints = []
        hops = []
        phase = .idle
        statusDetail = ""
    }

    private func run(networkScanner: NetworkScanner, bluetoothScanner: BluetoothScanner?) async {
        var collected: [AccessPoint] = []

        // ---- 1. The access point we are associated with ---------------------
        phase = .reading
        statusDetail = "Reading the joined Wi-Fi network…"
        await wifiInfo.refresh()

        if let joined = wifiInfo.joined {
            collected.append(AccessPoint(
                id: "joined",
                kind: .joined,
                ssid: joined.ssid,
                macAddress: joined.bssid,
                macSource: joined.bssid == nil ? nil : "BSSID (NEHotspotNetwork)",
                ipAddress: networkScanner.gateway,
                vendor: joined.vendor,
                signalStrength: joined.signalStrength,
                isSecure: joined.isSecure
            ))
        }

        // ---- 1b. Networks in range, if a Mac on this network can see them ---
        // iOS cannot scan the airwaves at all, so this asks the aobscand helper
        // for the list. Absent a helper it reports that and the rest continues.
        phase = .surveying
        statusDetail = "Looking for a Wi-Fi survey helper…"
        await survey.refresh()
        accessPoints = collected

        // ---- 2. Routers and APs the subnet scan already found ---------------
        networkScanner.refreshInterface()
        let gateway = networkScanner.gateway
        let devices = networkScanner.devices

        // With several networks swept, "the gateway" is no longer one address:
        // each discovered network has its own router, and each of those is
        // infrastructure whether or not this device routes through it.
        var gatewayAddresses = Set([gateway].compactMap { $0 })
        for discovered in networkScanner.discoveredSubnets {
            if let router = discovered.router { gatewayAddresses.insert(router) }
            // A network whose router never answered still has one at the
            // conventional address, if anything there answered at all.
            if let likely = discovered.subnet.likelyGateway,
               devices.contains(where: { $0.ip == likely }) {
                gatewayAddresses.insert(likely)
            }
        }

        for device in devices where qualifiesAsInfrastructure(device, gateways: gatewayAddresses) {
            collected.append(accessPoint(from: device, gateways: gatewayAddresses))
        }

        // A gateway that answered nothing during the sweep still belongs here.
        if let gateway, !collected.contains(where: { $0.ipAddress == gateway && $0.kind != .joined }) {
            collected.append(AccessPoint(id: gateway.description,
                                         kind: .gateway,
                                         ipAddress: gateway,
                                         isPrivateAddress: gateway.isPrivate))
        }

        accessPoints = collected
        guard !Task.isCancelled else { phase = .finished; return }

        // ---- 3. Make every host on the subnet identify itself ---------------
        // A single UDP datagram per host, so this runs across the whole scanned
        // list rather than only over hosts the heuristics already liked. It is
        // the step that turns "192.168.1.1, no open ports" into "AVM FRITZ!Box
        // 7590", and it promotes hosts whose UPnP profile says they route.
        phase = .interrogating
        let candidates = devices.map(\.ip)
        statusDetail = "Asking \(candidates.count) host\(candidates.count == 1 ? "" : "s") to identify themselves…"

        let descriptions = await interrogate(candidates)
        for (address, description) in descriptions {
            if let existing = collected.firstIndex(where: { $0.ipAddress == address && !$0.isRadioOnly }) {
                collected[existing].upnp = description
                if collected[existing].model == nil { collected[existing].model = description.modelName }
                if collected[existing].vendor == nil { collected[existing].vendor = description.manufacturer }
            } else if description.describesInfrastructure,
                      let device = devices.first(where: { $0.ip == address }) {
                // UPnP is the only thing that spotted this one.
                var point = accessPoint(from: device, gateways: gatewayAddresses)
                point.upnp = description
                point.model = point.model ?? description.modelName
                point.vendor = point.vendor ?? description.manufacturer
                collected.append(point)
            }
        }

        accessPoints = collected
        guard !Task.isCancelled else { phase = .finished; return }

        // ---- 4. Everything beyond the gateway -------------------------------
        phase = .tracing
        statusDetail = "Tracing the route out…"
        hops = []

        // The outer closure runs on the traceroute queue and captures nothing;
        // only the hop-back to the main actor takes a reference.
        let traced = await TracerouteProbe.trace(maxHops: 12) { hop in
            Task { @MainActor [weak self] in self?.hops.append(hop) }
        }
        hops = traced

        for hop in traced {
            guard let address = hop.address, !hop.isDestination else { continue }
            // The first hop is the gateway, already represented above.
            if address == gateway { continue }
            guard !collected.contains(where: { $0.ipAddress == address }) else { continue }
            collected.append(AccessPoint(id: "hop-\(hop.hopNumber)",
                                         kind: .upstreamHop,
                                         ipAddress: address,
                                         hopNumber: hop.hopNumber,
                                         roundTripTime: hop.roundTripTime,
                                         isPrivateAddress: address.isPrivate))
        }

        accessPoints = collected
        guard !Task.isCancelled else { phase = .finished; return }

        // ---- 5. Access points in radio range but not on this network --------
        if let bluetoothScanner {
            phase = .listening
            statusDetail = "Listening for access points in range…"
            let peripherals = await bluetoothScanner.collectNearbyRadios(duration: 6)
            collected.append(contentsOf: nearbyRadios(from: peripherals, existing: collected))
            accessPoints = collected
        }

        phase = .finished
        let onNetwork = collected.filter { !$0.isRadioOnly }.count
        let overheard = collected.count - onNetwork
        var summary = "\(onNetwork) on this network"
        if let surveyed = survey.survey?.networks.count, surveyed > 0 {
            summary += " · \(surveyed) in range"
        }
        if overheard > 0 { summary += " · \(overheard) nearby radio\(overheard == 1 ? "" : "s")" }
        statusDetail = summary
    }

    // MARK: - Building entries

    private func accessPoint(from device: NetworkDevice, gateways: Set<IPv4>) -> AccessPoint {
        let isGateway = gateways.contains(device.ip)
        let services = device.openPorts
            .compactMap { InfrastructureVendors.managementService(forPort: $0.port) }
        return AccessPoint(
            id: device.ip.description,
            kind: isGateway ? .gateway : .localInfrastructure,
            macAddress: device.macAddress,
            macSource: macSource(for: device),
            ipAddress: device.ip,
            vendor: device.vendor,
            roundTripTime: device.roundTripTime,
            model: device.modelName,
            hostnames: device.hostnames,
            managementServices: Array(Set(services)).sorted(),
            openPorts: device.openPorts.map(\.port),
            isPrivateAddress: device.ip.isPrivate
        )
    }

    /// Turns Bluetooth sightings into access point entries.
    ///
    /// These are the only entries in the list with no IP address, because they
    /// were never on this network to begin with — they were overheard.
    private func nearbyRadios(from peripherals: [BluetoothDevice],
                              existing: [AccessPoint]) -> [AccessPoint] {
        var results: [AccessPoint] = []

        for peripheral in peripherals {
            guard let match = WirelessInfrastructure.identify(name: peripheral.name,
                                                              localName: peripheral.localName,
                                                              companyIdentifier: peripheral.companyIdentifier,
                                                              serviceUUIDs: peripheral.serviceUUIDs)
            else { continue }

            // A radio that is also the AP we are joined to is already listed,
            // and saying so twice would overstate what was found.
            let alreadyListed = existing.contains { point in
                guard let vendor = point.vendor ?? point.upnp?.manufacturer else { return false }
                return match.family.localizedCaseInsensitiveContains(vendor)
                    || vendor.localizedCaseInsensitiveContains(match.family)
            }
            guard !alreadyListed else { continue }

            results.append(AccessPoint(
                id: "ble-\(peripheral.id.uuidString)",
                kind: .nearbyRadio,
                macAddress: peripheral.macAddress,
                macSource: peripheral.macSource,
                vendor: match.family,
                model: peripheral.deviceInformation["Model"],
                isPrivateAddress: false,
                bluetoothIdentifier: peripheral.id,
                rssi: peripheral.bestRSSI,
                detectionEvidence: match.evidence,
                detectionConfidence: match.confidence
            ))
        }

        return results.sorted { ($0.rssi ?? -127) > ($1.rssi ?? -127) }
    }

    // MARK: - UPnP interrogation

    /// Probes every address for a UPnP description, a few at a time.
    private func interrogate(_ addresses: [IPv4]) async -> [IPv4: SSDPDescription] {
        guard !addresses.isEmpty else { return [:] }
        var results: [IPv4: SSDPDescription] = [:]
        let width = min(24, addresses.count)
        var next = 0

        await withTaskGroup(of: (IPv4, SSDPDescription?).self) { group in
            func addTask(_ address: IPv4) {
                group.addTask { (address, await SSDPProbe.interrogate(host: address)) }
            }
            while next < width { addTask(addresses[next]); next += 1 }

            while let (address, description) = await group.next() {
                if let description { results[address] = description }
                if Task.isCancelled { break }
                if next < addresses.count { addTask(addresses[next]); next += 1 }
            }
            group.cancelAll()
        }
        return results
    }

    /// Decides whether a scanned host is routing or Wi-Fi infrastructure.
    private func qualifiesAsInfrastructure(_ device: NetworkDevice, gateways: Set<IPv4>) -> Bool {
        if gateways.contains(device.ip) { return true }
        if device.category == .router || device.category == .accessPoint { return true }
        if InfrastructureVendors.isInfrastructure(device.vendor) { return true }

        // mDNS names the product outright for the vendors that publish it.
        if device.bonjourServices.contains(where: {
            WirelessInfrastructure.bonjourServiceTypes.contains($0.serviceType)
        }) { return true }

        // Hostnames and HTTP titles carry product names: "unifi.lan", "Deco M5",
        // "FRITZ!Box 7590". A sweep that only looked at ports misses all of it.
        let corpus = (device.hostnames
                      + device.openPorts.compactMap(\.httpTitle)
                      + device.openPorts.compactMap(\.httpServer)
                      + device.openPorts.compactMap(\.httpRealm)
                      + [device.modelName].compactMap { $0 })
            .joined(separator: " ")
            .lowercased()
        if WirelessInfrastructure.textSuggestsAccessPoint(corpus) { return true }

        // A management interface on a well-known port is a strong signal, but a
        // bare web server is not — plenty of things serve port 80.
        let ports = Set(device.openPorts.map(\.port))
        if ports.contains(8291) || ports.contains(10001) || ports.contains(4343) { return true }
        if ports.contains(53) && (ports.contains(80) || ports.contains(443)) { return true }
        return false
    }

    private func macSource(for device: NetworkDevice) -> String? {
        guard let mac = device.macAddress else { return nil }
        if device.netbios?.macAddress == mac { return "NetBIOS" }
        if device.bonjourServices.contains(where: { $0.advertisedMAC == mac }) { return "Bonjour" }
        if device.discoveryMethods.contains(.snmp) { return "Router SNMP" }
        if device.discoveryMethods.contains(.arp) { return "ARP cache" }
        return nil
    }
}
