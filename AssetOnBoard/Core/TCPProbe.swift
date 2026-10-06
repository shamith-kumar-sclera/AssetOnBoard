//
//  TCPProbe.swift
//  AssetOnBoard
//
//  TCP connect scanning and banner grabbing built on Network.framework.
//

import Foundation
import Network

nonisolated enum TCPOutcome: String, Sendable, Codable {
    /// Handshake completed — the port is listening.
    case open
    /// RST came back. The port is shut, but it proves the host is up.
    case refused
    /// No answer at all: firewalled, or nothing at this address.
    case filtered
    /// The network stack said the host is unreachable.
    case unreachable
}

nonisolated struct TCPExchange: Sendable {
    let outcome: TCPOutcome
    let data: Data
    let certificates: [TLSCertificateInfo]
    let tlsVersion: String?
    let cipherSuite: String?
    let elapsed: TimeInterval
}

/// Thread-safe box for values handed back from Network.framework callbacks.
nonisolated private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}

/// Guarantees a continuation is resumed exactly once, whichever callback wins.
nonisolated private final class SingleResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func resume(_ value: Value) {
        let pending: CheckedContinuation<Value, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

nonisolated enum TCPProbe {

    private static let queue = DispatchQueue(label: "com.sclera.assetonboard.tcp",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    // MARK: - Connect scan

    /// Opens a TCP connection just far enough to classify the port, then hangs up.
    static func connect(to host: IPv4,
                        port: UInt16,
                        timeout: TimeInterval = 1.5) async -> TCPOutcome {
        let started = Date()
        let connection = NWConnection(host: .ipv4(networkHost(host)),
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: parameters(tls: false, timeout: timeout))

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<TCPOutcome, Never>) in
            let resumer = SingleResume(continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumer.resume(.open)
                    connection.cancel()
                case .failed(let error):
                    resumer.resume(classify(error))
                    connection.cancel()
                case .waiting(let error):
                    // NWConnection parks in `.waiting` on RST and keeps retrying;
                    // for a scanner that answer is already final.
                    resumer.resume(classify(error))
                    connection.cancel()
                case .cancelled:
                    resumer.resume(.filtered)
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                resumer.resume(.filtered)
                connection.cancel()
            }
        }
        _ = started
        return outcome
    }

    // MARK: - Banner grab

    /// Connects, optionally sends `payload`, and reads whatever the service says.
    ///
    /// Most plaintext services (SSH, FTP, SMTP, RTSP) announce themselves without
    /// being asked; HTTP needs a nudge, which is what `payload` is for.
    static func exchange(with host: IPv4,
                         port: UInt16,
                         useTLS: Bool = false,
                         serverName: String? = nil,
                         payload: Data? = nil,
                         maxBytes: Int = 16 * 1024,
                         connectTimeout: TimeInterval = 2.0,
                         readTimeout: TimeInterval = 2.5) async -> TCPExchange {
        let started = Date()
        let certificates = Box<[TLSCertificateInfo]>([])
        let tlsDetails = Box<(version: String?, cipher: String?)>((nil, nil))

        let connection = NWConnection(
            host: .ipv4(networkHost(host)),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters(tls: useTLS,
                              timeout: connectTimeout,
                              serverName: serverName,
                              certificateSink: certificates,
                              tlsDetailSink: tlsDetails)
        )

        // Phase 1: establish.
        let connected = await withCheckedContinuation { (continuation: CheckedContinuation<TCPOutcome, Never>) in
            let resumer = SingleResume(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resumer.resume(.open)
                case .failed(let error): resumer.resume(classify(error))
                case .waiting(let error): resumer.resume(classify(error)); connection.cancel()
                case .cancelled: resumer.resume(.filtered)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + connectTimeout) {
                resumer.resume(.filtered)
                connection.cancel()
            }
        }

        guard connected == .open else {
            connection.cancel()
            return TCPExchange(outcome: connected, data: Data(), certificates: certificates.value,
                               tlsVersion: nil, cipherSuite: nil,
                               elapsed: Date().timeIntervalSince(started))
        }

        // Phase 2: talk.
        if let payload {
            connection.send(content: payload, completion: .idempotent)
        }
        let received = await read(from: connection, maxBytes: maxBytes, timeout: readTimeout)
        connection.cancel()

        let details = tlsDetails.value
        return TCPExchange(outcome: .open,
                           data: received,
                           certificates: certificates.value,
                           tlsVersion: details.version,
                           cipherSuite: details.cipher,
                           elapsed: Date().timeIntervalSince(started))
    }

    private static func read(from connection: NWConnection,
                             maxBytes: Int,
                             timeout: TimeInterval) async -> Data {
        let buffer = Box(Data())
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline, buffer.value.count < maxBytes {
            let remaining = maxBytes - buffer.value.count
            let chunk = await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, Bool), Never>) in
                let resumer = SingleResume(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    resumer.resume((data, isComplete || error != nil))
                }
                queue.asyncAfter(deadline: .now() + max(0.2, deadline.timeIntervalSinceNow)) {
                    resumer.resume((nil, true))
                }
            }
            if let data = chunk.0, !data.isEmpty { buffer.mutate { $0.append(data) } }
            if chunk.1 { break }
        }
        return buffer.value
    }

    // MARK: - Plumbing

    private static func networkHost(_ address: IPv4) -> IPv4Address {
        IPv4Address(address.description) ?? IPv4Address.any
    }

    private static func classify(_ error: NWError) -> TCPOutcome {
        guard case .posix(let code) = error else { return .filtered }
        switch code {
        case .ECONNREFUSED: return .refused
        case .EHOSTDOWN, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN: return .unreachable
        default: return .filtered
        }
    }

    private static func parameters(tls: Bool,
                                   timeout: TimeInterval,
                                   serverName: String? = nil,
                                   certificateSink: Box<[TLSCertificateInfo]>? = nil,
                                   tlsDetailSink: Box<(version: String?, cipher: String?)>? = nil) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcpOptions.connectionDropTime = 1
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = false

        var tlsOptions: NWProtocolTLS.Options?
        if tls {
            let options = NWProtocolTLS.Options()
            if let serverName {
                sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, serverName)
            }
            // Reach ageing routers and printers that never moved past TLS 1.0.
            // Spelled as a raw version so the deprecated constant is not needed;
            // inventorying weak TLS is the point here, not a mistake.
            if let legacyMinimum = tls_protocol_version_t(rawValue: 0x0301) {
                sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, legacyMinimum)
            }
            // A scanner is inventorying certificates, not trusting them: accept
            // whatever the device presents so self-signed IoT gear still reports.
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { metadata, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] {
                    certificateSink?.value = chain.compactMap(TLSCertificateInfo.init(certificate:))
                }
                tlsDetailSink?.value = (
                    describe(version: sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata)),
                    describe(cipher: sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata))
                )
                complete(true)
            }, queue)
            tlsOptions = options
        }

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        // Keep probes on the local link; never bill a scan to the cellular plan.
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.preferNoProxies = true
        parameters.serviceClass = .responsiveData
        return parameters
    }

    private static func describe(version: tls_protocol_version_t) -> String? {
        switch version {
        case .TLSv10: "TLS 1.0"
        case .TLSv11: "TLS 1.1"
        case .TLSv12: "TLS 1.2"
        case .TLSv13: "TLS 1.3"
        case .DTLSv10: "DTLS 1.0"
        case .DTLSv12: "DTLS 1.2"
        default: nil
        }
    }

    private static func describe(cipher: tls_ciphersuite_t) -> String? {
        switch cipher {
        case .AES_128_GCM_SHA256: "TLS_AES_128_GCM_SHA256"
        case .AES_256_GCM_SHA384: "TLS_AES_256_GCM_SHA384"
        case .CHACHA20_POLY1305_SHA256: "TLS_CHACHA20_POLY1305_SHA256"
        case .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256: "ECDHE_ECDSA_AES_128_GCM_SHA256"
        case .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384: "ECDHE_ECDSA_AES_256_GCM_SHA384"
        case .ECDHE_RSA_WITH_AES_128_GCM_SHA256: "ECDHE_RSA_AES_128_GCM_SHA256"
        case .ECDHE_RSA_WITH_AES_256_GCM_SHA384: "ECDHE_RSA_AES_256_GCM_SHA384"
        case .RSA_WITH_AES_128_GCM_SHA256: "RSA_AES_128_GCM_SHA256"
        case .RSA_WITH_AES_256_GCM_SHA384: "RSA_AES_256_GCM_SHA384"
        default: String(format: "0x%04X", cipher.rawValue)
        }
    }
}
