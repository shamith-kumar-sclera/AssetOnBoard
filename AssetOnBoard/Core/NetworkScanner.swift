//
//  NetworkScanner.swift
//  AssetOnBoard
//
//  Orchestrates every probe and merges the results into one device list.
//
//  The pipeline is deliberately layered, because no single technique sees the
//  whole network: ICMP finds most hosts, a TCP knock catches the ones that drop
//  pings, mDNS finds devices that never answer either, and the enrichment pass
//  turns bare addresses into named, classified devices.
//

import Foundation
import Observation

@Observable
final class NetworkScanner {

    enum Phase: Equatable {
        case idle
        case preparing
        case sweeping
        case discoveringSubnets
        case nameSweep
        case knocking
        case enriching
        case finished
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Ready"
            case .preparing: "Preparing"
            case .discoveringSubnets: "Finding networks"
            case .sweeping: "Pinging subnet"
            case .nameSweep: "Asking Windows hosts"
            case .knocking: "Probing quiet hosts"
            case .enriching: "Identifying devices"
            case .finished: "Scan complete"
            case .failed(let message): message
            }
        }
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var statusDetail: String = ""
    private(set) var devices: [NetworkDevice] = []
    private(set) var interfaceInfo: LocalInterface?
    private(set) var subnet: IPv4Subnet?
    private(set) var gateway: IPv4?
    private(set) var localNetworkDenied = false
    private(set) var lastReport: ScanReport?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var arpAvailable = false
    private(set) var snmpResult: SNMPResult?
    private(set) var snmpMACCount = 0

    /// Read-only community strings tried against the gateway, in order.
    var snmpCommunities: [String] = ["public"]

    /// Scan this network instead of the one the interface is attached to.
    ///
    /// Routed networks next door are reachable but invisible to an
    /// interface-derived sweep: the addresses simply never get probed. Setting
    /// this aims the sweep somewhere else — a second SSID's subnet, a VLAN, a
    /// site on the other side of the gateway. The link-layer probes (ARP) and
    /// mDNS do not cross a router, so those stages go quiet; ICMP, TCP, NetBIOS,
    /// UPnP and reverse DNS all still work, because they are routed like any
    /// other traffic.
    var targetSubnetOverride: IPv4Subnet? {
        didSet { if targetSubnetOverride != oldValue { refreshInterface() } }
    }

    /// Networks found by SubnetDiscovery, for the UI to list.
    private(set) var discoveredSubnets: [DiscoveredSubnet] = []
    /// How far out subnet discovery looks for neighbouring networks.
    var subnetSearchBreadth: SubnetDiscovery.Breadth = .nearby
    /// Sweep every discovered network rather than only the attached one.
    var scansAllSubnets = false
    /// The network currently being swept, when working through several.
    private(set) var activeSubnet: IPv4Subnet?
    private(set) var completedSubnets = 0
    /// True while the subnet list is being rebuilt on its own.
    private(set) var isDiscoveringSubnets = false
    private(set) var subnetDiscoveryDetail = ""
    private var discoveryTask: Task<Void, Never>?

    /// True when the sweep is aimed off-link.
    var isScanningRemoteSubnet: Bool {
        guard let targetSubnetOverride, let local = interfaceInfo else { return false }
        return !targetSubnetOverride.contains(local.address)
    }

    var isScanning: Bool {
        switch phase {
        case .preparing, .discoveringSubnets, .sweeping, .nameSweep, .knocking, .enriching: true
        default: false
        }
    }

    /// Hosts that answered something, newest information merged in.
    var sortedDevices: [NetworkDevice] {
        devices.sorted { $0.ip < $1.ip }
    }

    // MARK: - Private state

    private var activeDepth: ScanDepth = .standard
    private var index: [IPv4: NetworkDevice] = [:]
    /// Addresses whose record changed since the last publish.
    private var dirty: Set<IPv4> = []
    private var publishPending = false
    private var lastPublish = Date.distantPast
    private var scanTask: Task<Void, Never>?
    private var bonjourTask: Task<Void, Never>?
    private var bonjour: BonjourDiscovery?
    private let sweeper = ICMPSweeper()

    // MARK: - Passive discovery

    /// Starts mDNS browsing without an active scan.
    ///
    /// Also the natural moment to trigger the iOS Local Network prompt, so the
    /// permission is already settled by the time the user taps Scan.
    func startPassiveDiscovery() {
        guard bonjourTask == nil else { return }
        refreshInterface()

        let discovery = BonjourDiscovery()
        bonjour = discovery
        bonjourTask = Task { [weak self] in
            for await service in discovery.start() {
                guard let self, !Task.isCancelled else { return }
                self.apply(service: service)
            }
        }

        // Give the browsers a moment, then report whether iOS refused access.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let bonjour = self.bonjour else { return }
            self.localNetworkDenied = bonjour.permissionDenied
        }
    }

    func refreshInterface() {
        let candidate = NetworkInterfaceScanner.preferredScanInterface()
        interfaceInfo = candidate
        guard let candidate else { return }
        let full = targetSubnetOverride ?? candidate.subnet
        let anchor = full.contains(candidate.address) ? candidate.address : full.network
        let resolved = full.clamped(around: anchor, maxHosts: SubnetDiscovery.maxSweepHosts)
        // Joining a different network invalidates the previous gateway.
        if subnet != resolved { gateway = nil }
        subnet = resolved
        // Provisional until the first-hop probe answers.
        gateway = gateway ?? full.likelyGateway

        Task { [weak self] in
            guard let discovered = await GatewayDiscovery.discover() else { return }
            guard let self, full.contains(discovered) else { return }
            self.gateway = discovered
        }
    }

    /// Resolves the gateway before the scan needs it, falling back to the
    /// conventional x.x.x.1 only when the first-hop probe finds nothing.
    private func resolveGateway(in subnet: IPv4Subnet) async {
        if let discovered = await GatewayDiscovery.discover(), subnet.contains(discovered) {
            gateway = discovered
        } else if gateway == nil {
            gateway = subnet.likelyGateway
        }
    }

    // MARK: - Subnet discovery

    /// Builds the subnet list without sweeping anything.
    ///
    /// Separated from the scan because the two answer different questions —
    /// "what networks are here?" takes seconds, "what is on them?" takes
    /// minutes — and there is no reason to make the first wait for the second.
    func discoverSubnets() {
        guard !isDiscoveringSubnets else { return }
        discoveryTask?.cancel()
        isDiscoveringSubnets = true

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isDiscoveringSubnets = false }

            self.refreshInterface()
            // refreshInterface only *starts* the first-hop probe, leaving the
            // conventional x.x.x.1 in place until it answers. Discovery uses the
            // gateway's host number to decide what to probe on every other
            // network, so reading it early would feed the guess back in as
            // evidence and miss every site that numbers its routers otherwise.
            if let subnet = self.subnet { await self.resolveGateway(in: subnet) }

            let interfaces = NetworkInterfaceScanner.current()
            let bonjourAddresses = self.index.values.flatMap { $0.bonjourServices.flatMap(\.addresses) }

            let found = await SubnetDiscovery.discover(
                localInterfaces: interfaces,
                gateway: self.gateway,
                snmpCommunities: self.snmpCommunities,
                bonjourAddresses: bonjourAddresses,
                breadth: self.subnetSearchBreadth
            ) { [weak self] message in
                Task { @MainActor [weak self] in self?.subnetDiscoveryDetail = message }
            }

            guard !Task.isCancelled else { return }
            self.discoveredSubnets = found
            self.subnetDiscoveryDetail = ""
        }
    }

    // MARK: - Scanning

    func start(depth: ScanDepth) {
        guard !isScanning else { return }
        startPassiveDiscovery()

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.run(depth: depth)
        }
    }

    /// The same scan, but awaitable.
    ///
    /// The combined run has to know when this finishes before it can point the
    /// access-point scan at the results, and polling `isScanning` would be a
    /// race against the final publish.
    func scan(depth: ScanDepth) async {
        guard !isScanning else { return }
        startPassiveDiscovery()

        scanTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(depth: depth)
        }
        scanTask = task
        await task.value
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        discoveryTask?.cancel()
        isDiscoveringSubnets = false
        if isScanning {
            phase = .finished
            finishedAt = Date()
            statusDetail = "Stopped"
        }
    }

    func reset() {
        stop()
        snmpResult = nil
        snmpMACCount = 0
        discoveredSubnets = []
        activeSubnet = nil
        completedSubnets = 0
        index.removeAll()
        dirty.removeAll()
        devices = []
        progress = 0
        phase = .idle
        statusDetail = ""
        lastReport = nil
    }

    private func run(depth: ScanDepth) async {
        activeDepth = depth
        startedAt = Date()
        finishedAt = nil
        phase = .preparing
        progress = 0
        completedSubnets = 0
        statusDetail = "Looking for an active network interface…"

        refreshInterface()

        if scansAllSubnets {
            await runAcrossAllSubnets(depth: depth)
            return
        }
        // The interface itself is read back from the property later; here we only
        // need to know that one exists before committing to a sweep.
        guard interfaceInfo != nil, let subnet else {
            phase = .failed("No Wi-Fi or Ethernet connection found.")
            return
        }
        await resolveGateway(in: subnet)

        // Keep whatever Bonjour already found; drop stale active results.
        // Snapshot the keys first — mutating a dictionary through its own live
        // `keys` view is undefined behaviour.
        for key in Array(index.keys) where index[key]?.bonjourServices.isEmpty ?? true {
            index.removeValue(forKey: key)
            dirty.remove(key)
        }

        let targets = subnet.hostAddresses
        activeSubnet = subnet
        statusDetail = "\(subnet) · \(targets.count) addresses"

        // ---- Stage 1: ICMP sweep -------------------------------------------
        phase = .sweeping
        var alive = Set<IPv4>()

        do {
            let replies = try await sweeper.sweep(targets: targets, rounds: 2, timeout: 1.4)
            for (address, reply) in replies {
                alive.insert(address)
                var device = index[address] ?? NetworkDevice(ip: address)
                device.roundTripTime = reply.roundTripTime
                device.ttl = reply.ttl > 0 ? reply.ttl : nil
                device.discoveryMethods.insert(.icmp)
                device.lastSeen = Date()
                store(device)
            }
        } catch {
            // An unavailable ICMP socket is survivable; the TCP knock still runs.
            statusDetail = "Ping unavailable — falling back to TCP discovery"
        }
        guard !Task.isCancelled else { return finish() }
        progress = 0.18
        statusDetail = "\(alive.count) host\(alive.count == 1 ? "" : "s") answered ping"

        // ---- Stage 2: NetBIOS name sweep -----------------------------------
        // Windows blocks ICMP out of the box and a stock install listens on none
        // of the usual TCP ports, so a ping-and-knock sweep walks straight past
        // it. It does answer a unicast NBSTAT query though, and that single
        // datagram returns the machine name and its MAC — which is why this runs
        // across the entire subnet rather than only over hosts already found.
        phase = .nameSweep
        statusDetail = "Querying \(targets.count) addresses for NetBIOS names…"

        var netbiosJobs: [@Sendable () async -> (IPv4, NetBIOSInfo)?] = []
        for host in targets {
            netbiosJobs.append { @Sendable in
                guard let info = await NetBIOSProbe.query(host: host) else { return nil }
                return (host, info)
            }
        }

        var netbiosFound = 0
        var netbiosDone = 0
        let netbiosTotal = max(netbiosJobs.count, 1)
        await runJobs(netbiosJobs, concurrency: depth.concurrency) { [weak self] result in
            guard let self else { return }
            netbiosDone += 1
            if netbiosDone % 40 == 0 {
                self.progress = 0.18 + 0.12 * (Double(netbiosDone) / Double(netbiosTotal))
            }
            guard let (host, info) = result else { return }
            netbiosFound += 1
            alive.insert(host)
            self.apply(enrichment: .netbios(host, info))
        }
        guard !Task.isCancelled else { return finish() }
        progress = 0.3
        statusDetail = "\(netbiosFound) Windows host\(netbiosFound == 1 ? "" : "s") named"

        // ---- Stage 3: TCP knock on everything that stayed silent -----------
        phase = .knocking
        let quiet = targets.filter { !alive.contains($0) }
        let knockPorts = ServiceCatalog.discoveryKnockPorts.prefix(depth.knockPortCount)

        var knockJobs: [@Sendable () async -> IPv4?] = []
        for host in quiet {
            for port in knockPorts {
                knockJobs.append { @Sendable in
                    let outcome = await TCPProbe.connect(to: host, port: port, timeout: depth.connectTimeout)
                    // A refusal is just as good as an accept: something is there.
                    return (outcome == .open || outcome == .refused) ? host : nil
                }
            }
        }

        var knockCompleted = 0
        let knockTotal = max(knockJobs.count, 1)
        await runJobs(knockJobs, concurrency: depth.concurrency) { [weak self] host in
            guard let self else { return }
            knockCompleted += 1
            if knockCompleted % 25 == 0 {
                self.progress = 0.3 + 0.1 * (Double(knockCompleted) / Double(knockTotal))
            }
            guard let host, !alive.contains(host) else { return }
            alive.insert(host)
            var device = self.index[host] ?? NetworkDevice(ip: host)
            device.discoveryMethods.insert(.tcp)
            device.lastSeen = Date()
            self.store(device)
        }
        guard !Task.isCancelled else { return finish() }

        // Anything Bonjour found on this subnet counts as alive too.
        for (address, device) in index where !device.bonjourServices.isEmpty && subnet.contains(address) {
            alive.insert(address)
        }
        progress = 0.4

        // ---- Stage 3: ARP cache (Simulator and older iOS only) -------------
        let arpEntries = ARPTable.current()
        arpAvailable = !arpEntries.isEmpty
        for (address, mac) in arpEntries where subnet.contains(address) {
            alive.insert(address)
            var device = index[address] ?? NetworkDevice(ip: address)
            device.macAddress = device.macAddress ?? mac
            device.discoveryMethods.insert(.arp)
            store(device)
        }

        // ---- Stage 3b: ask the router for its ARP table --------------------
        // The gateway is the only host that knows every IP-to-MAC binding on the
        // subnet, and iOS keeps the local ARP cache out of reach. When SNMP is
        // enabled this fills in MACs for devices that answer nothing else.
        snmpResult = nil
        snmpMACCount = 0
        if let gateway, !snmpCommunities.isEmpty {
            statusDetail = "Querying \(gateway) over SNMP…"
            if let result = await SNMPClient.readARPTable(from: gateway, communities: snmpCommunities) {
                snmpResult = result
                var contributed = 0
                for (address, mac) in result.arpTable where subnet.contains(address) {
                    alive.insert(address)
                    var device = index[address] ?? NetworkDevice(ip: address)
                    if device.macAddress == nil { contributed += 1 }
                    device.macAddress = device.macAddress ?? mac
                    device.discoveryMethods.insert(.snmp)
                    store(device)
                }
                snmpMACCount = contributed
            }
        }
        guard !Task.isCancelled else { return finish() }

        // ---- Stage 4: enrich every live host -------------------------------
        phase = .enriching
        let hosts = alive.sorted()
        statusDetail = "Identifying \(hosts.count) device\(hosts.count == 1 ? "" : "s")…"

        let ports = depth.ports
        let connectTimeout = depth.connectTimeout
        var jobs: [@Sendable () async -> Enrichment?] = []

        for host in hosts {
            jobs.append { @Sendable in
                guard let name = await NameResolution.reverseLookup(host) else { return nil }
                return .hostname(host, name)
            }
            // The name sweep already covered every address; only retry hosts it
            // did not answer for, in case the first datagram was simply lost.
            if index[host]?.netbios == nil {
                jobs.append { @Sendable in
                    guard let info = await NetBIOSProbe.query(host: host) else { return nil }
                    return .netbios(host, info)
                }
            }
            for definition in ports {
                jobs.append { @Sendable in
                    guard let observation = await ServiceProbe.probe(host: host,
                                                                     definition: definition,
                                                                     connectTimeout: connectTimeout)
                    else { return nil }
                    return .port(host, observation)
                }
            }
        }

        var completed = 0
        let total = max(jobs.count, 1)
        let hostCount = hosts.count
        await runJobs(jobs, concurrency: depth.concurrency) { [weak self] result in
            guard let self else { return }
            completed += 1
            if completed % 25 == 0 {
                self.progress = 0.4 + 0.58 * (Double(completed) / Double(total))
                self.statusDetail = "\(hostCount) hosts · \(completed.formatted())/\(total.formatted()) probes"
            }
            if let result { self.apply(enrichment: result) }
        }

        finish()
    }

    /// Discovers every reachable network, then sweeps each one in turn.
    ///
    /// Sequential rather than concurrent: each sweep already saturates the
    /// socket budget, so running two at once halves the pace of both and makes
    /// the progress bar meaningless.
    private func runAcrossAllSubnets(depth: ScanDepth) async {
        phase = .discoveringSubnets
        statusDetail = "Looking for networks…"

        if let subnet { await resolveGateway(in: subnet) }
        let interfaces = NetworkInterfaceScanner.current()
        let bonjourAddresses = index.values.flatMap { $0.bonjourServices.flatMap(\.addresses) }

        discoveredSubnets = await SubnetDiscovery.discover(
            localInterfaces: interfaces,
            gateway: gateway,
            snmpCommunities: snmpCommunities,
            bonjourAddresses: bonjourAddresses,
            breadth: subnetSearchBreadth
        ) { [weak self] message in
            Task { @MainActor [weak self] in self?.statusDetail = message }
        }

        guard !Task.isCancelled else { return finish() }
        guard !discoveredSubnets.isEmpty else {
            phase = .failed("No networks found to scan.")
            return
        }

        let targets = discoveredSubnets
        for (position, discovered) in targets.enumerated() {
            guard !Task.isCancelled else { break }
            activeSubnet = discovered.subnet
            completedSubnets = position
            targetSubnetOverride = discovered.isLocal ? nil : discovered.subnet
            refreshInterface()
            // A router's own tables can report a /12; sweeping one literally
            // would be a million probes. Narrow it to a bounded window around
            // the router we saw on it, or around its base when we saw none.
            let sweepTarget = discovered.subnet.clamped(
                around: discovered.router ?? discovered.subnet.network,
                maxHosts: SubnetDiscovery.maxSweepHosts)
            await sweep(subnet: sweepTarget,
                        depth: depth,
                        isLocal: discovered.isLocal,
                        position: position,
                        of: targets.count)
        }

        completedSubnets = targets.count
        activeSubnet = nil
        targetSubnetOverride = nil
        finish()
    }

    /// One network's worth of sweeping, scaled into the overall progress bar.
    private func sweep(subnet: IPv4Subnet,
                       depth: ScanDepth,
                       isLocal: Bool,
                       position: Int,
                       of total: Int) async {
        let slice = 1.0 / Double(max(total, 1))
        let base = slice * Double(position)
        let targets = subnet.hostAddresses

        phase = .sweeping
        statusDetail = "\(subnet) · network \(position + 1) of \(total)"

        var alive = Set<IPv4>()
        if let replies = try? await sweeper.sweep(targets: targets, rounds: 1, timeout: 1.2) {
            for (address, reply) in replies {
                alive.insert(address)
                var device = index[address] ?? NetworkDevice(ip: address)
                device.roundTripTime = reply.roundTripTime
                device.ttl = reply.ttl > 0 ? reply.ttl : nil
                device.discoveryMethods.insert(.icmp)
                device.lastSeen = Date()
                store(device)
            }
        }
        guard !Task.isCancelled else { return }

        // Stages that only work on the attached network. Skipping them off-subnet
        // is physics — ARP and a broadcast-free NetBIOS sweep do not cross a
        // router — but on the local network they are most of what finds MAC
        // addresses, so this mode must not quietly drop them.
        if isLocal {
            phase = .nameSweep
            statusDetail = "\(subnet) · querying \(targets.count) addresses for NetBIOS names…"

            var netbiosJobs: [@Sendable () async -> (IPv4, NetBIOSInfo)?] = []
            for host in targets {
                netbiosJobs.append { @Sendable in
                    guard let info = await NetBIOSProbe.query(host: host) else { return nil }
                    return (host, info)
                }
            }
            await runJobs(netbiosJobs, concurrency: depth.concurrency) { [weak self] result in
                guard let self, let (host, info) = result else { return }
                alive.insert(host)
                self.apply(enrichment: .netbios(host, info))
            }

            let arpEntries = ARPTable.current()
            arpAvailable = !arpEntries.isEmpty
            for (address, mac) in arpEntries where subnet.contains(address) {
                alive.insert(address)
                var device = index[address] ?? NetworkDevice(ip: address)
                device.macAddress = device.macAddress ?? mac
                device.discoveryMethods.insert(.arp)
                store(device)
            }

            if let gateway, !snmpCommunities.isEmpty,
               let result = await SNMPClient.readARPTable(from: gateway, communities: snmpCommunities) {
                snmpResult = result
                var contributed = 0
                for (address, mac) in result.arpTable where subnet.contains(address) {
                    alive.insert(address)
                    var device = index[address] ?? NetworkDevice(ip: address)
                    if device.macAddress == nil { contributed += 1 }
                    device.macAddress = device.macAddress ?? mac
                    device.discoveryMethods.insert(.snmp)
                    store(device)
                }
                snmpMACCount = contributed
            }
        }
        guard !Task.isCancelled else { return }
        progress = base + slice * 0.35

        // A TCP knock on everything that stayed quiet. mDNS and ARP do not cross
        // a router, so off-subnet this and ICMP are most of what is left.
        phase = .knocking
        let quiet = targets.filter { !alive.contains($0) }
        let knockPorts = ServiceCatalog.discoveryKnockPorts.prefix(depth.knockPortCount)

        var knockJobs: [@Sendable () async -> IPv4?] = []
        for host in quiet {
            for port in knockPorts {
                knockJobs.append { @Sendable in
                    let outcome = await TCPProbe.connect(to: host, port: port, timeout: depth.connectTimeout)
                    return (outcome == .open || outcome == .refused) ? host : nil
                }
            }
        }

        var knocked = 0
        let knockTotal = max(knockJobs.count, 1)
        await runJobs(knockJobs, concurrency: depth.concurrency) { [weak self] host in
            guard let self else { return }
            knocked += 1
            if knocked % 40 == 0 { self.progress = base + slice * (0.35 + 0.25 * (Double(knocked) / Double(knockTotal))) }
            guard let host, !alive.contains(host) else { return }
            alive.insert(host)
            var device = self.index[host] ?? NetworkDevice(ip: host)
            device.discoveryMethods.insert(.tcp)
            device.lastSeen = Date()
            self.store(device)
        }
        guard !Task.isCancelled else { return }

        // Enrich whatever answered.
        phase = .enriching
        let hosts = alive.sorted()
        statusDetail = "\(subnet) · identifying \(hosts.count) device\(hosts.count == 1 ? "" : "s")"

        var jobs: [@Sendable () async -> Enrichment?] = []
        for host in hosts {
            jobs.append { @Sendable in
                guard let name = await NameResolution.reverseLookup(host) else { return nil }
                return .hostname(host, name)
            }
            if index[host]?.netbios == nil {
                jobs.append { @Sendable in
                    guard let info = await NetBIOSProbe.query(host: host) else { return nil }
                    return .netbios(host, info)
                }
            }
            for definition in depth.ports {
                jobs.append { @Sendable in
                    guard let observation = await ServiceProbe.probe(host: host,
                                                                     definition: definition,
                                                                     connectTimeout: depth.connectTimeout)
                    else { return nil }
                    return .port(host, observation)
                }
            }
        }

        var done = 0
        let total = max(jobs.count, 1)
        await runJobs(jobs, concurrency: depth.concurrency) { [weak self] result in
            guard let self else { return }
            done += 1
            if done % 40 == 0 { self.progress = base + slice * (0.6 + 0.4 * (Double(done) / Double(total))) }
            if let result { self.apply(enrichment: result) }
        }
    }

    private func finish() {
        activeSubnet = nil
        dirty.formUnion(index.keys)
        publish()

        progress = 1
        phase = .finished
        finishedAt = Date()
        let count = devices.count
        statusDetail = "\(count) device\(count == 1 ? "" : "s") found"

        if let interfaceInfo, let subnet, let startedAt {
            lastReport = ScanReport(startedAt: startedAt,
                                    finishedAt: Date(),
                                    interfaceName: interfaceInfo.name,
                                    interfaceKind: interfaceInfo.kind.rawValue,
                                    localAddress: interfaceInfo.address,
                                    subnet: subnet.description,
                                    gateway: gateway,
                                    depth: activeDepth.rawValue,
                                    devices: sortedDevices)
        }
        scanTask = nil
    }

    // MARK: - Merging

    private enum Enrichment: Sendable {
        case hostname(IPv4, String)
        case netbios(IPv4, NetBIOSInfo)
        case port(IPv4, PortObservation)
    }

    private func apply(enrichment: Enrichment) {
        switch enrichment {
        case .hostname(let host, let name):
            var device = index[host] ?? NetworkDevice(ip: host)
            let tidied = NameResolution.tidy(name)
            if !device.hostnames.contains(tidied) { device.hostnames.append(tidied) }
            device.discoveryMethods.insert(.reverseDNS)
            store(device)

        case .netbios(let host, let info):
            var device = index[host] ?? NetworkDevice(ip: host)
            device.netbios = info
            if let mac = info.macAddress {
                device.macAddress = device.macAddress ?? mac
                device.vendor = device.vendor ?? OUIDatabase.vendor(for: mac)
            }
            device.discoveryMethods.insert(.netbios)
            store(device)

        case .port(let host, let observation):
            var device = index[host] ?? NetworkDevice(ip: host)
            if let existing = device.openPorts.firstIndex(where: { $0.port == observation.port }) {
                device.openPorts[existing] = observation
            } else {
                device.openPorts.append(observation)
                device.openPorts.sort { $0.port < $1.port }
            }
            device.discoveryMethods.insert(.tcp)
            store(device)
        }
    }

    private func apply(service: BonjourService) {
        // A service with no resolved address cannot be attributed to a host.
        guard let address = service.addresses.first else { return }

        var device = index[address] ?? NetworkDevice(ip: address)
        if !device.bonjourServices.contains(service) { device.bonjourServices.append(service) }
        device.discoveryMethods.insert(.bonjour)
        if let mac = service.advertisedMAC {
            device.macAddress = device.macAddress ?? mac
            device.vendor = device.vendor ?? OUIDatabase.vendor(for: mac)
        }
        device.lastSeen = Date()
        store(device)
    }

    /// Merges a sighting into the index. Deliberately cheap: fingerprinting and
    /// the SwiftUI-visible array are deferred to `publish`, because this runs
    /// once per probe result and a scan produces thousands of them.
    private func store(_ device: NetworkDevice) {
        if var existing = index[device.ip] {
            existing.merge(device)
            index[device.ip] = existing
        } else {
            index[device.ip] = device
        }
        dirty.insert(device.ip)
        schedulePublish()
    }

    /// Coalesces UI updates to a few per second.
    ///
    /// Publishing on every result meant re-fingerprinting and re-diffing the
    /// whole list thousands of times on the main actor, which is enough to trip
    /// the watchdog on a busy subnet.
    private func schedulePublish() {
        guard !publishPending else { return }
        publishPending = true
        let delay = max(0, Self.publishInterval - Date().timeIntervalSince(lastPublish))

        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self else { return }
            self.publishPending = false
            self.publish()
        }
    }

    private static let publishInterval: TimeInterval = 0.3

    private func publish() {
        lastPublish = Date()
        for address in dirty {
            guard var device = index[address] else { continue }
            device.isGateway = device.ip == gateway
            device.isThisDevice = device.ip == interfaceInfo?.address
            if device.vendor == nil, let mac = device.macAddress {
                device.vendor = OUIDatabase.vendor(for: mac)
            }
            DeviceFingerprinter.classify(&device)
            index[address] = device
        }
        dirty.removeAll()
        devices = Array(index.values)
    }

    // MARK: - Bounded concurrent execution

    /// Runs `jobs` with a fixed number in flight, applying each result on the
    /// main actor as it lands so the list fills in while the scan continues.
    private func runJobs<Result: Sendable>(_ jobs: [@Sendable () async -> Result],
                                           concurrency: Int,
                                           onResult: (Result) -> Void) async {
        guard !jobs.isEmpty else { return }
        let width = max(1, min(concurrency, jobs.count))
        var next = 0

        await withTaskGroup(of: Result.self) { group in
            while next < width {
                let job = jobs[next]
                group.addTask { await job() }
                next += 1
            }
            while let result = await group.next() {
                onResult(result)
                if Task.isCancelled { break }
                if next < jobs.count {
                    let job = jobs[next]
                    group.addTask { await job() }
                    next += 1
                }
            }
            group.cancelAll()
        }
    }
}
