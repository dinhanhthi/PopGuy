// BabylonBGLDictionaryProvider.swift
// PopGuy — DictionaryEngine
//
// DictionaryProvider adapter for user-loaded Babylon .bgl files.

import Foundation

// MARK: - BabylonBGLDictionaryProvider

nonisolated struct BabylonBGLDictionaryProvider: DictionaryProvider {
    typealias IndexLoader = @Sendable (BabylonDictionary) async throws -> BabylonBGLIndex

    private let dictionaries: [BabylonDictionary]
    private let indexLoader: IndexLoader

    init(
        dictionaries: [BabylonDictionary],
        indexLoader: @escaping IndexLoader = { dictionary in
            try await BabylonBGLIndexCache.shared.index(for: dictionary)
        }
    ) {
        self.dictionaries = dictionaries
        self.indexLoader = indexLoader
    }

    func lookup(
        term: String,
        sourceLanguage: String?,
        definitionLanguage: String?
    ) async throws -> DictionaryEntry {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictionaryLookupError.notFound }

        let candidates = dictionaries.filter { $0.isEnabled }
        guard !candidates.isEmpty else { throw DictionaryLookupError.notFound }

        var lexicalEntries: [LexicalEntry] = []
        for dictionary in candidates {
            // A missing or corrupt .bgl file must not hide results from the other
            // enabled dictionaries — skip the failing one and keep going. If every
            // dictionary fails to load, the empty-result guard below reports notFound.
            guard let index = try? await indexLoader(dictionary) else { continue }
            let matches = index.lookup(term: trimmed)
            guard !matches.isEmpty else { continue }

            lexicalEntries.append(contentsOf: matches.flatMap {
                Self.lexicalEntries(for: $0, dictionary: dictionary)
            })
        }

        guard !lexicalEntries.isEmpty else { throw DictionaryLookupError.notFound }

        return DictionaryEntry(
            headword: trimmed,
            lexicalEntries: lexicalEntries,
            sourceName: DictionaryProviderKind.babylonBGL.displayName,
            rawText: nil
        )
    }

    /// Map one BGL entry to one lexical entry per part-of-speech section. A single
    /// headword can carry several parts of speech (e.g. "result": danh từ + nội động
    /// từ); each becomes its own lexical entry so the view shows a heading per group.
    /// The pronunciation rides on the first emitted entry only.
    private static func lexicalEntries(
        for entry: BabylonBGLEntry,
        dictionary: BabylonDictionary
    ) -> [LexicalEntry] {
        let parsed = parseDefinition(entry.definition)
        var pendingPronunciation = (parsed.pronunciation?.isEmpty == false) ? parsed.pronunciation : nil

        var result: [LexicalEntry] = []
        for group in parsed.groups {
            let senses = group.senses
                .filter { !$0.definition.isEmpty }
                .map { Sense(definition: $0.definition, examples: $0.examples, synonyms: []) }
            guard !senses.isEmpty else { continue }

            let pronunciations: [Pronunciation]
            if let pronunciation = pendingPronunciation {
                pronunciations = [Pronunciation(ipa: pronunciation, tags: [])]
                pendingPronunciation = nil
            } else {
                pronunciations = []
            }

            result.append(LexicalEntry(
                language: dictionary.resolvedDisplayName,
                partOfSpeech: group.partOfSpeech,
                pronunciations: pronunciations,
                senses: senses,
                audioURL: nil
            ))
        }
        return result
    }

    private struct ParsedDefinition {
        let pronunciation: String?
        let groups: [ParsedGroup]
    }

    private struct ParsedGroup {
        let partOfSpeech: String?
        let senses: [ParsedSense]
    }

    private struct ParsedSense {
        let definition: String
        let examples: [String]
    }

    private static func parseDefinition(_ definition: String) -> ParsedDefinition {
        var lines = definition
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let pronunciation: String?
        if let firstLine = lines.first,
           let split = splitPronunciationPrefix(firstLine) {
            pronunciation = split.pronunciation
            if split.remainder.isEmpty {
                lines.removeFirst()
            } else {
                lines[0] = split.remainder
            }
        } else {
            pronunciation = nil
        }

        return ParsedDefinition(
            pronunciation: pronunciation,
            groups: splitIntoPartOfSpeechGroups(lines)
        )
    }

    /// Split the body into part-of-speech sections. A line that begins with a known
    /// Vietnamese part-of-speech marker opens a new group; lines before the first
    /// marker form a group with no part of speech. Each group's body is then parsed
    /// into senses independently.
    private static func splitIntoPartOfSpeechGroups(_ lines: [String]) -> [ParsedGroup] {
        var groups: [ParsedGroup] = []
        var currentPartOfSpeech: String?
        var bodyLines: [String] = []

        func flush() {
            let senses = parseSenses(from: bodyLines)
            if currentPartOfSpeech != nil || !senses.isEmpty {
                groups.append(ParsedGroup(partOfSpeech: currentPartOfSpeech, senses: senses))
            }
            currentPartOfSpeech = nil
            bodyLines = []
        }

        for line in lines {
            if let parsed = splitPartOfSpeechPrefix(line) {
                flush()
                currentPartOfSpeech = parsed.partOfSpeech
                if !parsed.definition.isEmpty {
                    bodyLines.append(parsed.definition)
                }
            } else {
                bodyLines.append(line)
            }
        }
        flush()
        return groups
    }

    private static func parseSenses(from lines: [String]) -> [ParsedSense] {
        var definitionLines: [String] = []
        var exampleLines: [String] = []
        var foundExampleSection = false

        for line in lines {
            if let remainder = exampleHeadingRemainder(in: line) {
                foundExampleSection = true
                if !remainder.isEmpty {
                    exampleLines.append(remainder)
                }
                continue
            }

            if foundExampleSection {
                exampleLines.append(strippingExampleBullet(from: line))
            } else {
                definitionLines.append(line)
            }
        }

        if !foundExampleSection {
            return groupNoHeadingSenses(definitionLines)
        }

        let definition = definitionLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty else { return [] }

        return [
            ParsedSense(
                definition: definition,
                examples: groupedExamples(from: exampleLines)
            )
        ]
    }

    /// Group a no-heading Vietnamese E-V body into senses.
    ///
    /// Lac Viet-style entries carry no "Ví dụ:" heading: the meaning / example /
    /// translation roles are coded only by font colour in the source HTML, which is
    /// already stripped by the time this runs. We re-infer the structure from script
    /// and position: a Vietnamese line starts a new sense (the meaning), each English
    /// line that follows is an example, and the line immediately after an English
    /// example is taken as its Vietnamese translation. This stops every line from
    /// becoming its own numbered sense.
    private static func groupNoHeadingSenses(_ lines: [String]) -> [ParsedSense] {
        var senses: [ParsedSense] = []
        var currentDefinition: String?
        var currentExamples: [String] = []

        func flush() {
            if let definition = currentDefinition {
                senses.append(ParsedSense(definition: definition, examples: currentExamples))
            }
            currentDefinition = nil
            currentExamples = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if currentDefinition == nil {
                // The first line of a group is always the meaning, whatever its
                // script — this keeps non-Vietnamese definitions (e.g. a single
                // French word) intact instead of dropping them as orphan examples.
                currentDefinition = line
                index += 1
            } else if isSourceLanguageLine(line) {
                // Under a meaning, an English line is an example (meanings are
                // Vietnamese). Pair it with the following translation line when the
                // next line is Vietnamese; otherwise keep it as a lone example. This
                // stops long entries from splitting every example into its own sense.
                if index + 1 < lines.count, !isSourceLanguageLine(lines[index + 1]) {
                    currentExamples.append("\(line)\n\(lines[index + 1])")
                    index += 2
                } else {
                    currentExamples.append(line)
                    index += 1
                }
            } else {
                // A Vietnamese line that is not an example translation → next meaning.
                flush()
                currentDefinition = line
                index += 1
            }
        }
        flush()
        return senses
    }

    /// True when a cleaned line carries no Vietnamese-specific letters, i.e. it reads
    /// as a source-language (English) example rather than a Vietnamese meaning or
    /// translation. Diacritic-less Vietnamese meanings are rare, so this split is
    /// reliable enough for the no-heading fallback.
    static func isSourceLanguageLine(_ line: String) -> Bool {
        !line.lowercased().contains { vietnameseLetters.contains($0) }
    }

    private static let vietnameseLetters: Set<Character> = Set(
        "àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ"
    )

    private static func exampleHeadingRemainder(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalizedExampleHeading(trimmed)
        if Self.exampleHeadingMarkers.contains(normalized) {
            return ""
        }

        guard let separator = normalized.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return nil
        }

        let heading = String(normalized[..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.exampleHeadingMarkers.contains(heading) else { return nil }

        guard let originalSeparator = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return ""
        }
        let remainderStart = trimmed.index(after: originalSeparator)
        return String(trimmed[remainderStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedExampleHeading(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func groupedExamples(from lines: [String]) -> [String] {
        let cleaned = lines
            .map { strippingExampleBullet(from: $0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var examples: [String] = []
        var index = 0
        while index < cleaned.count {
            if index + 1 < cleaned.count {
                examples.append("\(cleaned[index])\n\(cleaned[index + 1])")
                index += 2
            } else {
                examples.append(cleaned[index])
                index += 1
            }
        }
        return examples
    }

    private static func strippingExampleBullet(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- ", "• ", "* ", "– ", "— ", "▪ "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    private static func splitPronunciationPrefix(_ line: String) -> (pronunciation: String, remainder: String)? {
        guard line.first == "[",
              let close = line.firstIndex(of: "]") else {
            return nil
        }
        let pronunciation = String(line[...close]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainderStart = line.index(after: close)
        let remainder = String(line[remainderStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (pronunciation, remainder)
    }

    private static func splitPartOfSpeechPrefix(_ line: String) -> (partOfSpeech: String, definition: String)? {
        let normalized = line
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        for partOfSpeech in partOfSpeechPrefixes {
            let normalizedPartOfSpeech = partOfSpeech
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            guard normalized.hasPrefix(normalizedPartOfSpeech) else { continue }

            let end = line.index(line.startIndex, offsetBy: partOfSpeech.count)
            // Only a whole-word match is a part of speech: the marker must end the
            // line or be followed by whitespace, so "danh từ" never matches inside a
            // longer Vietnamese word.
            guard end == line.endIndex || line[end].isWhitespace else { continue }
            let remainder = String(line[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (partOfSpeech, remainder)
        }
        return nil
    }

    /// Vietnamese part-of-speech markers used to split an entry into sections. Only
    /// Vietnamese markers are used (the supported BGL dictionaries are Vietnamese):
    /// English markers like "article" or "noun" would false-match the start of an
    /// English example line ("article of clothing").
    private static let vietnamesePartOfSpeechPrefixes: [String] = [
        "nội động từ",
        "ngoại động từ",
        "trợ động từ",
        "danh từ",
        "động từ",
        "tính từ",
        "trạng từ",
        "phó từ",
        "giới từ",
        "liên từ",
        "đại từ",
        "thán từ",
        "mạo từ",
        "viết tắt",
    ]

    private static var partOfSpeechPrefixes: [String] {
        vietnamesePartOfSpeechPrefixes.sorted { $0.count > $1.count }
    }

    private static let exampleHeadingMarkers: Set<String> = [
        "vi du",
        "thi du",
        "example",
        "examples",
        "ex",
        "eg",
        "e.g.",
    ]
}

// MARK: - BabylonBGLIndexCache

/// Actor-owned BGL index cache. Parsed indexes are kept in memory for the
/// current launch and persisted under Application Support for later launches.
actor BabylonBGLIndexCache {
    typealias IndexParser = @Sendable (URL, BabylonDictionary) throws -> BabylonBGLIndex

    static let shared = BabylonBGLIndexCache()

    private static let cacheVersion = 2

    private struct SourceFileSignature: Sendable, Codable, Equatable {
        let filePath: String
        let modificationTime: TimeInterval?
        let fileSize: Int?
    }

    private struct CachedIndex {
        let signature: SourceFileSignature
        let index: BabylonBGLIndex
    }

    private struct PersistedIndex: Sendable, Codable {
        let version: Int
        let dictionaryID: UUID
        let signature: SourceFileSignature
        let entries: [BabylonBGLEntry]
        let termIndex: [String: [Int]]
    }

    private var cache: [UUID: CachedIndex] = [:]
    private let cacheDirectory: URL
    private let parser: IndexParser

    init(
        cacheDirectory: URL? = nil,
        parser: @escaping IndexParser = { url, dictionary in
            try BabylonBGLParser().parseFile(url: url, dictionary: dictionary)
        }
    ) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.parser = parser
    }

    func index(for dictionary: BabylonDictionary) async throws -> BabylonBGLIndex {
        let fileURL = URL(fileURLWithPath: dictionary.filePath)
        let signature = try Self.sourceFileSignature(for: fileURL)

        if let cached = cache[dictionary.id],
           cached.signature == signature {
            return cached.index
        }

        if let persisted = loadPersistedIndex(for: dictionary, signature: signature) {
            cache[dictionary.id] = CachedIndex(signature: signature, index: persisted)
            return persisted
        }

        let parsed = try parser(fileURL, dictionary)
        cache[dictionary.id] = CachedIndex(signature: signature, index: parsed)
        try? savePersistedIndex(parsed, signature: signature)
        return parsed
    }

    func warm(dictionaries: [BabylonDictionary]) async {
        for dictionary in dictionaries where dictionary.isEnabled {
            _ = try? await index(for: dictionary)
        }
    }

    func remove(id: UUID) {
        cache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: cacheFileURL(for: id))
    }

    func removeAll() {
        cache.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func loadPersistedIndex(
        for dictionary: BabylonDictionary,
        signature: SourceFileSignature
    ) -> BabylonBGLIndex? {
        let fileURL = cacheFileURL(for: dictionary.id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try PropertyListDecoder().decode(PersistedIndex.self, from: data)
            guard payload.version == Self.cacheVersion,
                  payload.dictionaryID == dictionary.id,
                  payload.signature == signature else {
                return nil
            }

            return BabylonBGLIndex(
                dictionary: dictionary,
                entries: payload.entries,
                termIndex: payload.termIndex
            )
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    private func savePersistedIndex(
        _ index: BabylonBGLIndex,
        signature: SourceFileSignature
    ) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = PersistedIndex(
            version: Self.cacheVersion,
            dictionaryID: index.dictionary.id,
            signature: signature,
            entries: index.entries,
            termIndex: index.termIndex
        )
        let data = try encoder.encode(payload)
        try data.write(to: cacheFileURL(for: index.dictionary.id), options: [.atomic])
    }

    private func cacheFileURL(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString).bglindex", isDirectory: false)
    }

    private static func sourceFileSignature(for fileURL: URL) throws -> SourceFileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modificationDate = attributes[.modificationDate] as? Date
        let fileSize = (attributes[.size] as? NSNumber)?.intValue
        return SourceFileSignature(
            filePath: fileURL.path,
            modificationTime: modificationDate?.timeIntervalSinceReferenceDate,
            fileSize: fileSize
        )
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PopGuy", isDirectory: true)
            .appendingPathComponent("BabylonBGLIndexes", isDirectory: true)
    }
}
