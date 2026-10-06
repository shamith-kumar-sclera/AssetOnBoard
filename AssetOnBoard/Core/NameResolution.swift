//
//  NameResolution.swift
//  AssetOnBoard
//
//  Reverse DNS lookups.
//
//  mDNSResponder answers in-addr.arpa queries for the local subnet, so this one
//  call recovers `.local` names for Macs, Linux boxes and most IoT devices as
//  well as anything the router's DNS knows about.
//

import Foundation
import Darwin

nonisolated enum NameResolution {

    private static let queue = DispatchQueue(label: "com.sclera.assetonboard.dns",
                                             qos: .utility,
                                             attributes: .concurrent)

    /// Resolves `address` to a hostname, or nil when nothing answers in time.
    static func reverseLookup(_ address: IPv4, timeout: TimeInterval = 2.0) async -> String? {
        await withCheckedContinuation { continuation in
            let box = LookupBox(continuation)

            queue.async {
                var storage = address.socketAddress
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = withUnsafePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        getnameinfo(sockaddrPointer,
                                    socklen_t(MemoryLayout<sockaddr_in>.size),
                                    &buffer, socklen_t(buffer.count),
                                    nil, 0,
                                    NI_NAMEREQD)
                    }
                }
                guard status == 0 else { return box.finish(nil) }
                let name = String(cString: buffer)
                // getnameinfo echoes the literal when it has nothing better.
                box.finish(name == address.description ? nil : Self.tidy(name))
            }

            queue.asyncAfter(deadline: .now() + timeout) { box.finish(nil) }
        }
    }

    /// Strips the trailing dot and the `.local` suffix for display.
    static func tidy(_ hostname: String) -> String {
        var name = hostname
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// The bare device name, without any DNS domain.
    static func shortName(_ hostname: String) -> String {
        tidy(hostname).split(separator: ".").first.map(String.init) ?? hostname
    }
}

nonisolated private final class LookupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func finish(_ value: String?) {
        let pending = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
