//
//  TLSCertificateInfo.swift
//  AssetOnBoard
//
//  Certificate details pulled from a device's TLS handshake.
//
//  Security.framework on iOS only exposes the subject summary and serial, so the
//  issuer, validity window and SANs come from a small DER walk over the raw
//  certificate. Those fields identify hardware unusually well — self-signed certs
//  on NAS boxes, routers and printers routinely carry the model in the CN.
//

import Foundation
import Security

nonisolated struct TLSCertificateInfo: Sendable, Hashable, Codable {
    var subjectCommonName: String?
    var subjectOrganization: String?
    var subjectSummary: String?
    var issuerCommonName: String?
    var issuerOrganization: String?
    var serialNumber: String?
    var notBefore: Date?
    var notAfter: Date?
    var subjectAlternativeNames: [String]
    var isSelfSigned: Bool

    var isExpired: Bool {
        guard let notAfter else { return false }
        return notAfter < Date()
    }

    /// The most human-meaningful label available for this certificate.
    var displayName: String? {
        subjectCommonName ?? subjectSummary ?? subjectOrganization ?? subjectAlternativeNames.first
    }

    init?(certificate: SecCertificate) {
        let der = [UInt8](SecCertificateCopyData(certificate) as Data)
        let parsed = DERCertificate(der: der)

        subjectSummary = SecCertificateCopySubjectSummary(certificate) as String?
        var commonName: CFString?
        if SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess {
            subjectCommonName = commonName as String?
        }
        subjectCommonName = subjectCommonName ?? parsed?.subject["CN"]
        subjectOrganization = parsed?.subject["O"]
        issuerCommonName = parsed?.issuer["CN"]
        issuerOrganization = parsed?.issuer["O"]
        notBefore = parsed?.notBefore
        notAfter = parsed?.notAfter
        subjectAlternativeNames = parsed?.subjectAlternativeNames ?? []

        if let serial = SecCertificateCopySerialNumberData(certificate, nil) as Data? {
            serialNumber = serial.map { String(format: "%02x", $0) }.joined()
        }
        isSelfSigned = parsed.map { $0.subject == $0.issuer && !$0.subject.isEmpty } ?? false

        if subjectCommonName == nil && subjectSummary == nil && subjectAlternativeNames.isEmpty {
            return nil
        }
    }
}

// MARK: - Minimal DER reader

nonisolated private struct DERElement {
    let tag: UInt8
    let contents: ArraySlice<UInt8>
}

nonisolated private enum DER {
    /// Splits one level of TLV elements, ignoring anything malformed.
    static func elements(in bytes: ArraySlice<UInt8>) -> [DERElement] {
        var results: [DERElement] = []
        var index = bytes.startIndex

        while index < bytes.endIndex {
            let tag = bytes[index]
            var cursor = bytes.index(after: index)
            guard cursor < bytes.endIndex else { break }

            var length = 0
            let firstLengthByte = bytes[cursor]
            cursor = bytes.index(after: cursor)

            if firstLengthByte & 0x80 == 0 {
                length = Int(firstLengthByte)
            } else {
                let byteCount = Int(firstLengthByte & 0x7F)
                guard byteCount > 0, byteCount <= 4,
                      bytes.index(cursor, offsetBy: byteCount, limitedBy: bytes.endIndex) != nil
                else { break }
                for _ in 0..<byteCount {
                    length = length << 8 | Int(bytes[cursor])
                    cursor = bytes.index(after: cursor)
                }
            }

            guard let end = bytes.index(cursor, offsetBy: length, limitedBy: bytes.endIndex) else { break }
            results.append(DERElement(tag: tag, contents: bytes[cursor..<end]))
            index = end
        }
        return results
    }

    static func string(_ bytes: ArraySlice<UInt8>) -> String? {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
    }

    /// Parses UTCTime (`YYMMDDHHMMSSZ`) and GeneralizedTime (`YYYYMMDDHHMMSSZ`).
    static func date(tag: UInt8, contents: ArraySlice<UInt8>) -> Date? {
        guard let text = string(contents) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = tag == 0x17 ? "yyMMddHHmmssZ" : "yyyyMMddHHmmssZ"
        return formatter.date(from: text)
    }
}

nonisolated private struct DERCertificate {
    var subject: [String: String] = [:]
    var issuer: [String: String] = [:]
    var notBefore: Date?
    var notAfter: Date?
    var subjectAlternativeNames: [String] = []

    private static let attributeOIDs: [[UInt8]: String] = [
        [0x55, 0x04, 0x03]: "CN",
        [0x55, 0x04, 0x06]: "C",
        [0x55, 0x04, 0x07]: "L",
        [0x55, 0x04, 0x08]: "ST",
        [0x55, 0x04, 0x0A]: "O",
        [0x55, 0x04, 0x0B]: "OU"
    ]
    private static let subjectAltNameOID: [UInt8] = [0x55, 0x1D, 0x11]

    init?(der: [UInt8]) {
        guard let certificate = DER.elements(in: der[...]).first,
              let tbs = DER.elements(in: certificate.contents).first
        else { return nil }

        var fields = DER.elements(in: tbs.contents)
        // An explicit [0] version tag shifts every following field along by one.
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        guard fields.count >= 6 else { return nil }

        issuer = Self.name(from: fields[2])
        subject = Self.name(from: fields[4])

        let validity = DER.elements(in: fields[3].contents)
        if validity.count >= 2 {
            notBefore = DER.date(tag: validity[0].tag, contents: validity[0].contents)
            notAfter = DER.date(tag: validity[1].tag, contents: validity[1].contents)
        }

        if let extensionsTag = fields.first(where: { $0.tag == 0xA3 }) {
            subjectAlternativeNames = Self.subjectAltNames(in: extensionsTag)
        }
    }

    private static func name(from element: DERElement) -> [String: String] {
        var result: [String: String] = [:]
        for relativeName in DER.elements(in: element.contents) {
            for pair in DER.elements(in: relativeName.contents) {
                let parts = DER.elements(in: pair.contents)
                guard parts.count >= 2,
                      let key = attributeOIDs[Array(parts[0].contents)],
                      let value = DER.string(parts[1].contents)
                else { continue }
                // Keep the first occurrence; certificates may repeat an attribute.
                if result[key] == nil { result[key] = value }
            }
        }
        return result
    }

    private static func subjectAltNames(in extensionsTag: DERElement) -> [String] {
        guard let sequence = DER.elements(in: extensionsTag.contents).first else { return [] }
        for extensionElement in DER.elements(in: sequence.contents) {
            let parts = DER.elements(in: extensionElement.contents)
            guard let oid = parts.first, Array(oid.contents) == subjectAltNameOID,
                  let octetString = parts.last,
                  let generalNames = DER.elements(in: octetString.contents).first
            else { continue }

            return DER.elements(in: generalNames.contents).compactMap { entry in
                switch entry.tag {
                case 0x82:  // dNSName
                    return DER.string(entry.contents)
                case 0x87:  // iPAddress
                    let octets = Array(entry.contents)
                    return octets.count == 4 ? octets.map(String.init).joined(separator: ".") : nil
                default:
                    return nil
                }
            }
        }
        return []
    }
}
