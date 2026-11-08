// EmojiSearch.swift
// PopGuy — EmojiPicker
//
// Fuzzy, case- and accent-insensitive search over the emoji and symbol catalog (ported from
// FastMoji), ranked by text score then usage frecency.
//
// Isolation: nonisolated — immutable index and pure scoring, usable from any context.

import Foundation

nonisolated private enum Score {
    static let base = 10.0
    static let exactAlias = 100.0
    static let prefix = 30.0
    static let wordBoundary = 15.0
    static let consecutive = 5.0
    static let gap = 1.0
    static let aliasWeight = 2.0
    static let descriptionWeight = 1.0
    static let tagWeight = 0.0
    /// Taken off symbol scores, so emoji lead unless the match is much better; an exact alias
    /// (`cmd` → ⌘) still beats an emoji prefix match.
    static let nonEmojiPenalty = 25.0
    /// Max frecency bonus = 10 * 0.25 = 2.5, below one consecutive-char bonus.
    static let frecencyCap = 10.0
    static let frecencyFactor = 0.25
}

// MARK: - CatalogIndex

/// Read-only search data built once from the decoded rows and shared by every picker.
nonisolated final class CatalogIndex: Sendable {
    fileprivate struct Field: Sendable {
        let scalars: [Unicode.Scalar]
        let isAlias: Bool
        /// Tags and keywords: matched contiguously only (see `EmojiSearch.score`).
        let isTag: Bool
        let weight: Double
    }

    /// The catalog with `keywords` dropped (they only live folded in `fields`, to save memory).
    /// The single source of `Emoji` values, so results compare equal to everything built from it.
    let emojis: [Emoji]
    /// Folded, deduped searchable texts per emoji, same order as `emojis`.
    fileprivate let fields: [[Field]]

    init(catalog: [Emoji]) {
        fields = catalog.map { emoji in
            // Highest weight first, so dedup keeps the best weight and its flags.
            let texts = emoji.aliases.map { ($0, true, false, Score.aliasWeight) }
                + [(emoji.description, false, false, Score.descriptionWeight)]
                + (emoji.tags + (emoji.keywords ?? [])).map { ($0, false, true, Score.tagWeight) }
            var seen: Set<String> = []
            return texts.compactMap { text, isAlias, isTag, weight in
                let folded = Self.fold(text)
                guard seen.insert(folded).inserted else { return nil }
                return Field(scalars: Array(folded.unicodeScalars), isAlias: isAlias, isTag: isTag, weight: weight)
            }
        }
        emojis = catalog.map { emoji in
            var stripped = emoji
            stripped.keywords = nil
            return stripped
        }
    }

    /// Case- and accent-insensitive form used for both fields and queries ("Cười" → "cuoi").
    /// Folding keeps the Vietnamese "đ" (a letter, not d + accent) and the French "œ" (a ligature),
    /// so they are mapped by hand: "cœur" is found by typing `coeur`. Case folding already turns
    /// "Œ" into "œ".
    static func fold(_ text: String) -> String {
        // Most texts are plain ASCII, where folding is just lowercasing (and much faster).
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        return text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
            .replacingOccurrences(of: "œ", with: "oe")
    }
}

// MARK: - EmojiSearch

/// Fuzzy subsequence search over the catalog, ranked by text score then frecency.
nonisolated struct EmojiSearch: Sendable {
    let index: CatalogIndex

    init(index: CatalogIndex) {
        self.index = index
    }

    init(catalog: [Emoji]) {
        self.init(index: CatalogIndex(catalog: catalog))
    }

    /// Matching emoji and symbols, best first. An empty query returns the catalog order.
    /// Ties keep catalog order (emoji, then symbols), so grouping the result by `kind` in order of
    /// first appearance gives sections ordered by best score, emoji first on ties.
    func search(_ query: String, frecency: (String) -> Double) -> [Emoji] {
        let folded = CatalogIndex.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let q = Array(folded.unicodeScalars)
        guard !q.isEmpty else { return index.emojis }

        var hits: [(index: Int, score: Double)] = []
        for (i, emojiFields) in index.fields.enumerated() {
            var best: Double?
            for field in emojiFields {
                guard let s = Self.score(q, in: field) else { continue }
                best = max(best ?? s, s)
            }
            guard var score = best else { continue }
            let emoji = index.emojis[i]
            if emoji.kind != nil { score -= Score.nonEmojiPenalty }
            let bonus = min(frecency(emoji.emoji), Score.frecencyCap) * Score.frecencyFactor
            hits.append((i, score + max(0, bonus)))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return hits.map { index.emojis[$0.index] }
    }

    /// Best subsequence score of `q` in `field`, trying every start position; nil if no match.
    /// Minimum match rule: a start inside a word counts only when the whole query follows it
    /// contiguously, so scattered letters don't match (`yeet` must not find "lady_beetle").
    /// Tags and keywords (many per emoji, often long phrases) need that at every start, word
    /// starts included: a scattered match there only adds unrelated results to the tail.
    private static func score(_ q: [Unicode.Scalar], in field: CatalogIndex.Field) -> Double? {
        let f = field.scalars
        guard q.count <= f.count else { return nil }
        if field.isAlias && f == q { return Score.exactAlias + Score.base + field.weight }

        let isPrefix = f.starts(with: q)
        var best: Double?
        for start in f.indices where f[start] == q[0] {
            let atBoundary = start == 0 || isSeparator(f[start - 1])
            if !atBoundary || field.isTag {
                // A contiguous match also scores best among in-word starts, so skipping the rest
                // is the same as allowing any match once the query is a substring.
                guard start + q.count <= f.count, f[start..<start + q.count].elementsEqual(q) else { continue }
            }
            guard let s = matchScore(q, f, from: start) else { break } // later starts cannot match either
            best = max(best ?? s, s)
        }
        guard let best else { return nil }
        return best + (isPrefix ? Score.prefix : 0) + field.weight
    }

    /// Greedy forward match of `q` in `f` starting with `q[0]` at `start`.
    private static func matchScore(_ q: [Unicode.Scalar], _ f: [Unicode.Scalar], from start: Int) -> Double? {
        var score = Score.base
        if start == 0 || isSeparator(f[start - 1]) { score += Score.wordBoundary }
        var last = start
        var qi = 1
        var fi = start + 1
        while qi < q.count && fi < f.count {
            if f[fi] == q[qi] {
                score += fi == last + 1 ? Score.consecutive : -Score.gap * Double(fi - last - 1)
                last = fi
                qi += 1
            }
            fi += 1
        }
        return qi == q.count ? score : nil
    }

    private static func isSeparator(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c == "-" || c == " "
    }
}
