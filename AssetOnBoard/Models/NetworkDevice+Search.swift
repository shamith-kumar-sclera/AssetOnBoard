//
//  NetworkDevice+Search.swift
//  AssetOnBoard
//

import Foundation

extension NetworkDevice {
    /// Matches the search box against every identifying string we hold.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }

        var haystack: [String] = [displayName, subtitle, ip.description, category.rawValue]
        haystack.append(contentsOf: hostnames)
        haystack.append(contentsOf: [vendor, modelName, modelIdentifier, operatingSystem].compactMap { $0 })
        haystack.append(contentsOf: [macAddress?.description].compactMap { $0 })
        haystack.append(contentsOf: bonjourServices.map(\.instanceName))
        haystack.append(contentsOf: bonjourServices.map(\.friendlyProtocolName))
        haystack.append(contentsOf: openPorts.map { "\($0.port) \($0.serviceName) \($0.summary)" })
        if let netbios {
            haystack.append(contentsOf: [netbios.computerName, netbios.workgroup].compactMap { $0 })
        }
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}

extension NetworkScanner {
    /// Builds an exportable report from the current results, even mid-scan.
    func currentReport(depth: ScanDepth) -> ScanReport? {
        guard let interfaceInfo, let subnet else { return nil }
        return ScanReport(startedAt: startedAt ?? Date(),
                          finishedAt: finishedAt ?? Date(),
                          interfaceName: interfaceInfo.name,
                          interfaceKind: interfaceInfo.kind.rawValue,
                          localAddress: interfaceInfo.address,
                          subnet: subnet.description,
                          gateway: gateway,
                          depth: depth.rawValue,
                          devices: sortedDevices)
    }
}
