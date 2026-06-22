// DictionaryEngineTests.swift
// PopGuyTests
//
// Unit tests for the DictionaryEngine module: DictionaryConfig Codable,
// DictionaryProviderKind properties, the three providers' lookup/error paths,
// MinhqndDictionaryProvider URL resolution + synonym matching helpers, and the
// ToolbarViewModel dictionary state machine branches.
//
// Network is stubbed via MockURLProtocol (host-keyed), injected through the
// providers' test-only init(session:).

import ApplicationServices
import Foundation
import Testing
@testable import PopGuy

// MARK: - DictionaryConfig

@Suite("DictionaryConfig")
struct DictionaryConfigTests {

    @Test("default values match the spec")
    func defaultValues() {
        let c = DictionaryConfig.default
        #expect(c.provider == .macOSBuiltin)
        #expect(c.definitionLanguage == "en")
        #expect(c.isEnabled == false)
        #expect(c.accent == .usEnglish)
        #expect(c.speakSettings == .default)
    }

    @Test("round-trip encode/decode preserves all fields")
    func roundTrip() throws {
        var original = DictionaryConfig.default
        original.provider = .minhqnd
        original.definitionLanguage = "vi"
        original.isEnabled = true
        original.accent = .ukEnglish
        original.speakSettings.rate = 0.6
        original.speakSettings.dictionaryAudioEnabled = false

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DictionaryConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("decoding empty JSON yields defaults")
    func decodeEmpty() throws {
        let decoded = try JSONDecoder().decode(DictionaryConfig.self, from: Data("{}".utf8))
        #expect(decoded == DictionaryConfig.default)
    }

    @Test("decoding partial JSON fills missing fields with defaults")
    func decodePartial() throws {
        let json = """
        {"provider": "freeDictionaryAPI", "isEnabled": true}
        """
        let decoded = try JSONDecoder().decode(DictionaryConfig.self, from: Data(json.utf8))
        #expect(decoded.provider == .freeDictionaryAPI)
        #expect(decoded.isEnabled == true)
        #expect(decoded.definitionLanguage == "en")
        #expect(decoded.accent == .usEnglish)
    }

    @Test("decoding unknown provider throws (corrupted config blob)")
    func decodeUnknownProvider() throws {
        let json = #"{"provider": "not-a-real-provider"}"#
        // Decoding an unknown enum case throws — this is the right failure
        // surface for a corrupted config blob; decodeIfPresent can't recover
        // from a present-but-invalid value.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(DictionaryConfig.self, from: Data(json.utf8))
        }
    }
}

// MARK: - DictionaryProviderKind

@Suite("DictionaryProviderKind")
struct DictionaryProviderKindTests {

    @Test("allCases covers the v1 providers")
    func allCasesCoverage() {
        #expect(DictionaryProviderKind.allCases == [
            .macOSBuiltin, .minhqnd, .freeDictionaryAPI, .babylonBGL
        ])
    }

    @Test("displayName is non-empty for every case")
    func displayNameNonEmpty() {
        for kind in DictionaryProviderKind.allCases {
            #expect(!kind.displayName.isEmpty, "displayName empty for \(kind)")
        }
    }

    @Test("requiresNetwork is false only for the builtin provider")
    func requiresNetwork() {
        #expect(DictionaryProviderKind.macOSBuiltin.requiresNetwork == false)
        #expect(DictionaryProviderKind.minhqnd.requiresNetwork == true)
        #expect(DictionaryProviderKind.freeDictionaryAPI.requiresNetwork == true)
        #expect(DictionaryProviderKind.babylonBGL.requiresNetwork == false)
    }

    @Test("iconSystemName is non-empty for every case")
    func iconNonEmpty() {
        for kind in DictionaryProviderKind.allCases {
            #expect(!kind.iconSystemName.isEmpty)
        }
    }

    @Test("languageHint is non-empty for every case")
    func languageHintNonEmpty() {
        for kind in DictionaryProviderKind.allCases {
            #expect(!kind.languageHint.isEmpty)
        }
    }
}

// MARK: - DictionaryProviderFactory

@Suite("DictionaryProviderFactory")
struct DictionaryProviderFactoryTests {

    @Test("make(_:) returns a provider for every kind")
    func factoryMapping() {
        for kind in DictionaryProviderKind.allCases {
            let provider = DictionaryProviderFactory.make(kind)
            #expect(String(describing: type(of: provider)).contains("Provider"))
        }
    }
}

// MARK: - BabylonDictionary Codable

@Suite("BabylonDictionary Codable")
struct BabylonDictionaryCodableTests {

    @Test("round-trip preserves the language mapping")
    func roundTripPreservesLanguages() throws {
        let original = BabylonDictionary(
            displayName: "Lac Viet E-V",
            filePath: "/tmp/ev.bgl",
            isEnabled: true,
            entryCount: 42,
            sourceLanguage: "en",
            targetLanguage: "vi"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BabylonDictionary.self, from: data)
        #expect(decoded == original)
        #expect(decoded.sourceLanguage == "en")
        #expect(decoded.targetLanguage == "vi")
    }

