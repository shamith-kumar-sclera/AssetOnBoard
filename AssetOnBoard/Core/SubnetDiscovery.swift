//
//  SubnetDiscovery.swift
//  AssetOnBoard
//
//  Works out which networks exist around this device, before anything is swept.
//
//  A subnet sweep can only find what it is pointed at, and iOS tells an app
//  about exactly one network: the one its interface sits on. Everything else has
//  to be inferred, so this tries every route available and keeps whatever
//  answers, tagged with where it came from:
//
//    1. Local interfaces      — getifaddrs; certain, but only our own segment.
//    2. Router SNMP tables    — authoritative when SNMP is on. The router knows
//                               every network it routes; nothing else does.
//    3. Traceroute hops       — each router on the way out reveals a transit
//                               network, which is how a second SSID's subnet
//                               turns up without anyone typing it in.
//    4. Stepped gateway sweep — one ping at the address a router would occupy
//                               in each /24 of the surrounding space. Crude, but
//                               it finds the networks the other three miss, and
//                               it is the only source that works when SNMP is
//                               off and the route out leaves the site directly.
//    5. Bonjour addresses     — a service that resolved off-subnet proves a
//                               network exists, and occasionally beats the rest.
//
//  DNS and DHCP server addresses are sources on other platforms and would be
//  good ones here; iOS exposes neither (resolv.h is outside the Darwin module
//  map and the DHCP server address is not vended at all), so there is nothing
//  to read.
//

import Foundation

nonisolated struct DiscoveredSubnet: Sendable, Hashable, Identifiable {
    enum Source: String, Sendable, Hashable, CaseIterable {
        case localInterface = "Local interface"
        case snmpConnected = "Router interface table"
        case snmpRoute = "Router routing table"
        case tracerouteHop = "Traceroute hop"
        case probedGateway = "Probed gateway"
        case bonjour = "Bonjour"

        /// Ordering for display, and which source wins when two agree.
        var rank: Int {
            switch self {
            case .localInterface: 0
            case .snmpConnected: 1
            case .snmpRoute: 2
            case .tracerouteHop: 3
            case .probedGateway: 4
            case .bonjour: 5
            }
        }

        /// True for sources that learn an address but never a mask, and so have
        /// to assume /24 for the network around it.
        var assumesPrefix: Bool {
            switch self {
            case .localInterface, .snmpConnected, .snmpRoute: false
            case .tracerouteHop, .probedGateway, .bonjour: true
            }
        }

        var symbolName: String {
            switch self {
            case .localInterface: "antenna.radiowaves.left.and.right"
            case .snmpConnected, .snmpRoute: "wifi.router.fill"
            case .tracerouteHop: "arrow.up.forward"
            case .probedGateway: "scope"
            case .bonjour: "dot.radiowaves.left.and.right"
            }
        }
    }

    var subnet: IPv4Subnet
    var sources: Set<Source>
    /// A router address seen on this network, when one was observed.
    var router: IPv4?
    /// True for the network this device is actually attached to.
    var isLocal: Bool

    var id: String { subnet.description }

    /// The most trustworthy source that found it.
    var primarySource: Source {
        sources.min { $0.rank < $1.rank } ?? .probedGateway
    }

    var sourceSummary: String {
        sources.sorted { $0.rank < $1.rank }.map(\.rawValue).joined(separator: ", ")
    }

    /// True when every source that found this network had to guess its mask.
    var prefixIsAssumed: Bool { sources.allSatisfy(\.assumesPrefix) }

    /// Corroboration matters: two independent methods agreeing is worth more
    /// than any one of them alone.
    var confidence: Double {
        if isLocal { return 1 }
        var score = 0.0
        for source in sources {
            switch source {
            case .localInterface: score += 1
            case .snmpConnected: score += 0.9
            case .snmpRoute: score += 0.75
            case .tracerouteHop: score += 0.6
            case .probedGateway: score += 0.5
            case .bonjour: score += 0.4
            }
        }
        return min(1, score)
    }
}

