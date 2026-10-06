//
//  SystemLimits.swift
//  AssetOnBoard
//
//  Raises the process file-descriptor ceiling so the scanner can widen its fan-out.
//
//  A subnet scan is almost entirely blocked on sockets waiting to time out, so
//  throughput is bounded by how many can be open at once. iOS starts an app at
//  256 descriptors, which caps useful concurrency at a few dozen connections and
//  turns a busy /23 into a multi-minute scan. Raising the soft limit toward the
//  kernel's per-process maximum is the supported way to lift that ceiling.
//

import Foundation
import Darwin

nonisolated enum SystemLimits {

    /// `RLIM_INFINITY` is not vended by the iOS SDK; it is `2^63 - 1` on Darwin.
    private static let unlimited = rlim_t(bitPattern: Int64.max)

    /// Descriptors available to this process after `raiseFileDescriptorLimit()`.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedLimit = 256

    static var fileDescriptorLimit: Int {
        lock.withLock { cachedLimit }
    }

    /// Pushes `RLIMIT_NOFILE` as high as the kernel allows, returning the result.
    ///
    /// Safe to call more than once; each call re-reads the current limit.
    @discardableResult
    static func raiseFileDescriptorLimit() -> Int {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return fileDescriptorLimit }

        let ceiling: rlim_t = limits.rlim_max == unlimited ? 16_384 : limits.rlim_max
        // Walk down until the kernel accepts one; hard caps vary by OS version.
        for candidate in [rlim_t(16_384), 8_192, 4_096, 2_048, 1_024] {
            let target = min(candidate, ceiling)
            guard target > limits.rlim_cur else { continue }
            var attempt = limits
            attempt.rlim_cur = target
            if setrlimit(RLIMIT_NOFILE, &attempt) == 0 {
                lock.withLock { cachedLimit = Int(target) }
                return Int(target)
            }
        }

        lock.withLock { cachedLimit = Int(limits.rlim_cur) }
        return Int(limits.rlim_cur)
    }

    /// Concurrent socket budget, leaving generous headroom for the rest of the app.
    ///
    /// Network.framework needs more than one descriptor per connection, so this
    /// divides rather than subtracts.
    static func socketBudget(preferred: Int) -> Int {
        max(16, min(preferred, fileDescriptorLimit / 8))
    }
}