    @Test("decoding a pre-language blob defaults the codes to empty")
    func decodesLegacyBlobWithoutLanguageKeys() throws {
        // A blob persisted before the language fields existed (no source/target keys).
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "displayName": "Lac Viet E-V",
            "filePath": "/tmp/ev.bgl",
            "isEnabled": true,
            "entryCount": 42
        }
        """
        let decoded = try JSONDecoder().decode(BabylonDictionary.self, from: Data(json.utf8))
        #expect(decoded.sourceLanguage == "")
        #expect(decoded.targetLanguage == "")
        #expect(decoded.entryCount == 42)
    }
}

// MARK: - Babylon BGL parser / provider

@Suite("BabylonBGLParser")
struct BabylonBGLParserTests {

    @Test("parseUncompressedBlocks indexes headwords and alternates from type 1 entry blocks")
    func parseUncompressedBlocksIndexesEntryAndAlternates() throws {
        let dictionary = BabylonDictionary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Vietnamese English",
            filePath: "/tmp/ve.bgl",
            isEnabled: true,
            entryCount: 0
        )
        let stream = Self.entryBlock(type: 1, word: "hello", definition: "xin chào<br>used as a greeting", alternates: ["hi"])

        let index = try BabylonBGLParser().parseUncompressedBlocks(stream, dictionary: dictionary)

        #expect(index.entryCount == 1)
        #expect(index.lookup(term: "HELLO").first?.headword == "hello")
        #expect(index.lookup(term: "hi").first?.definition.contains("xin chào") == true)
    }

    @Test("parseUncompressedBlocks strips Babylon presentation artifacts")
    func parseUncompressedBlocksStripsBabylonPresentationArtifacts() throws {
        let dictionary = BabylonDictionary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            displayName: "Lac Viet E-V",
            filePath: "/tmp/lacviet.bgl",
            isEnabled: true,
            entryCount: 0
        )
        let definition = """
        #I_C{width:18px;vertical-align:baseline;} #C_C{width:2000px;}
        Sound\\f\\format.wav
        ['fɔ:mæt]danh từ khổ (sách, giấy, bìa...)
        """
        let stream = Self.entryBlock(type: 1, word: "format", definition: definition, alternates: ["formats"])

        let index = try BabylonBGLParser().parseUncompressedBlocks(stream, dictionary: dictionary)
        let entry = try #require(index.lookup(term: "format").first)

        #expect(entry.definition == "['fɔ:mæt]\ndanh từ khổ (sách, giấy, bìa...)")
        #expect(!entry.definition.contains("#I_C"))
        #expect(!entry.definition.contains("Sound"))
    }

    @Test("parseUncompressedBlocks keeps table row examples on separate lines")
    func parseUncompressedBlocksKeepsTableRowExamplesOnSeparateLines() throws {
        let dictionary = BabylonDictionary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            displayName: "Lac Viet E-V",
            filePath: "/tmp/lacviet.bgl",
            isEnabled: true,
            entryCount: 0
        )
        let definition = """
        động từ cung cấp<table><tr><td>Ví dụ:</td></tr><tr><td>provide for a family</td></tr><tr><td>chu cấp cho gia đình</td></tr></table>
        """
        let stream = Self.entryBlock(type: 1, word: "provide", definition: definition, alternates: [])

        let index = try BabylonBGLParser().parseUncompressedBlocks(stream, dictionary: dictionary)
        let entry = try #require(index.lookup(term: "provide").first)

        #expect(entry.definition == "động từ cung cấp\nVí dụ:\nprovide for a family\nchu cấp cho gia đình")
    }

    private static func entryBlock(type: UInt8, word: String, definition: String, alternates: [String]) -> Data {
        var payload = Data()
        let wordBytes = Array(word.utf8)
        payload.append(UInt8(wordBytes.count))
        payload.append(contentsOf: wordBytes)

        let definitionBytes = Array(definition.utf8)
        payload.append(UInt8((definitionBytes.count >> 8) & 0xff))
        payload.append(UInt8(definitionBytes.count & 0xff))
        payload.append(contentsOf: definitionBytes)

        for alternate in alternates {
            let alternateBytes = Array(alternate.utf8)
            payload.append(UInt8(alternateBytes.count))
            payload.append(contentsOf: alternateBytes)
        }

        var block = Data()
        block.append(type & 0x0f)
        block.append(UInt8(payload.count))
        block.append(payload)
        return block
    }
}

@Suite("BabylonBGLDictionaryProvider")
struct BabylonBGLDictionaryProviderTests {

    @Test("lookup searches every enabled dictionary regardless of target language")
    func lookupSearchesEnabledDictionaries() async throws {
        let viDictionary = Self.dictionary(id: 1, name: "Vietnamese English", enabled: true)
        let frDictionary = Self.dictionary(id: 2, name: "French English", enabled: true)
        let disabledDictionary = Self.dictionary(id: 3, name: "Disabled Vietnamese", enabled: false)
        let indexes = [
            viDictionary.id: BabylonBGLIndex(dictionary: viDictionary, entries: [
                BabylonBGLEntry(headword: "hello", definition: "xin chào", alternates: [])
            ]),
            frDictionary.id: BabylonBGLIndex(dictionary: frDictionary, entries: [
                BabylonBGLEntry(headword: "hello", definition: "bonjour", alternates: [])
            ]),
            disabledDictionary.id: BabylonBGLIndex(dictionary: disabledDictionary, entries: [
                BabylonBGLEntry(headword: "hello", definition: "disabled", alternates: [])
            ]),
        ]
        let provider = BabylonBGLDictionaryProvider(
            dictionaries: [viDictionary, frDictionary, disabledDictionary],
            indexLoader: { dictionary in
                guard let index = indexes[dictionary.id] else { throw DictionaryLookupError.notFound }
                return index
            }
        )

        let entry = try await provider.lookup(term: "hello", sourceLanguage: String?.none, definitionLanguage: "vi")

        #expect(entry.sourceName == DictionaryProviderKind.babylonBGL.displayName)
        let definitions = entry.lexicalEntries.flatMap(\.senses).map(\.definition)
        #expect(definitions.contains("xin chào"))
        #expect(definitions.contains("bonjour"))
        #expect(!definitions.contains("disabled"))
    }

    @Test("lookup maps cleaned Lac Viet entries to structured phonetic part of speech and definition")
    func lookupMapsLacVietEntriesToStructuredFields() async throws {
        let viDictionary = Self.dictionary(id: 11, name: "Lac Viet E-V", enabled: true)
        let provider = BabylonBGLDictionaryProvider(
            dictionaries: [viDictionary],
            indexLoader: { dictionary in
                BabylonBGLIndex(dictionary: dictionary, entries: [
                    BabylonBGLEntry(
                        headword: "format",
                        definition: "['fɔ:mæt]\ndanh từ khổ (sách, giấy, bìa...)",
                        alternates: ["formats"]
                    )
                ])
            }
        )

        let entry = try await provider.lookup(term: "format", sourceLanguage: String?.none, definitionLanguage: "vi")

        #expect(entry.rawText == nil)
        #expect(entry.lexicalEntries.first?.pronunciations.first?.ipa == "['fɔ:mæt]")
        #expect(entry.lexicalEntries.first?.partOfSpeech == "danh từ")
        #expect(entry.lexicalEntries.first?.senses.first?.definition == "khổ (sách, giấy, bìa...)")
    }

    @Test("lookup preserves Vietnamese main meaning before parenthetical notes")
    func lookupPreservesVietnameseMainMeaningBeforeParenthetical() async throws {
        let viDictionary = Self.dictionary(id: 12, name: "Lac Viet E-V", enabled: true)
        let provider = BabylonBGLDictionaryProvider(
            dictionaries: [viDictionary],
            indexLoader: { dictionary in
                BabylonBGLIndex(dictionary: dictionary, entries: [
                    BabylonBGLEntry(
                        headword: "provider",
                        definition: "[prə'vaidə]\ndanh từ người cung cấp (nhất là người trụ cột của gia đình)",
                        alternates: []
                    )
                ])
            }
        )

        let entry = try await provider.lookup(term: "provider", sourceLanguage: String?.none, definitionLanguage: "vi")

        #expect(entry.lexicalEntries.first?.pronunciations.first?.ipa == "[prə'vaidə]")
        #expect(entry.lexicalEntries.first?.partOfSpeech == "danh từ")
        #expect(
            entry.lexicalEntries.first?.senses.first?.definition
                == "người cung cấp (nhất là người trụ cột của gia đình)"
        )
    }

    @Test("lookup maps BGL example sections to separated example blocks")
    func lookupMapsBGLExampleSectionsToSeparatedExampleBlocks() async throws {
        let viDictionary = Self.dictionary(id: 13, name: "Lac Viet E-V", enabled: true)
        let provider = BabylonBGLDictionaryProvider(
            dictionaries: [viDictionary],
            indexLoader: { dictionary in
                BabylonBGLIndex(dictionary: dictionary, entries: [
                    BabylonBGLEntry(
                        headword: "provide",
                        definition: """
                        [prə'vaid]
                        động từ cung cấp
                        Ví dụ:
                        provide for a family
                        chu cấp cho gia đình
                        provide evidence
                        cung cấp bằng chứng
                        """,
                        alternates: []
                    )
                ])
            }
        )

        let entry = try await provider.lookup(term: "provide", sourceLanguage: String?.none, definitionLanguage: "vi")
        let sense = try #require(entry.lexicalEntries.first?.senses.first)

        #expect(sense.definition == "cung cấp")
        #expect(sense.examples == [
            "provide for a family\nchu cấp cho gia đình",
            "provide evidence\ncung cấp bằng chứng",
        ])
    }

    @Test("lookup groups a heading-less entry into meaning + example/translation pairs")
    func lookupGroupsHeadinglessEntryIntoSenses() async throws {
        let viDictionary = Self.dictionary(id: 14, name: "Lac Viet E-V", enabled: true)
        let provider = BabylonBGLDictionaryProvider(
            dictionaries: [viDictionary],
            indexLoader: { dictionary in
                BabylonBGLIndex(dictionary: dictionary, entries: [
                    BabylonBGLEntry(
                        headword: "result",
                        definition: """
                        [ri'zʌlt]
                        danh từ
                        (result of something) kết quả (của cái gì)
                        the flight was delayed as a result of fog
                        chuyến bay bị muộn vì sương mù
                        (số nhiều) thành quả
                        to begin to show/produce/achieve results
                        bắt đầu cho thấy/tạo ra/đạt được những thành quả
                        """,
                        alternates: []
                    )
                ])
            }
        )

        let lexical = try #require(
            try await provider.lookup(term: "result", sourceLanguage: String?.none, definitionLanguage: "vi")
                .lexicalEntries.first
        )

        #expect(lexical.partOfSpeech == "danh từ")
        // Each Vietnamese meaning is one sense — not one sense per line.
        #expect(lexical.senses.count == 2)
        #expect(lexical.senses.first?.definition == "(result of something) kết quả (của cái gì)")
        #expect(lexical.senses.first?.examples == [
            "the flight was delayed as a result of fog\nchuyến bay bị muộn vì sương mù"
        ])
        #expect(lexical.senses.last?.definition == "(số nhiều) thành quả")
        #expect(lexical.senses.last?.examples == [
            "to begin to show/produce/achieve results\nbắt đầu cho thấy/tạo ra/đạt được những thành quả"
        ])
    }

    private static func dictionary(id: Int, name: String, enabled: Bool) -> BabylonDictionary {
        BabylonDictionary(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", id))")!,
            displayName: name,
            filePath: "/tmp/\(name).bgl",
            isEnabled: enabled,
            entryCount: 1
        )
    }
}

@Suite("BabylonBGLIndexCache")
struct BabylonBGLIndexCacheTests {

    @Test("index persists to disk and reloads without reparsing")
    func indexPersistsToDiskAndReloadsWithoutReparsing() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = tempRoot.appendingPathComponent("dictionary.bgl", isDirectory: false)
        let cacheDirectory = tempRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("source-v1".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dictionary = BabylonDictionary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            displayName: "Vietnamese English",
            filePath: sourceURL.path,
            isEnabled: true,
            entryCount: 1
        )
        let expectedIndex = BabylonBGLIndex(dictionary: dictionary, entries: [
            BabylonBGLEntry(headword: "hello", definition: "xin chào", alternates: ["hi"])
        ])
        let writer = BabylonBGLIndexCache(
            cacheDirectory: cacheDirectory,
            parser: { _, _ in expectedIndex }
        )

        _ = try await writer.index(for: dictionary)

        let reader = BabylonBGLIndexCache(
            cacheDirectory: cacheDirectory,
            parser: { _, _ in
                throw DictionaryLookupError.decoding("Expected persisted BGL index to load without reparsing.")
            }
        )

        let loaded = try await reader.index(for: dictionary)

        #expect(loaded.entryCount == 1)
        #expect(loaded.lookup(term: "hi").first?.definition == "xin chào")
    }

    @Test("index ignores persisted cache when source file changes")
    func indexIgnoresPersistedCacheWhenSourceFileChanges() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = tempRoot.appendingPathComponent("dictionary.bgl", isDirectory: false)
        let cacheDirectory = tempRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("source-v1".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dictionary = BabylonDictionary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            displayName: "Vietnamese English",
            filePath: sourceURL.path,
            isEnabled: true,
            entryCount: 1
        )
        let staleIndex = BabylonBGLIndex(dictionary: dictionary, entries: [
            BabylonBGLEntry(headword: "old", definition: "stale", alternates: [])
        ])
        let writer = BabylonBGLIndexCache(
            cacheDirectory: cacheDirectory,
            parser: { _, _ in staleIndex }
        )

        _ = try await writer.index(for: dictionary)
        try Data("source-v2-with-different-size".utf8).write(to: sourceURL)

        let refreshedIndex = BabylonBGLIndex(dictionary: dictionary, entries: [
            BabylonBGLEntry(headword: "new", definition: "fresh", alternates: [])
        ])
        let reader = BabylonBGLIndexCache(
            cacheDirectory: cacheDirectory,
            parser: { _, _ in refreshedIndex }
        )

        let loaded = try await reader.index(for: dictionary)

        #expect(loaded.lookup(term: "old").isEmpty)
        #expect(loaded.lookup(term: "new").first?.definition == "fresh")
    }

    @Test("warm loads persisted indexes into memory before lookup")
    func warmLoadsPersistedIndexesIntoMemoryBeforeLookup() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = tempRoot.appendingPathComponent("dictionary.bgl", isDirectory: false)
        let cacheDirectory = tempRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("source-v1".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dictionary = BabylonDictionary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            displayName: "Vietnamese English",
            filePath: sourceURL.path,
            isEnabled: true,
            entryCount: 1
        )
        let expectedIndex = BabylonBGLIndex(dictionary: dictionary, entries: [
            BabylonBGLEntry(headword: "hello", definition: "xin chào", alternates: [])
        ])
        let writer = BabylonBGLIndexCache(
            cacheDirectory: cacheDirectory,
            parser: { _, _ in expectedIndex }
        )

        _ = try await writer.index(for: dictionary)

        let reader = BabylonBGLIndexCache(
            cacheDirectory: cacheDirectory,
            parser: { _, _ in
                throw DictionaryLookupError.decoding("Expected warm cache to satisfy lookup without reparsing.")
            }
        )
        await reader.warm(dictionaries: [dictionary])
        try FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent("\(dictionary.id.uuidString).bglindex", isDirectory: false)
        )

        let loaded = try await reader.index(for: dictionary)

        #expect(loaded.lookup(term: "hello").first?.definition == "xin chào")
    }
}

// MARK: - DictionaryEngine multi-provider lookup

private struct StubDictionaryProvider: DictionaryProvider {
    let result: Result<DictionaryEntry, DictionaryLookupError>

    func lookup(
        term: String,
        sourceLanguage: String?,
        definitionLanguage: String?
    ) async throws -> DictionaryEntry {
        try result.get()
    }
}

@Suite("DictionaryEngine lookupAll")
struct DictionaryEngineLookupAllTests {

    private func entry(_ word: String, source: String) -> DictionaryEntry {
        DictionaryEntry.plainText(headword: word, text: "\(source) definition", sourceName: source)
    }

    private func makeEngine(_ results: [DictionaryProviderKind: Result<DictionaryEntry, DictionaryLookupError>]) -> DictionaryEngine {
        DictionaryEngine { kind in
            StubDictionaryProvider(result: results[kind] ?? .failure(.notFound))
        }
    }

    @Test("lookupAll returns successful providers in provider order and skips not-found providers")
    func lookupAllReturnsOrderedSuccesses() async throws {
        var config = DictionaryConfig.default
        config.definitionLanguage = ""
        let engine = makeEngine([
            .macOSBuiltin: .success(entry("hello", source: "macOS Dictionary")),
            .minhqnd: .failure(.notFound),
            .freeDictionaryAPI: .success(entry("hello", source: "Free Dictionary API")),
        ])

        let results = try await engine.lookupAll(term: "hello", config: config)

        #expect(results.map(\.providerKind) == [.macOSBuiltin, .freeDictionaryAPI])
        #expect(results.map(\.entry.sourceName) == ["macOS Dictionary", "Free Dictionary API"])
    }

    @Test("lookupAll skips macOS Dictionary when a non-English target definition language is requested")
    func lookupAllSkipsMacOSForNonEnglishTarget() async throws {
        var config = DictionaryConfig.default
        config.definitionLanguage = "vi"
        let engine = makeEngine([
            .macOSBuiltin: .success(entry("hello", source: "macOS Dictionary")),
            .minhqnd: .success(entry("hello", source: "minhqnd")),
            .freeDictionaryAPI: .failure(.notFound),
        ])

        let results = try await engine.lookupAll(term: "hello", config: config)

        #expect(results.map(\.providerKind) == [.minhqnd])
        #expect(results.map(\.entry.sourceName) == ["minhqnd"])
    }

    @Test("lookupAll includes macOS Dictionary when the target definition language is English")
    func lookupAllIncludesMacOSForEnglishTarget() async throws {
        var config = DictionaryConfig.default
        config.definitionLanguage = "en"
        let engine = makeEngine([
            .macOSBuiltin: .success(entry("hello", source: "macOS Dictionary")),
            .minhqnd: .failure(.notFound),
            .freeDictionaryAPI: .success(entry("hello", source: "Free Dictionary API")),
        ])

        let results = try await engine.lookupAll(term: "hello", config: config)

        #expect(results.map(\.providerKind) == [.macOSBuiltin, .freeDictionaryAPI])
        #expect(results.map(\.entry.sourceName) == ["macOS Dictionary", "Free Dictionary API"])
    }

    @Test("lookupAll still returns definitions when another provider errors")
    func lookupAllSuppressesErrorsWhenDefinitionExists() async throws {
        let engine = makeEngine([
            .macOSBuiltin: .failure(.network(underlying: "offline")),
            .minhqnd: .success(entry("hello", source: "minhqnd")),
            .freeDictionaryAPI: .failure(.notFound),
        ])

        let results = try await engine.lookupAll(term: "hello", config: .default)

        #expect(results.map(\.providerKind) == [.minhqnd])
    }

    @Test("lookupAll throws notFound when every provider misses")
    func lookupAllThrowsNotFoundWhenAllMiss() async {
        let engine = makeEngine([:])

        await #expect(throws: DictionaryLookupError.notFound) {
            _ = try await engine.lookupAll(term: "missing", config: .default)
        }
    }

    @Test("lookupAll throws a provider error when no provider succeeds")
    func lookupAllThrowsProviderErrorWhenNoSuccess() async {
        let engine = makeEngine([
            .macOSBuiltin: .failure(.notFound),
            .minhqnd: .failure(.rateLimited),
            .freeDictionaryAPI: .failure(.notFound),
        ])

        await #expect(throws: DictionaryLookupError.rateLimited) {
            _ = try await engine.lookupAll(term: "hello", config: .default)
        }
    }
}

// MARK: - URL capture helper (thread-safe)

/// Thread-safe box for capturing a request URL from inside a `@Sendable`
/// MockURLProtocol handler closure.
final class URLCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL?
    func set(_ url: URL?) {
        lock.withLock { _url = url }
    }
    func get() -> URL? {
        lock.withLock { _url }
    }
}

// MARK: - FreeDictionaryAPIProvider

@Suite("FreeDictionaryAPIProvider", .serialized)
struct FreeDictionaryAPIProviderTests {

    private static let mockHost = "freedictionaryapi.com"

    private func makeSession(host: String, handler: @escaping @Sendable (URLRequest) throws -> (MockHTTPResponse, Data)) -> URLSession {
        MockURLProtocol.register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("lookup returns notFound for empty/whitespace term")
    func emptyTerm() async throws {
        let provider = FreeDictionaryAPIProvider(session: makeSession(host: "unused.com") { _ in fatalError("should not hit network") })
        await #expect(throws: DictionaryLookupError.notFound) {
            _ = try await provider.lookup(term: "   ", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup builds the URL with definitionLanguage when sourceLanguage is nil")
    func urlUsesDefinitionLanguage() async throws {
        let captured = URLCapture()
        let session = makeSession(host: Self.mockHost) { req in
            captured.set(req.url)
            return (MockHTTPResponse(statusCode: 404), Data())
        }
        let provider = FreeDictionaryAPIProvider(session: session)
        await #expect(throws: DictionaryLookupError.self) {
            _ = try await provider.lookup(term: "bonjour", sourceLanguage: nil, definitionLanguage: "fr")
        }
        let url = try #require(captured.get())
        #expect(url.path.contains("/fr/"))
    }

    @Test("lookup defaults to 'en' when both languages are nil")
    func defaultsToEnglish() async throws {
        let captured = URLCapture()
        let session = makeSession(host: Self.mockHost) { req in
            captured.set(req.url)
            return (MockHTTPResponse(statusCode: 404), Data())
        }
        let provider = FreeDictionaryAPIProvider(session: session)
        await #expect(throws: DictionaryLookupError.self) {
            _ = try await provider.lookup(term: "hello", sourceLanguage: nil, definitionLanguage: nil)
        }
        let url = try #require(captured.get())
        #expect(url.path.contains("/en/"))
    }

    @Test("lookup throws rateLimited on HTTP 429")
    func rateLimited() async throws {
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 429), Data())
        }
        let provider = FreeDictionaryAPIProvider(session: session)
        await #expect(throws: DictionaryLookupError.rateLimited) {
            _ = try await provider.lookup(term: "hello", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup throws network on non-2xx (non-429)")
    func networkErrorOn500() async throws {
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 500), Data())
        }
        let provider = FreeDictionaryAPIProvider(session: session)
        await #expect(throws: DictionaryLookupError.self) {
            _ = try await provider.lookup(term: "hello", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup throws decoding on invalid JSON")
    func decodingError() async throws {
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 200), Data("not-json".utf8))
        }
        let provider = FreeDictionaryAPIProvider(session: session)
        await #expect(throws: DictionaryLookupError.self) {
            _ = try await provider.lookup(term: "hello", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup throws notFound when entries is empty")
    func emptyEntries() async throws {
        let payload = Data(#"{"word":"x","entries":[]}"#.utf8)
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 200), payload)
        }
        let provider = FreeDictionaryAPIProvider(session: session)
        await #expect(throws: DictionaryLookupError.notFound) {
            _ = try await provider.lookup(term: "x", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup maps a valid response into a DictionaryEntry")
    func successMapping() async throws {
        let payload = Data("""
        {
            "word": "hello",
            "entries": [
                {
                    "partOfSpeech": "exclamation",
                    "pronunciations": [{"text": "/həˈləʊ/", "tags": ["UK"]}],
                    "senses": [
                        {"definition": "used as a greeting", "examples": ["Hello there!"], "synonyms": ["hi"]}
                    ],
                    "synonyms": ["hi"]
                }
            ]
        }
        """.utf8)
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 200), payload)
        }
        let provider = FreeDictionaryAPIProvider(session: session)
        let entry = try await provider.lookup(term: "hello", sourceLanguage: nil, definitionLanguage: nil)
        #expect(entry.headword == "hello")
        #expect(entry.sourceName == "Free Dictionary API")
        #expect(entry.lexicalEntries.count == 1)
        let lexical = try #require(entry.lexicalEntries.first)
        #expect(lexical.partOfSpeech == "exclamation")
        #expect(lexical.pronunciations.first?.ipa == "/həˈləʊ/")
        let sense = try #require(lexical.senses.first)
        #expect(sense.definition == "used as a greeting")
        #expect(sense.examples == ["Hello there!"])
        #expect(sense.synonyms.contains("hi"))
    }
}

// MARK: - MinhqndDictionaryProvider

@Suite("MinhqndDictionaryProvider", .serialized)
struct MinhqndDictionaryProviderTests {

    private static let mockHost = "dict.minhqnd.com"

    private func makeSession(host: String, handler: @escaping @Sendable (URLRequest) throws -> (MockHTTPResponse, Data)) -> URLSession {
        MockURLProtocol.register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("lookup returns notFound for empty/whitespace term")
    func emptyTerm() async throws {
        let provider = MinhqndDictionaryProvider(session: makeSession(host: "unused.com") { _ in fatalError("should not hit network") })
        await #expect(throws: DictionaryLookupError.notFound) {
            _ = try await provider.lookup(term: "", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup throws notFound when exists is false")
    func notFoundWhenMissing() async throws {
        let payload = Data(#"{"exists": false, "word": "x"}"#.utf8)
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 200), payload)
        }
        let provider = MinhqndDictionaryProvider(session: session)
        await #expect(throws: DictionaryLookupError.notFound) {
            _ = try await provider.lookup(term: "x", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup throws notFound when results is empty")
    func notFoundWhenEmptyResults() async throws {
        let payload = Data(#"{"exists": true, "word": "x", "results": []}"#.utf8)
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 200), payload)
        }
        let provider = MinhqndDictionaryProvider(session: session)
        await #expect(throws: DictionaryLookupError.notFound) {
            _ = try await provider.lookup(term: "x", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup throws network on non-2xx")
    func networkError() async throws {
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 503), Data())
        }
        let provider = MinhqndDictionaryProvider(session: session)
        await #expect(throws: DictionaryLookupError.self) {
            _ = try await provider.lookup(term: "x", sourceLanguage: nil, definitionLanguage: nil)
        }
    }

    @Test("lookup query includes word, lang, def_lang when both provided")
    func queryConstruction() async throws {
        let captured = URLCapture()
        let payload = Data(#"{"exists": false}"#.utf8)
        let session = makeSession(host: Self.mockHost) { req in
            captured.set(req.url)
            return (MockHTTPResponse(statusCode: 200), payload)
        }
        let provider = MinhqndDictionaryProvider(session: session)
        await #expect(throws: DictionaryLookupError.self) {
            _ = try await provider.lookup(term: "bonjour", sourceLanguage: "fr", definitionLanguage: "en")
        }
        let url = try #require(captured.get())
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = (components.queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        #expect(names["word"] == "bonjour")
        #expect(names["lang"] == "fr")
        #expect(names["def_lang"] == "en")
    }

    @Test("lookup maps a valid VI response")
    func successMapping() async throws {
        let payload = Data("""
        {
            "exists": true,
            "word": "xin chào",
            "results": [
                {
                    "lang_code": "vi",
                    "lang_name": "Vietnamese",
                    "audio": "/audio/xin-chao.mp3",
                    "pronunciations": [{"ipa": "/sin tɕǎw/", "region": "Northern"}],
                    "meanings": [
                        {"definition": "a greeting", "example": "Xin chào!", "pos": "phrase", "links": []}
                    ],
                    "relations": [
                        {"related_word": "chào", "relation_type": "synonym"}
                    ]
                }
            ]
        }
        """.utf8)
        let session = makeSession(host: Self.mockHost) { _ in
            (MockHTTPResponse(statusCode: 200), payload)
        }
        let provider = MinhqndDictionaryProvider(session: session)
        let entry = try await provider.lookup(term: "xin chào", sourceLanguage: "vi", definitionLanguage: nil)
        #expect(entry.headword == "xin chào")
        #expect(entry.sourceName == "minhqnd")
        let lexical = try #require(entry.lexicalEntries.first)
        #expect(lexical.language == "Vietnamese")
        #expect(lexical.partOfSpeech == "phrase")
        #expect(lexical.pronunciations.first?.ipa == "/sin tɕǎw/")
        #expect(lexical.pronunciations.first?.tags == ["Northern"])
        #expect(lexical.audioURL == "https://dict.minhqnd.com/audio/xin-chao.mp3")
        let sense = try #require(lexical.senses.first)
        #expect(sense.synonyms.contains("chào"))
    }
}

// MARK: - MinhqndDictionaryProvider.resolveAudioURL (security invariants)

@Suite("MinhqndDictionaryProvider.resolveAudioURL")
struct MinhqndResolveAudioURLTests {

    @Test("absolute https URL is returned verbatim")
    func absoluteHttps() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: "https://cdn.example.com/word.mp3",
            langCode: "vi",
            headword: "chào"
        )
        #expect(url == "https://cdn.example.com/word.mp3")
    }

    @Test("absolute http URL is rejected")
    func absoluteHttpRejected() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: "http://cdn.example.com/word.mp3",
            langCode: "vi",
            headword: "chào"
        )
        #expect(url == nil)
    }

    @Test("data: scheme is rejected")
    func dataSchemeRejected() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: "data:audio/mp3;base64,AAAA",
            langCode: "vi",
            headword: "chào"
        )
        #expect(url == nil)
    }

    @Test("javascript: scheme is rejected")
    func javascriptSchemeRejected() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: "javascript:alert(1)",
            langCode: "vi",
            headword: "chào"
        )
        #expect(url == nil)
    }

    @Test("relative path starting with / is joined to the https base")
    func leadingSlash() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: "/audio/word.mp3",
            langCode: "vi",
            headword: "word"
        )
        #expect(url == "https://dict.minhqnd.com/audio/word.mp3")
    }

    @Test("bare path is joined to the https base")
    func barePath() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: "audio/word.mp3",
            langCode: "vi",
            headword: "word"
        )
        #expect(url == "https://dict.minhqnd.com/audio/word.mp3")
    }

    @Test("empty audio falls back to the TTS URL when a lang_code is present")
    func fallbackTTSWithURL() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: nil,
            langCode: "vi",
            headword: "chào"
        )
        #expect(url == "https://dict.minhqnd.com/api/v1/tts?word=ch%C3%A0o&lang=vi")
    }

    @Test("malicious lang_code is escaped and cannot inject query parameters")
    func fallbackTTSEscapesLangCode() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: nil,
            langCode: "vi&inject=1",
            headword: "chào"
        )
        #expect(url == "https://dict.minhqnd.com/api/v1/tts?word=ch%C3%A0o&lang=vi%26inject%3D1")
    }

    @Test("empty audio and empty lang_code returns nil")
    func fallbackNoLang() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: nil,
            langCode: nil,
            headword: "word"
        )
        #expect(url == nil)
    }

    @Test("whitespace-only audio falls back to TTS")
    func whitespaceAudio() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: "   ",
            langCode: "vi",
            headword: "word"
        )
        #expect(url?.hasPrefix("https://dict.minhqnd.com/api/v1/tts?") == true)
    }

    @Test("headword is percent-encoded in the fallback TTS URL")
    func fallbackEncoding() {
        let url = MinhqndDictionaryProvider.resolveAudioURL(
            audio: nil,
            langCode: "vi",
            headword: "xin chào"
        )
        #expect(url == "https://dict.minhqnd.com/api/v1/tts?word=xin%20ch%C3%A0o&lang=vi")
    }
}

// MARK: - MinhqndDictionaryProvider.isSynonymRelation

@Suite("MinhqndDictionaryProvider.isSynonymRelation")
struct MinhqndSynonymTests {

    @Test("nil returns false")
    func nilReturnsFalse() {
        #expect(MinhqndDictionaryProvider.isSynonymRelation(nil) == false)
    }

    @Test("exact 'synonym' (any case) matches")
    func synonymMatches() {
        #expect(MinhqndDictionaryProvider.isSynonymRelation("synonym") == true)
        #expect(MinhqndDictionaryProvider.isSynonymRelation("Synonym") == true)
        #expect(MinhqndDictionaryProvider.isSynonymRelation("SYNONYM") == true)
    }

    @Test("Vietnamese 'đồng nghĩa' substring matches")
    func vietnameseSubstr() {
        #expect(MinhqndDictionaryProvider.isSynonymRelation("từ đồng nghĩa") == true)
        #expect(MinhqndDictionaryProvider.isSynonymRelation("Đồng nghĩa") == true)
    }

    @Test("unrelated type returns false")
    func unrelatedFalse() {
        #expect(MinhqndDictionaryProvider.isSynonymRelation("antonym") == false)
        #expect(MinhqndDictionaryProvider.isSynonymRelation("") == false)
    }
}

// MARK: - ToolbarViewModel dictionary spy

@MainActor
private final class DictionarySpy: ToolbarActionHandling {
    private(set) var dictionaryCalls: [String] = []
    private(set) var dictionaryTargetLanguages: [TargetLanguage] = []
    private(set) var dictionaryCalled: Bool = false
    func improve(text: String, viewModel: ToolbarViewModel) {}
    func shorten(text: String, viewModel: ToolbarViewModel) {}
    func proofread(text: String, viewModel: ToolbarViewModel) {}
    func translate(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {}
    func custom(action: CustomAction, text: String, viewModel: ToolbarViewModel) {}
    func recordSpeak(text: String, engineLabel: String, accent: String, sourceBundleID: String?) {}
    func recordScriptAction(actionName: String, typeLabel: String, input: String, output: String, success: Bool, errorMessage: String?, startedAt: Date, sourceBundleID: String?) {}
    func prompt(promptText: String, text: String, viewModel: ToolbarViewModel) {}
    func dictionary(text: String, targetLanguage: TargetLanguage, viewModel: ToolbarViewModel) {
        dictionaryCalled = true
        dictionaryCalls.append(text)
        dictionaryTargetLanguages.append(targetLanguage)
    }
    func dictionary(text: String, config: DictionaryConfig, actionName: String, viewModel: ToolbarViewModel) {
        dictionaryCalled = true
        dictionaryCalls.append(text)
        dictionaryTargetLanguages.append(TargetLanguage(bcp47: config.definitionLanguage))
    }
    func cancel() {}
}

// MARK: - ToolbarViewModel dictionary state machine

@Suite("ToolbarViewModel dictionary state")
@MainActor
struct ToolbarViewModelDictionaryTests {

    private func makeVM(text: String = "hello") -> ToolbarViewModel {
        let vm = ToolbarViewModel()
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: text, sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        return vm
    }

    @Test("triggerDictionary with no handler surfaces an error state")
    func triggerDictionaryNoHandler() {
        let vm = makeVM()
        vm.triggerDictionary()
        if case .error = vm.actionState {
            // ok
        } else {
            Issue.record("expected .error state, got \(vm.actionState)")
        }
        #expect(vm.isDictionaryAction == true)
    }

    @Test("triggerDictionary invokes handler.dictionary")
    func triggerDictionaryCallsHandler() {
        let vm = makeVM()
        let spy = DictionarySpy()
        vm.actionHandler = spy
        vm.triggerDictionary()
        #expect(spy.dictionaryCalled == true)
        #expect(spy.dictionaryCalls == ["hello"])
        #expect(spy.dictionaryTargetLanguages == [.english])
        #expect(vm.isDictionaryAction == true)
        #expect(vm.isDictionaryNotFound == false)
        #expect(vm.dictionaryEntry == nil)
    }

    @Test("triggerDictionary is a no-op on empty captured text")
    func triggerDictionaryEmptyText() {
        let vm = makeVM(text: "")
        let spy = DictionarySpy()
        vm.actionHandler = spy
        vm.triggerDictionary()
        #expect(spy.dictionaryCalled == false)
    }

    @Test("finishWithDictionary stores entry and seeds preview")
    func finishWithDictionary() {
        let vm = makeVM()
        let entry = DictionaryEntry(
            headword: "hello",
            lexicalEntries: [
                LexicalEntry(
                    language: "en",
                    partOfSpeech: "exclamation",
                    pronunciations: [],
                    senses: [Sense(definition: "used as a greeting", examples: [], synonyms: [])],
                    audioURL: nil
                )
            ],
            sourceName: "Free Dictionary API",
            rawText: nil
        )
        vm.finishWithDictionary(entry)
        #expect(vm.isDictionaryAction == true)
        #expect(vm.isDictionaryNotFound == false)
        #expect(vm.dictionaryEntry?.headword == "hello")
        #expect(vm.editedResult == "used as a greeting")
        if case .result(let preview) = vm.actionState {
            #expect(preview == "used as a greeting")
        } else {
            Issue.record("expected .result state")
        }
    }

    @Test("finishWithDictionary falls back to headword when no senses")
    func finishWithDictionaryFallsBackToHeadword() {
        let vm = makeVM()
        let entry = DictionaryEntry.plainText(
            headword: "x",
            text: "definition body",
            sourceName: "macOS Dictionary"
        )
        vm.finishWithDictionary(entry)
        #expect(vm.dictionaryEntry?.headword == "x")
        // rawText is the fallback when senses is empty.
        #expect(vm.editedResult == "definition body")
    }

    @Test("finishWithDictionaryResults stores multiple providers and switches selected entry")
    func finishWithDictionaryResultsStoresMultipleProviders() {
        let vm = makeVM()
        let mac = DictionaryProviderResult(
            providerKind: .macOSBuiltin,
            entry: .plainText(headword: "hello", text: "mac definition", sourceName: "macOS Dictionary")
        )
        let free = DictionaryProviderResult(
            providerKind: .freeDictionaryAPI,
            entry: .plainText(headword: "hello", text: "free definition", sourceName: "Free Dictionary API")
        )

        vm.finishWithDictionaryResults([mac, free])

        #expect(vm.dictionaryEntries.map(\.providerKind) == [.macOSBuiltin, .freeDictionaryAPI])
        #expect(vm.selectedDictionaryProvider == .macOSBuiltin)
        #expect(vm.dictionaryEntry?.rawText == "mac definition")

        vm.selectDictionaryProvider(.freeDictionaryAPI)

        #expect(vm.selectedDictionaryProvider == .freeDictionaryAPI)
        #expect(vm.dictionaryEntry?.rawText == "free definition")
    }

    @Test("finishWithDictionaryNotFound clears entry and shows not-found state")
    func finishWithDictionaryNotFound() {
        let vm = makeVM()
        // Seed a prior dictionary result, then mark not-found.
        vm.finishWithDictionary(.plainText(headword: "x", text: "y", sourceName: "s"))
        vm.finishWithDictionaryNotFound()
        #expect(vm.isDictionaryAction == true)
        #expect(vm.isDictionaryNotFound == true)
        #expect(vm.dictionaryEntry == nil)
        #expect(vm.dictionaryEntries.isEmpty)
        #expect(vm.editedResult == "")
    }

    @Test("failWith clears dictionary entry while in dictionary mode")
    func failWithClearsEntry() {
        let vm = makeVM()
        vm.finishWithDictionary(.plainText(headword: "x", text: "y", sourceName: "s"))
        vm.failWith(message: "boom")
        #expect(vm.dictionaryEntry == nil)
        #expect(vm.isDictionaryNotFound == false)
        if case .error(let msg) = vm.actionState {
            #expect(msg == "boom")
        } else {
            Issue.record("expected .error state")
        }
    }

    @Test("reset clears all dictionary state")
    func resetClearsDictionary() {
        let vm = makeVM()
        vm.finishWithDictionary(.plainText(headword: "x", text: "y", sourceName: "s"))
        vm.finishWithDictionaryNotFound()
        vm.reset()
        #expect(vm.isDictionaryAction == false)
        #expect(vm.dictionaryEntry == nil)
        #expect(vm.isDictionaryNotFound == false)
    }

    @Test("finishWith(result:) clears dictionary state for non-dictionary actions")
    func finishWithClearsDictionaryState() {
        let vm = makeVM()
        vm.finishWithDictionary(.plainText(headword: "x", text: "y", sourceName: "s"))
        vm.finishWith(result: "improved text")
        #expect(vm.isDictionaryAction == false)
        #expect(vm.dictionaryEntry == nil)
    }

    @Test("update clears dictionary state on a new selection")
    func updateClearsDictionaryState() {
        let vm = makeVM()
        vm.finishWithDictionary(.plainText(headword: "x", text: "y", sourceName: "s"))
        let ref = SourceElementRef(element: AXUIElementCreateSystemWide())
        vm.update(text: "new", sourceElement: ref, screenRect: nil, sourceBundleID: nil)
        #expect(vm.isDictionaryAction == false)
        #expect(vm.dictionaryEntry == nil)
    }
}

// MARK: - ToolbarViewModel.compactActions (dictionary-inclusive regression)

@Suite("ToolbarViewModel compactActions + dictionary")
@MainActor
struct ToolbarViewModelCompactDictionaryTests {

    @Test("3 built-ins + dictionary enabled (total 4) flips compact mode")
    func dictionaryCountsTowardCompact() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = true
        vm.translateEnabled = true
        vm.proofreadEnabled = false
        vm.speakEnabled = false
        vm.promptEnabled = false
        vm.dictionaryEnabled = true
        #expect(vm.compactActions == true)
    }

    @Test("2 built-ins + dictionary (total 3) does not flip compact mode")
    func dictionaryKeepsNonCompactUnderFour() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = true
        vm.shortenEnabled = true
        vm.translateEnabled = false
        vm.proofreadEnabled = false
        vm.speakEnabled = false
        vm.promptEnabled = false
        vm.dictionaryEnabled = true
        #expect(vm.compactActions == false)
    }

    @Test("dictionary alone (1 enabled) does not flip compact mode")
    func dictionaryOnly() {
        let vm = ToolbarViewModel()
        vm.improveEnabled = false
        vm.shortenEnabled = false
        vm.translateEnabled = false
        vm.proofreadEnabled = false
        vm.speakEnabled = false
        vm.promptEnabled = false
        vm.dictionaryEnabled = true
        #expect(vm.compactActions == false)
    }
}