private extension Array {
    /// Splits into fixed-size batches, for work that has to report progress and
    /// stay cancellable.
    nonisolated func chunks(of size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

nonisolated enum SubnetDiscovery {

    /// How far out from this device to look for neighbouring networks.
    enum Breadth: String, Sendable, CaseIterable, Identifiable {
        /// The /16 around our own address — 256 candidate /24s. This is the
        /// neighbourhood a single site actually occupies, and it finishes in
        /// seconds.
        case nearby
        /// The whole RFC 1918 block this device sits in: 10/8, 172.16/12 or
        /// 192.168/16, whichever contains our address.
        case block
        /// All three RFC 1918 blocks, wherever this device sits. Roughly 70,000
        /// candidate /24s — minutes rather than seconds.
        case allPrivate

        var id: String { rawValue }

        var label: String {
            switch self {
            case .nearby: "Nearby"
            case .block: "This block"
            case .allPrivate: "All private"
            }
        }

        var explanation: String {
            switch self {
            case .nearby:
                "The /16 around this device — 256 networks. Seconds."
            case .block:
                "The whole private range this device sits in — 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16, whichever it is on. Tens of thousands of probes."
            case .allPrivate:
                "All three private ranges — 10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16, about 70,000 networks. Minutes rather than seconds, and a lot of traffic."
            }
        }
    }

    /// The space `nearby` covers: one /16 centred on the anchor.
    private static let sweepPrefixLength = 16

    /// Host numbers a router conventionally answers on, best first.
    private static let gatewayHosts: [UInt8] = [1, 254]

    /// The three RFC 1918 ranges, widest last.
    ///
    /// Still commonly called the Class A, B and C private ranges, after a
    /// classful split that stopped governing allocation with CIDR in 1993. The
    /// ranges themselves are exactly those: 10.0.0.0–10.255.255.255,
    /// 172.16.0.0–172.31.255.255 and 192.168.0.0–192.168.255.255.
    static let privateBlocks: [IPv4Subnet] = [
        IPv4Subnet(network: IPv4(raw: 0xC0A8_0000), prefixLength: 16),   // 192.168/16, 256 /24s
        IPv4Subnet(network: IPv4(raw: 0xAC10_0000), prefixLength: 12),   // 172.16/12, 4,096
        IPv4Subnet(network: IPv4(raw: 0x0A00_0000), prefixLength: 8)     // 10/8, 65,536
    ]

    /// Addresses per ICMP round when stepping a large space.
    ///
    /// Sweeping every private range is hundreds of thousands of packets. One
    /// blocking call would report no progress and ignore cancellation for
    /// minutes, so the work is cut into rounds this size.
    private static let probeChunkSize = 8_192

    /// Largest sweep any one network is allowed to become.
    static let maxSweepHosts = 4_096

    /// Widest prefix allowed to absorb a network that sits inside it.
    ///
    /// A /8 or /12 out of a routing table covers every other network here.
    /// Letting one of those swallow the rest is how four real subnets collapse
    /// into a single useless row.
    private static let widestAbsorbingPrefix = 16

    /// Well-known gateway addresses, tried in addition to the stepped sweep.
    ///
    /// These cover the case the stepped sweep structurally cannot: a network in
    /// a different RFC 1918 block entirely, such as a 192.168.1.0/24 guest SSID
    /// beside a 10.x corporate network. Deliberately short — it is a list of
    /// factory defaults, not an attempt to enumerate RFC 1918.
    private static let wellKnownGateways: [String] = [
        "192.168.0.1", "192.168.1.1", "192.168.2.1", "192.168.4.1",
        "192.168.8.1", "192.168.10.1", "192.168.29.1", "192.168.31.1",
        "192.168.50.1", "192.168.100.1", "192.168.178.1",
        "10.0.0.1", "10.0.1.1", "10.1.1.1", "10.10.10.1",
        "172.16.0.1", "172.16.1.1", "172.20.10.1"
    ]

    // MARK: - Where to look

    /// Ceiling on the stepped sweep, so a runaway space cannot become an
    /// unbounded scan. Candidates are generated home-block-first, so a truncated
    /// list is still the most useful part of one.
    private static func maxCandidates(for breadth: Breadth) -> Int {
        switch breadth {
        case .nearby: 8_192
        case .block, .allPrivate: 262_144
        }
    }

    /// The address spaces a stepped gateway sweep should cover.
    ///
    /// Distinct spaces are always disjoint — separate /16s, or separate RFC 1918
    /// blocks — so the candidates generated from them need no deduplication.
    static func sweepSpaces(anchors: [IPv4], breadth: Breadth) -> [IPv4Subnet] {
        switch breadth {
        case .nearby:
            return unique(anchors.map { IPv4Subnet(network: $0, prefixLength: sweepPrefixLength) })
        case .block:
            return unique(anchors.map(enclosingPrivateBlock))
        case .allPrivate:
            // Our own block first. The other two can take minutes, and the
            // networks worth finding are usually numbered beside ours.
            let home = anchors.first.map(enclosingPrivateBlock)
            return unique([home].compactMap { $0 }.filter(privateBlocks.contains) + privateBlocks)
        }
    }

    private static func unique(_ subnets: [IPv4Subnet]) -> [IPv4Subnet] {
        var seen = Set<IPv4Subnet>()
        return subnets.filter { seen.insert($0).inserted }
    }

    /// How many probes a sweep at this breadth would send, for the UI to warn with.
    static func estimatedProbeCount(anchors: [IPv4],
                                    breadth: Breadth,
                                    observedGateways: [IPv4] = []) -> Int {
        let hosts = candidateHosts(breadth: breadth, observedGateways: observedGateways).count
        let steps = sweepSpaces(anchors: anchors, breadth: breadth).reduce(0) { $0 + stepCount(in: $1) }
        return min(steps * hosts, maxCandidates(for: breadth))
    }

    /// How many /24s a space contains, capped at the 65,536 in a /8.
    private static func stepCount(in space: IPv4Subnet) -> Int {
        1 << min(max(24 - space.prefixLength, 0), 16)
    }

    /// The RFC 1918 block `address` belongs to, or its /16 when it belongs to none.
    private static func enclosingPrivateBlock(_ address: IPv4) -> IPv4Subnet {
        let octets = address.octets
        if octets[0] == 10 {
            return IPv4Subnet(network: address, prefixLength: 8)
        }
        if octets[0] == 172, (16...31).contains(octets[1]) {
            return IPv4Subnet(network: address, prefixLength: 12)
        }
        if octets[0] == 192, octets[1] == 168 {
            return IPv4Subnet(network: address, prefixLength: 16)
        }
        return IPv4Subnet(network: address, prefixLength: sweepPrefixLength)
    }

    /// How many observed host numbers to carry into the sweep.
    ///
    /// Each extra number is another packet per /24 — 256 more across a /16, but
    /// 65,536 more across a 10/8. The wider the sweep, the fewer guesses it can
    /// afford.
    private static func maxObservedHosts(for breadth: Breadth) -> Int {
        switch breadth {
        case .nearby: 4
        case .block, .allPrivate: 2
        }
    }

    /// Which host number to try in each candidate /24.
    ///
    /// This is the part that decides whether the whole method works. Probing
    /// only .1 and .254 finds nothing on a site that numbers its routers .250 —
    /// and plenty do. But whatever host number *this* network gave its own
    /// routers is almost certainly the number its other routers use too: one
    /// admin, one convention, one address plan. Those observed numbers are the
    /// strongest evidence available and go first.
    ///
    /// Every router seen counts, not only the default gateway: a traceroute hop
    /// and an SNMP-reported leg are the same kind of evidence, and the gateway
    /// probe does not always answer.
    static func candidateHosts(breadth: Breadth, observedGateways: [IPv4]) -> [UInt8] {
        var hosts: [UInt8] = []
        for observed in observedGateways {
            let host = observed.octets[3]
            guard (1...254).contains(host), !hosts.contains(host) else { continue }
            hosts.append(host)
            if hosts.count >= maxObservedHosts(for: breadth) { break }
        }
        // .1 always; .254 only when the space is small enough to afford a
        // second packet per /24.
        let conventional = breadth == .nearby ? gatewayHosts : [gatewayHosts[0]]
        for host in conventional where !hosts.contains(host) { hosts.append(host) }
        return hosts
    }

    static func candidateHosts(breadth: Breadth, observedGateway: IPv4?) -> [UInt8] {
        candidateHosts(breadth: breadth, observedGateways: [observedGateway].compactMap { $0 })
    }

    /// Every address worth one ping when looking for a neighbouring router.
    ///
    /// Steps one /24 at a time across the sweep space, because the mask is the
    /// one thing nothing here can see: /24 is what sites actually deploy, and a
    /// router answering at all is the evidence that a network exists.
    static func gatewayCandidates(anchors: [IPv4],
                                  breadth: Breadth = .nearby,
                                  observedGateways: [IPv4] = []) -> [IPv4] {
        let hosts = candidateHosts(breadth: breadth, observedGateways: observedGateways)
        guard !hosts.isEmpty else { return [] }

        let limit = maxCandidates(for: breadth)
        let spaces = sweepSpaces(anchors: anchors, breadth: breadth)
        var candidates: [IPv4] = []
        candidates.reserveCapacity(min(spaces.reduce(0) { $0 + stepCount(in: $1) } * hosts.count, limit))

        for space in spaces {
            for step in 0..<stepCount(in: space) {
                let base = space.network.raw &+ (UInt32(step) << 8)
                for host in hosts {
                    candidates.append(IPv4(raw: base &+ UInt32(host)))
                    if candidates.count >= limit { return candidates }
                }
            }
        }
        return candidates
    }

    static func gatewayCandidates(anchor: IPv4,
                                  breadth: Breadth = .nearby,
                                  observedGateways: [IPv4] = []) -> [IPv4] {
        gatewayCandidates(anchors: [anchor], breadth: breadth, observedGateways: observedGateways)
    }

    // MARK: - Discovery

    /// Runs every method and merges the results.
    ///
    /// - Parameter onProgress: called as each method finishes, for the UI.
    static func discover(localInterfaces: [LocalInterface],
                         gateway: IPv4?,
                         snmpCommunities: [String],
                         bonjourAddresses: [IPv4] = [],
                         includeProbing: Bool = true,
                         breadth: Breadth = .nearby,
                         onProgress: (@Sendable (String) -> Void)? = nil) async -> [DiscoveredSubnet] {

        var found: [IPv4Subnet: DiscoveredSubnet] = [:]

        func record(_ subnet: IPv4Subnet, _ source: DiscoveredSubnet.Source,
                    router: IPv4? = nil, isLocal: Bool = false) {
            guard isPlausibleLAN(subnet) else { return }
            if var existing = found[subnet] {
                existing.sources.insert(source)
                existing.router = existing.router ?? router
                existing.isLocal = existing.isLocal || isLocal
                found[subnet] = existing
            } else {
                found[subnet] = DiscoveredSubnet(subnet: subnet,
                                                 sources: [source],
                                                 router: router,
                                                 isLocal: isLocal)
            }
        }

        // ---- 1. Our own interfaces -----------------------------------------
        onProgress?("Reading local interfaces…")
        let scannable = localInterfaces.filter(\.isScannable)
        for interface in scannable {
            record(interface.subnet.clamped(around: interface.address, maxHosts: maxSweepHosts),
                   .localInterface,
                   isLocal: true)
        }

        // ---- 2. Ask the router -------------------------------------------—
        if let gateway, !snmpCommunities.isEmpty {
            onProgress?("Asking \(gateway) for its routing table…")
            if let topology = await SNMPClient.readTopology(from: gateway,
                                                            communities: snmpCommunities) {
                for (subnet, address) in topology.connectedSubnets {
                    record(subnet, .snmpConnected, router: address)
                }
                for subnet in topology.routedSubnets {
                    record(subnet, .snmpRoute, router: subnet.likelyGateway)
                }
            }
        }
        guard !Task.isCancelled else { return sorted(found) }

        // ---- 3. Trace the way out ------------------------------------------
        onProgress?("Tracing the route out…")
        let hops = await TracerouteProbe.trace(maxHops: 8)
        for hop in hops {
            guard let address = hop.address, address.isPrivate else { continue }
            // A hop address implies a network around it; /24 is the safe guess
            // when the router will not tell us the real mask.
            record(IPv4Subnet(network: address, prefixLength: IPv4Subnet.defaultPrefixLength),
                   .tracerouteHop,
                   router: address)
        }
        guard !Task.isCancelled else { return sorted(found) }

        // ---- 4. Knock on the addresses routers actually use -----------------
        if includeProbing {
            // Anchor on our own address, because the networks worth finding are
            // the ones numbered next to it. The gateway is the fallback when
            // there is no scannable interface to anchor on.
            let anchors = scannable.map(\.address) + [gateway].compactMap { $0 }
            // Feed back every router the earlier stages saw. The gateway probe
            // is the best source of the site's host-numbering convention, but
            // it is not the only one, and it does not always answer in time.
            let observedGateways = [gateway].compactMap { $0 }
                + found.values.sorted { $0.primarySource.rank < $1.primarySource.rank }
                    .compactMap(\.router)

            // Addresses inside a network we already know about are not new
            // information, and the real sweep will reach them anyway.
            func isNew(_ candidate: IPv4) -> Bool {
                !found.keys.contains { $0.contains(candidate) }
            }

            let stepped = gatewayCandidates(anchors: anchors,
                                            breadth: breadth,
                                            observedGateways: observedGateways).filter(isNew)
            var probed = 0

            for chunk in stepped.chunks(of: probeChunkSize) {
                guard !Task.isCancelled else { break }
                probed += chunk.count
                onProgress?("Probing gateways… \(probed.formatted()) of \(stepped.count.formatted())")
                for address in await ping(chunk) {
                    record(IPv4Subnet(network: address, prefixLength: IPv4Subnet.defaultPrefixLength),
                           .probedGateway,
                           router: address)
                }
            }

            // A second look at the addresses most likely to be a router, now
            // that `found` reflects everything the stepped sweep placed. What it
            // already found is skipped; what it missed gets a TCP knock, which
            // catches both the routers that drop ICMP and the replies lost to a
            // single unretried round across six figures of packets.
            let wellKnown = wellKnownGateways.compactMap(IPv4.init).filter(isNew)
            if !Task.isCancelled, !wellKnown.isEmpty {
                onProgress?("Probing \(wellKnown.count) well-known gateway addresses…")
                for address in await probe(wellKnown) {
                    record(IPv4Subnet(network: address, prefixLength: IPv4Subnet.defaultPrefixLength),
                           .probedGateway,
                           router: address)
                }
            }
        }
        guard !Task.isCancelled else { return sorted(found) }

        // ---- 5. Anything Bonjour resolved off-subnet ------------------------
        for address in bonjourAddresses where address.isPrivate {
            guard !found.keys.contains(where: { $0.contains(address) }) else { continue }
            record(IPv4Subnet(network: address, prefixLength: IPv4Subnet.defaultPrefixLength),
                   .bonjour)
        }

        let consolidated = consolidate(found)
        onProgress?("\(consolidated.count) network\(consolidated.count == 1 ? "" : "s") found")
        return consolidated
    }

    /// A network worth listing at all.
    ///
    /// Wider than a /8 or narrower than a /30 is a routing-table artefact — a
    /// summary or a host route — rather than a segment with hosts on it. A
    /// public range has no business in a LAN inventory even if a router
    /// mentions it. And 169.254/16 is what an interface gives itself when DHCP
    /// fails: sweeping it is thousands of probes at nothing.
    static func isPlausibleLAN(_ subnet: IPv4Subnet) -> Bool {
        (8...30).contains(subnet.prefixLength)
            && subnet.network.isPrivate
            && !subnet.network.isLoopback
            && !subnet.network.isLinkLocal
    }

    /// Folds a guessed /24 into the larger network that was actually reported.
    ///
    /// A probed gateway or traceroute hop is recorded as a /24 around one
    /// address, because nothing told us the mask. When the router did tell us —
    /// a /22, say — the two are the same network and listing both would sweep
    /// the same addresses twice.
    ///
    /// Two limits keep this from destroying the answer. Only a *guessed* prefix
    /// may be folded away: a /24 the router itself reported is a real segment
    /// and stays on the list even when a wider route covers it. And nothing
    /// wider than `widestAbsorbingPrefix` may absorb, so a 10.0.0.0/8 summary
    /// cannot swallow every network at the site.
    static func consolidate(_ found: [IPv4Subnet: DiscoveredSubnet]) -> [DiscoveredSubnet] {
        // Widest first, so a container is always in `kept` before what it contains.
        let entries = found.values.sorted { $0.subnet.prefixLength < $1.subnet.prefixLength }
        var kept: [DiscoveredSubnet] = []

        for entry in entries {
            let absorber = entry.prefixIsAssumed
                ? kept.firstIndex { candidate in
                    (widestAbsorbingPrefix..<entry.subnet.prefixLength)
                        .contains(candidate.subnet.prefixLength)
                        && candidate.subnet.contains(entry.subnet.network)
                }
                : nil

            guard let index = absorber else {
                kept.append(entry)
                continue
            }
            kept[index].sources.formUnion(entry.sources)
            kept[index].router = kept[index].router ?? entry.router
            kept[index].isLocal = kept[index].isLocal || entry.isLocal
        }
        return sortedList(kept)
    }

    /// Pings candidates, keeping the ones that answer.
    ///
    /// One round, short timeout: a router either answers immediately or is not
    /// there, and at this scale a second round would double a sweep already
    /// measured in minutes.
    private static func ping(_ candidates: [IPv4]) async -> [IPv4] {
        guard !candidates.isEmpty else { return [] }
        let replies = (try? await ICMPSweeper().sweep(targets: candidates,
                                                      rounds: 1,
                                                      timeout: 1.5)) ?? [:]
        return Array(replies.keys)
    }

    /// Pings, then knocks over TCP on whatever stayed silent.
    ///
    /// Only for short lists: knocking on every address of a stepped sweep would
    /// be hundreds of thousands of connections for a handful of extra hits, and
    /// would outlast the sweep itself many times over.
    private static func probe(_ candidates: [IPv4]) async -> [IPv4] {
        guard !candidates.isEmpty else { return [] }
        var reachable = Set(await ping(candidates))

        let silent = candidates.filter { !reachable.contains($0) }
        guard !silent.isEmpty else { return reachable.sorted() }

        await withTaskGroup(of: IPv4?.self) { group in
            for candidate in silent {
                group.addTask {
                    for port: UInt16 in [80, 443, 53] {
                        let outcome = await TCPProbe.connect(to: candidate, port: port, timeout: 0.6)
                        if outcome == .open || outcome == .refused { return candidate }
                    }
                    return nil
                }
            }
            for await result in group {
                if let result { reachable.insert(result) }
            }
        }
        return reachable.sorted()
    }

    private static func sorted(_ found: [IPv4Subnet: DiscoveredSubnet]) -> [DiscoveredSubnet] {
        sortedList(Array(found.values))
    }

    private static func sortedList(_ entries: [DiscoveredSubnet]) -> [DiscoveredSubnet] {
        entries.sorted { lhs, rhs in
            if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
            if lhs.primarySource.rank != rhs.primarySource.rank {
                return lhs.primarySource.rank < rhs.primarySource.rank
            }
            return lhs.subnet.network < rhs.subnet.network
        }
    }
}
