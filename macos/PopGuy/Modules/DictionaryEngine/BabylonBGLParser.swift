// BabylonBGLParser.swift
// PopGuy — DictionaryEngine
//
// Native reader for the Babylon .bgl container format.
//
// BGL files are reverse-engineered binary dictionaries. PopGuy supports the
// common entry block shapes used by Babylon glossary files and keeps the output
// as readable plain text. File contents are untrusted: sizes and offsets are
// validated before allocation.

import Compression
import Foundation

// MARK: - BabylonBGLParser

nonisolated struct BabylonBGLParser: Sendable {
    private static let headerMagicV1: [UInt8] = [0x12, 0x34, 0x00, 0x01]
    private static let headerMagicV2: [UInt8] = [0x12, 0x34, 0x00, 0x02]
    private static let maxCompressedBytes = 200 * 1024 * 1024
    private static let maxUncompressedBytes = 512 * 1024 * 1024
    private static let maxBlockBytes = 16 * 1024 * 1024

    func parseFile(url: URL, dictionary: BabylonDictionary) throws -> BabylonBGLIndex {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maxCompressedBytes {
            throw DictionaryLookupError.decoding("BGL file is too large to index.")
        }

        let data = try Data(contentsOf: url)
        return try parse(data: data, dictionary: dictionary)
    }

    func parse(data: Data, dictionary: BabylonDictionary) throws -> BabylonBGLIndex {
        let bytes = [UInt8](data)
        guard bytes.count >= 18 else {
            throw DictionaryLookupError.decoding("BGL file is too short.")
        }
        let magic = Array(bytes.prefix(4))
        guard magic == Self.headerMagicV1 || magic == Self.headerMagicV2 else {
            throw DictionaryLookupError.decoding("Invalid BGL header.")
        }

        let gzipOffset = Int(Self.uintBigEndian(bytes[4...5]))
        guard gzipOffset >= 6, gzipOffset < bytes.count else {
            throw DictionaryLookupError.decoding("Invalid BGL gzip offset.")
        }

        let decompressed = try inflateGzipMember(Array(bytes[gzipOffset...]))
        return try parseUncompressedBlocks(decompressed, dictionary: dictionary)
    }

    func parseUncompressedBlocks(_ data: Data, dictionary: BabylonDictionary) throws -> BabylonBGLIndex {
        try parseUncompressedBlocks([UInt8](data), dictionary: dictionary)
    }

    func parseUncompressedBlocks(_ bytes: [UInt8], dictionary: BabylonDictionary) throws -> BabylonBGLIndex {
        var cursor = 0
        var entries: [BabylonBGLEntry] = []

        while cursor < bytes.count {
            guard let block = try readBlock(from: bytes, cursor: &cursor) else { break }
            guard !block.payload.isEmpty else { continue }

            switch block.type {
            case 1, 7, 10, 13:
                if let entry = try parseShortEntryBlock(block.payload) {
                    entries.append(entry)
                }
            case 11:
                if let entry = try parseLongEntryBlock(block.payload) {
                    entries.append(entry)
                }
            default:
                continue
            }
        }

        return BabylonBGLIndex(dictionary: dictionary, entries: entries)
    }

    // MARK: - Gzip

    private func inflateGzipMember(_ bytes: [UInt8]) throws -> Data {
        guard bytes.count >= 18,
              bytes[0] == 0x1f,
              bytes[1] == 0x8b,
              bytes[2] == 0x08 else {
            throw DictionaryLookupError.decoding("BGL payload is not a gzip deflate stream.")
        }

        let flags = bytes[3]
        var cursor = 10

        if flags & 0x04 != 0 {
            guard cursor + 2 <= bytes.count else { throw DictionaryLookupError.decoding("Invalid gzip extra field.") }
            let extraLength = Int(Self.uintLittleEndian(bytes[cursor..<(cursor + 2)]))
            cursor += 2 + extraLength
        }

        if flags & 0x08 != 0 {
            cursor = try skipNullTerminatedField(in: bytes, from: cursor)
        }

        if flags & 0x10 != 0 {
            cursor = try skipNullTerminatedField(in: bytes, from: cursor)
        }

        if flags & 0x02 != 0 {
            cursor += 2
        }

        let trailerStart = bytes.count - 8
        guard cursor >= 10, cursor < trailerStart else {
            throw DictionaryLookupError.decoding("Invalid gzip member layout.")
        }

        let expectedSize = Int(Self.uintLittleEndian(bytes[(trailerStart + 4)..<(trailerStart + 8)]))
        guard expectedSize <= Self.maxUncompressedBytes else {
            throw DictionaryLookupError.decoding("BGL index is too large to load.")
        }

        let compressed = Array(bytes[cursor..<trailerStart])
        return try inflateRawDeflate(compressed, expectedSize: expectedSize)
    }

    private func skipNullTerminatedField(in bytes: [UInt8], from start: Int) throws -> Int {
        var cursor = start
        while cursor < bytes.count {
            if bytes[cursor] == 0 { return cursor + 1 }
            cursor += 1
        }
        throw DictionaryLookupError.decoding("Invalid gzip string field.")
    }

    private func inflateRawDeflate(_ compressed: [UInt8], expectedSize: Int) throws -> Data {
        var capacity = max(expectedSize, compressed.count * 4, 1024)
        if capacity == 0 { capacity = 1024 }

        while capacity <= Self.maxUncompressedBytes {
            let decoded = [UInt8](unsafeUninitializedCapacity: capacity) { outputBuffer, decodedCount in
                decodedCount = compression_decode_buffer(
                    outputBuffer.baseAddress!,
                    capacity,
                    compressed,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            if !decoded.isEmpty {
                return Data(decoded)
            }
            capacity *= 2
        }

        throw DictionaryLookupError.decoding("Could not decompress BGL data.")
    }

    // MARK: - Blocks

    private struct Block {
        let type: Int
        let payload: [UInt8]
    }

    private func readBlock(from bytes: [UInt8], cursor: inout Int) throws -> Block? {
        guard cursor < bytes.count else { return nil }
        let header = bytes[cursor]
        cursor += 1

        let type = Int(header & 0x0f)
        let lengthMarker = Int(header >> 4)
        let length: Int
        if lengthMarker < 4 {
            length = try readUInt(from: bytes, cursor: &cursor, width: lengthMarker + 1)
        } else {
            length = lengthMarker - 4
        }

        guard length >= 0, length <= Self.maxBlockBytes else {
            throw DictionaryLookupError.decoding("BGL block is too large.")
        }
        guard cursor + length <= bytes.count else {
            throw DictionaryLookupError.decoding("BGL block length exceeds stream size.")
        }

        let payload = Array(bytes[cursor..<(cursor + length)])
        cursor += length
        return Block(type: type, payload: payload)
    }

    private func parseShortEntryBlock(_ bytes: [UInt8]) throws -> BabylonBGLEntry? {
        var cursor = 0
        let wordBytes = try readLengthPrefixedBytes(from: bytes, cursor: &cursor, width: 1)
        let definitionBytes = try readLengthPrefixedBytes(from: bytes, cursor: &cursor, width: 2)
        var alternates: [String] = []
        while cursor < bytes.count {
            let alternateBytes = try readLengthPrefixedBytes(from: bytes, cursor: &cursor, width: 1)
            let alternate = decodeText(alternateBytes).trimmingCharacters(in: .whitespacesAndNewlines)
            if !alternate.isEmpty { alternates.append(alternate) }
        }
        return makeEntry(wordBytes: wordBytes, definitionBytes: definitionBytes, alternates: alternates)
    }

    private func parseLongEntryBlock(_ bytes: [UInt8]) throws -> BabylonBGLEntry? {
        var cursor = 0
        let wordBytes = try readLengthPrefixedBytes(from: bytes, cursor: &cursor, width: 5)
        let alternateCount = try readUInt(from: bytes, cursor: &cursor, width: 4)
        var alternates: [String] = []
        for _ in 0..<alternateCount {
            let alternateBytes = try readLengthPrefixedBytes(from: bytes, cursor: &cursor, width: 4)
            guard !alternateBytes.isEmpty else { break }
            let alternate = decodeText(alternateBytes).trimmingCharacters(in: .whitespacesAndNewlines)
            if !alternate.isEmpty { alternates.append(alternate) }
        }
        let definitionBytes = try readLengthPrefixedBytes(from: bytes, cursor: &cursor, width: 4)
        return makeEntry(wordBytes: wordBytes, definitionBytes: definitionBytes, alternates: alternates)
    }

    private func makeEntry(
        wordBytes: [UInt8],
        definitionBytes: [UInt8],
        alternates: [String]
    ) -> BabylonBGLEntry? {
        let headword = decodeText(wordBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headword.isEmpty else { return nil }

        let cleanDefinition = cleanDefinitionText(definitionBytes)
        guard !cleanDefinition.isEmpty else { return nil }

        let dedupedAlternates = Array(Set(alternates.filter { $0 != headword })).sorted()
        return BabylonBGLEntry(headword: headword, definition: cleanDefinition, alternates: dedupedAlternates)
    }

    // MARK: - Text

    private func cleanDefinitionText(_ bytes: [UInt8]) -> String {
        let mainBytes: [UInt8]
        if let fieldsStart = definitionFieldsStart(in: bytes) {
            mainBytes = Array(bytes[..<fieldsStart])
        } else {
            mainBytes = bytes
        }

        var text = decodeText(mainBytes)
        text = replacingHTMLLayout(in: text)
        text = strippingHTMLTags(from: text)
        text = decodingCommonEntities(in: text)
        text = removingBabylonPresentationArtifacts(from: text)
        text = separatingInlinePhonetics(in: text)
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func definitionFieldsStart(in bytes: [UInt8]) -> Int? {
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x14, bytes[index + 1] != 0x20 {
                return index
            }
            index += 1
        }
        return nil
    }

    private func decodeText(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let cp1252 = String(data: data, encoding: .windowsCP1252) {
            return cp1252
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func replacingHTMLLayout(in input: String) -> String {
        var text = input
        let regexReplacements: [(String, String)] = [
            (#"<br\s*/?>"#, "\n"),
            (#"<(table|tr|td|p|div|blockquote|dd|dt)[^>]*>"#, "\n"),
            (#"</(p|div|li|tr|td|table|blockquote|dd|dt)>"#, "\n"),
            (#"<li[^>]*>"#, "\n- "),
        ]
        for (pattern, replacement) in regexReplacements {
            text = text.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.caseInsensitive, .regularExpression]
            )
        }
        return text
    }

    private func strippingHTMLTags(from input: String) -> String {
        var text = input
        while let range = text.range(of: "<[^>]+>", options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }

    private func decodingCommonEntities(in input: String) -> String {
        input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private func removingBabylonPresentationArtifacts(from input: String) -> String {
        var text = input
        while let range = text.range(
            of: #"#[A-Za-z0-9_]+\{[^}]*\}"#,
            options: .regularExpression
        ) {
            text.removeSubrange(range)
        }

        return text
            .components(separatedBy: .newlines)
            .filter { !isBabylonPresentationArtifactLine($0) }
            .joined(separator: "\n")
    }

    private func isBabylonPresentationArtifactLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        return lowercased.hasPrefix("sound\\")
            || lowercased.hasPrefix("sound/")
            || lowercased.hasPrefix("sound ")
            || lowercased.hasPrefix("sound:")
    }

    private func separatingInlinePhonetics(in input: String) -> String {
        input.replacingOccurrences(
            of: #"(?m)^(\[[^\]\n]+\])\s*(\S)"#,
            with: "$1\n$2",
            options: .regularExpression
        )
    }

    // MARK: - Binary helpers

    private func readLengthPrefixedBytes(from bytes: [UInt8], cursor: inout Int, width: Int) throws -> [UInt8] {
        let length = try readUInt(from: bytes, cursor: &cursor, width: width)
        guard length >= 0, cursor + length <= bytes.count else {
            throw DictionaryLookupError.decoding("BGL entry length exceeds block size.")
        }
        let result = Array(bytes[cursor..<(cursor + length)])
        cursor += length
        return result
    }

    private func readUInt(from bytes: [UInt8], cursor: inout Int, width: Int) throws -> Int {
        guard width > 0, width <= 5, cursor + width <= bytes.count else {
            throw DictionaryLookupError.decoding("BGL integer exceeds stream size.")
        }
        let value = Int(Self.uintBigEndian(bytes[cursor..<(cursor + width)]))
        cursor += width
        return value
    }

    private static func uintBigEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func uintLittleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.enumerated().reduce(UInt64(0)) { partial, item in
            partial | (UInt64(item.element) << UInt64(item.offset * 8))
        }
    }
}
