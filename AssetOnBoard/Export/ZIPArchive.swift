//
//  ZIPArchive.swift
//  AssetOnBoard
//
//  Minimal ZIP writer, used to assemble .xlsx files.
//
//  An xlsx is just a ZIP of XML parts, and the project carries no third-party
//  dependencies, so this writes the container directly. Entries are deflated
//  with Apple's Compression framework — `COMPRESSION_ZLIB` emits raw DEFLATE,
//  which is exactly what ZIP method 8 expects — and fall back to stored when
//  compression would not help.
//

import Foundation
import Compression

nonisolated struct ZIPArchive {

    private struct Entry {
        let path: String
        let data: Data
        let crc32: UInt32
        let compressed: Data
        let method: UInt16      // 0 = stored, 8 = deflate
        var localHeaderOffset: UInt32 = 0
    }

    private var entries: [Entry] = []

    mutating func addFile(path: String, contents: Data) {
        let checksum = CRC32.checksum(contents)
        if let deflated = Self.deflate(contents), deflated.count < contents.count {
            entries.append(Entry(path: path, data: contents, crc32: checksum,
                                 compressed: deflated, method: 8))
        } else {
            entries.append(Entry(path: path, data: contents, crc32: checksum,
                                 compressed: contents, method: 0))
        }
    }

    mutating func addFile(path: String, string: String) {
        addFile(path: path, contents: Data(string.utf8))
    }

    /// Serialises local headers, file data, the central directory and the EOCD.
    func data() -> Data {
        var output = Data()
        var placed: [Entry] = []

        for var entry in entries {
            entry.localHeaderOffset = UInt32(output.count)
            output.append(localHeader(for: entry))
            output.append(entry.compressed)
            placed.append(entry)
        }

        let centralDirectoryOffset = UInt32(output.count)
        for entry in placed {
            output.append(centralDirectoryHeader(for: entry))
        }
        let centralDirectorySize = UInt32(output.count) - centralDirectoryOffset

        output.append(UInt32(0x0605_4B50).littleEndianData)   // EOCD signature
        output.append(UInt16(0).littleEndianData)             // this disk
        output.append(UInt16(0).littleEndianData)             // disk with central directory
        output.append(UInt16(placed.count).littleEndianData)
        output.append(UInt16(placed.count).littleEndianData)
        output.append(centralDirectorySize.littleEndianData)
        output.append(centralDirectoryOffset.littleEndianData)
        output.append(UInt16(0).littleEndianData)             // comment length
        return output
    }

    // MARK: - Headers

    private func localHeader(for entry: Entry) -> Data {
        var header = Data()
        let name = Data(entry.path.utf8)
        header.append(UInt32(0x0403_4B50).littleEndianData)
        header.append(UInt16(20).littleEndianData)            // version needed
        header.append(UInt16(0).littleEndianData)             // flags
        header.append(entry.method.littleEndianData)
        header.append(UInt16(0).littleEndianData)             // mod time
        header.append(UInt16(0x21).littleEndianData)          // mod date (1980-01-01)
        header.append(entry.crc32.littleEndianData)
        header.append(UInt32(entry.compressed.count).littleEndianData)
        header.append(UInt32(entry.data.count).littleEndianData)
        header.append(UInt16(name.count).littleEndianData)
        header.append(UInt16(0).littleEndianData)             // extra field length
        header.append(name)
        return header
    }

    private func centralDirectoryHeader(for entry: Entry) -> Data {
        var header = Data()
        let name = Data(entry.path.utf8)
        header.append(UInt32(0x0201_4B50).littleEndianData)
        header.append(UInt16(20).littleEndianData)            // version made by
        header.append(UInt16(20).littleEndianData)            // version needed
        header.append(UInt16(0).littleEndianData)             // flags
        header.append(entry.method.littleEndianData)
        header.append(UInt16(0).littleEndianData)             // mod time
        header.append(UInt16(0x21).littleEndianData)          // mod date
        header.append(entry.crc32.littleEndianData)
        header.append(UInt32(entry.compressed.count).littleEndianData)
        header.append(UInt32(entry.data.count).littleEndianData)
        header.append(UInt16(name.count).littleEndianData)
        header.append(UInt16(0).littleEndianData)             // extra field length
        header.append(UInt16(0).littleEndianData)             // comment length
        header.append(UInt16(0).littleEndianData)             // disk number start
        header.append(UInt16(0).littleEndianData)             // internal attributes
        header.append(UInt32(0).littleEndianData)             // external attributes
        header.append(entry.localHeaderOffset.littleEndianData)
        header.append(name)
        return header
    }

    // MARK: - Compression

    private static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + 64
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = input.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity,
                                             base, input.count,
                                             nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }
}

// MARK: - CRC32

nonisolated enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

nonisolated private extension UInt16 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

nonisolated private extension UInt32 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}
