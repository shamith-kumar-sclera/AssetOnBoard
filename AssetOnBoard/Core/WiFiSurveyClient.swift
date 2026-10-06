//
//  WiFiSurveyClient.swift
//  AssetOnBoard
//
//  Reads a Wi-Fi survey from the aobscand helper running on a Mac.
//
//  This is the app's answer to the one thing iOS will not do. Listing the
//  networks in range needs NEHotspotHelper, an entitlement Apple issues only to
//  captive-network vendors, and no amount of code works around that. macOS has
//  no such restriction — CoreWLAN scans freely — so the survey is performed
//  there and fetched from here.
//
//  The helper is found over Bonjour rather than configured, so there is no
//  address to type and it keeps working when the Mac's IP changes.
//

import Foundation
import Network
import Observation

@Observable
final class WiFiSurveyClient {

    enum State: Equatable {
        case idle
        case searching
        case ready(host: String)
        case noHelper
        case failed(String)

        var message: String {
            switch self {
            case .idle: "Not looking yet"
            case .searching: "Looking for a survey helper on this network…"
            case .ready(let host): "Surveyed by \(host)"
            case .noHelper:
                "Nothing on this network is publishing a survey yet. This is not a permissions problem — the app browsed and nothing answered. Start the helper on a Mac and it appears here within seconds."
            case .failed(let reason): reason
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var survey: WiFiSurvey?
    private(set) var lastUpdated: Date?

    var isBusy: Bool { state == .searching }

    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private let queue = DispatchQueue(label: "com.sclera.assetonboard.survey")

    // MARK: - Public entry point

    /// Finds the helper if needed, then fetches a fresh survey.
    func refresh() async {
        state = .searching

        if endpoint == nil {
            endpoint = await discover(timeout: 4)
        }
        guard let endpoint else {
            state = .noHelper
            return
        }

        guard let data = await fetch(from: endpoint, timeout: 8) else {
            // The helper may have moved or stopped; forget it and let the next
            // refresh look again rather than failing forever on a stale endpoint.
            self.endpoint = nil
            state = .failed("The survey helper stopped answering. Check it is still running.")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode(WiFiSurvey.self, from: data)
            survey = decoded
            lastUpdated = Date()
            state = .ready(host: decoded.hostName)
        } catch {
            state = .failed("The helper sent something this app could not read.")
        }
    }

    func reset() {
        browser?.cancel()
        browser = nil
        endpoint = nil
        survey = nil
        lastUpdated = nil
        state = .idle
    }

    // MARK: - Bonjour discovery

    /// Browses for `_aobscan._tcp` and returns the first helper that appears.
    private func discover(timeout: TimeInterval) async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let resumer = OnceBox(continuation)
            let descriptor = NWBrowser.Descriptor.bonjour(type: "_aobscan._tcp", domain: nil)
            let browser = NWBrowser(for: descriptor, using: .tcp)
            self.browser = browser

            browser.browseResultsChangedHandler = { results, _ in
                guard let first = results.first else { return }
                resumer.finish(first.endpoint)
                browser.cancel()
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { resumer.finish(nil); browser.cancel() }
            }
            browser.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                resumer.finish(nil)
                browser.cancel()
            }
        }
    }

    // MARK: - Fetch

    /// Issues `GET /survey` and returns the response body.
    ///
    /// The helper closes the connection when it is done, so the body is whatever
    /// arrived by the time the stream ends — no need to honour Content-Length.
    private func fetch(from endpoint: NWEndpoint, timeout: TimeInterval) async -> Data? {
        let request = Data("""
        GET /survey HTTP/1.1\r
        Host: aobscand\r
        User-Agent: AssetOnBoard/1.0\r
        Accept: application/json\r
        Connection: close\r
        \r
        
        """.utf8)

        return await withCheckedContinuation { continuation in
            let resumer = OnceBox(continuation)
            let connection = NWConnection(to: endpoint, using: .tcp)
            let buffer = ByteBox()

            func readMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { chunk, _, isComplete, error in
                    if let chunk, !chunk.isEmpty { buffer.append(chunk) }
                    if isComplete || error != nil {
                        resumer.finish(Self.httpBody(of: buffer.value))
                        connection.cancel()
                    } else {
                        readMore()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .idempotent)
                    readMore()
                case .failed, .cancelled:
                    resumer.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                resumer.finish(Self.httpBody(of: buffer.value))
                connection.cancel()
            }
        }
    }

    /// Splits an HTTP response at the header/body boundary.
    private static func httpBody(of data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let body = data[range.upperBound...]
        return body.isEmpty ? nil : Data(body)
    }
}

// MARK: - Callback plumbing

/// Resumes a continuation exactly once, whichever callback gets there first.
nonisolated private final class OnceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func finish(_ value: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Accumulates bytes across Network.framework's callback queue.
nonisolated private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.withLock { storage.append(data) } }
    var value: Data { lock.withLock { storage } }
}
