// EmojiPickerTests.swift
// PopGuyTests
//
// Tests for the Emoji Picker data layer (EmojiPicker module).

import Foundation
import Testing
@testable import PopGuy

@Suite("EmojiCatalog")
struct EmojiCatalogTests {

    @Test("loading from the app bundle yields every emoji and symbol category")
    func loadsBundledCategories() {
        let catalog = EmojiCatalog.load(bundle: .main)
        let emojiCategories = Set(catalog.filter { $0.kind == nil }.map(\.category))
        let symbolCategories = Set(catalog.filter { $0.kind == .symbol }.map(\.category))

        #expect(emojiCategories == [
            "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink",
            "Travel & Places", "Activities", "Objects", "Symbols", "Flags",
        ])
        #expect(symbolCategories == [
            "Arrows", "Checkboxes", "Currency", "Keyboard", "Math", "Typography",
        ])
    }
}

// MARK: - Search

@Suite("EmojiSearch")
struct EmojiSearchTests {

    private func emoji(
        _ char: String, aliases: [String], keywords: [String]? = nil, kind: Emoji.Kind? = nil
    ) -> Emoji {
        Emoji(
            emoji: char, description: aliases[0].replacingOccurrences(of: "_", with: " "),
            category: "Test", aliases: aliases, tags: [], keywords: keywords, kind: kind
        )
    }

    @Test("an exact alias ranks first, even a symbol's over an emoji prefix match")
    func exactAliasRanksFirst() {
        // The expected losers come first in the catalog, so a scoring tie would fail the test.
        let search = EmojiSearch(catalog: [
            emoji("😺", aliases: ["smiley_cat"]),
            emoji("😄", aliases: ["smile"]),
            emoji("💻", aliases: ["cmdline"]),
            emoji("⌘", aliases: ["cmd"], kind: .symbol),
        ])

        #expect(search.search("smile", frecency: { _ in 0 }).first?.emoji == "😄")
        #expect(search.search("cmd", frecency: { _ in 0 }).first?.emoji == "⌘")
    }

    @Test("scattered letters inside a word don't match: yeet does not find lady_beetle")
    func scatteredLettersDoNotMatch() {
        let search = EmojiSearch(catalog: [emoji("🐞", aliases: ["lady_beetle"])])

        #expect(search.search("yeet", frecency: { _ in 0 }).isEmpty)
        #expect(search.search("eetle", frecency: { _ in 0 }).map(\.emoji) == ["🐞"])
    }

    @Test("an accent-free Vietnamese keyword matches: cuoi finds cười")
    func accentFreeVietnameseMatches() {
        let search = EmojiSearch(catalog: [
            emoji("😢", aliases: ["cry"], keywords: ["khóc"]),
            emoji("😆", aliases: ["laughing"], keywords: ["cười"]),
        ])

        #expect(search.search("cuoi", frecency: { _ in 0 }).map(\.emoji) == ["😆"])
    }
}

// MARK: - Skin tones

@Suite("EmojiToning")
struct EmojiToningTests {

    /// Real catalog rows, so a regenerated `emoji.json` without `skin_tones` fails too.
    /// A fixed `maxVersion` keeps the tests independent of the macOS they run on.
    private static let catalog = Dictionary(
        EmojiCatalog.load(bundle: .main, maxVersion: 17.0).map { ($0.emoji, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    @Test("the modifier replaces the U+FE0F after the base")
    func modifierReplacesVariationSelector() throws {
        let victory = try #require(Self.catalog["✌️"])
        #expect(victory.toned(.medium) == "✌🏽")
    }

    @Test("both people take the tone, the handshake between them does not")
    func handshakeInsideSequenceStaysUntoned() throws {
        let holdingHands = try #require(Self.catalog["🧑‍🤝‍🧑"])
        #expect(holdingHands.toned(.medium) == "🧑🏽‍🤝‍🧑🏽")
    }
}

// MARK: - Picker navigation

@Suite("EmojiPickerNavigation")
@MainActor
struct EmojiPickerNavigationTests {

    @Test("Down from the last row into a shorter next section clamps to its last cell")
    func downIntoShorterSectionClamps() {
        let name = UserDefaults.testSuiteDirectory + "/com.popguy.test.emojipicker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        // Category A: 13 emoji (the last row holds indices 9...12); category B: 2 emoji.
        let catalog = (0..<13).map {
            Emoji(emoji: "a\($0)", description: "a \($0)", category: "A", aliases: ["a_\($0)"], tags: [])
        } + (0..<2).map {
            Emoji(emoji: "b\($0)", description: "b \($0)", category: "B", aliases: ["b_\($0)"], tags: [])
        }
        let index = CatalogIndex(catalog: catalog)
        let model = EmojiPickerModel(
            catalog: PickerCatalog(index: index),
            search: EmojiSearch(index: index),
            frecency: EmojiFrecency(defaults: defaults)
        )
        #expect(model.sections.map(\.emojis.count) == [13, 2])

        model.select(model.sections[0].emojis[12], in: 0)
        model.move(.down)

        #expect(model.selection == PickerSelection(section: 1, index: 1))
    }
}

// MARK: - Frecency

@Suite("EmojiFrecency")
@MainActor
struct EmojiFrecencyTests {

    @Test("decay reorders top(): an old frequent pick falls behind a recent one")
    func decayReordersTop() {
        let name = UserDefaults.testSuiteDirectory + "/com.popguy.test.emojifrecency.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let monthAgo = Date(timeIntervalSince1970: 1_000_000_000)
        let now = monthAgo.addingTimeInterval(30 * 86_400)
        let frecency = EmojiFrecency(defaults: defaults)
        for _ in 0..<3 { frecency.record("😂", now: monthAgo) }
        frecency.record("👍", now: now)

        #expect(frecency.top(2, now: monthAgo) == ["😂", "👍"])
        #expect(frecency.top(2, now: now) == ["👍", "😂"])
    }
}
