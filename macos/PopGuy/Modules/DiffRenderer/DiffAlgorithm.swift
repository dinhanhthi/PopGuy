// DiffAlgorithm.swift
// PopGuy — DiffRenderer
//
// Pure, deterministic word-level diff using the standard LCS (longest common
// subsequence) algorithm.  No third-party library — HARD CONSTRAINT.
//
// Public surface:
//   DiffKind    — .equal / .inserted / .deleted
//   DiffSegment — (kind, text) value type; Equatable, Sendable
//   DiffAlgorithm.diff(original:improved:) -> [DiffSegment]
//
// Isolation:
//   All types are nonisolated value types that conform to Sendable.
//   The `nonisolated` prefix opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
//   so the algorithm can be called from any actor without a crossing cost.
//
// Tokenization strategy:
//   Split on whitespace using a greedy "word + trailing whitespace" scheme so
//   that concatenating all tokens reproduces the original string byte-for-byte
//   (round-trip invariant).  Specifically: we keep any leading whitespace as
//   a synthetic prefix token, then each real word carries its trailing spaces.
//   This guarantees that reconstructOriginal(diff(o,i)) == o and
//   reconstructImproved(diff(o,i)) == i for all inputs.

import Foundation

// MARK: - DiffKind

/// The role of a single segment in a diff.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum DiffKind: Equatable, Sendable {
    /// Text present in both original and improved.
    case equal
    /// Text present only in the improved string (addition).
    case inserted
    /// Text present only in the original string (deletion).
    case deleted
}

// MARK: - DiffSegment

/// A single run of text that belongs to one of the three diff roles.
nonisolated struct DiffSegment: Equatable, Sendable {
    let kind: DiffKind
    let text: String

    init(kind: DiffKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

// MARK: - DiffAlgorithm

/// Namespace for the diff algorithm.
///
/// The implementation:
///   1. Tokenizes both strings into "word tokens" (each token = word + its
///      trailing whitespace, except a leading-whitespace prefix if present).
///   2. Runs a standard O(m·n) LCS dynamic-programming algorithm on the token
///      arrays.
///   3. Walks back through the LCS table to emit DiffSegment values.
///   4. Merges adjacent segments of the same kind for a clean output.
nonisolated enum DiffAlgorithm {

    // MARK: - Public entry point

    /// Compute the diff between `original` and `improved`.
    ///
    /// The returned array satisfies the **round-trip invariant**:
    ///   - Concatenating all `.equal` and `.deleted` segments reproduces `original`.
    ///   - Concatenating all `.equal` and `.inserted` segments reproduces `improved`.
    static func diff(original: String, improved: String) -> [DiffSegment] {
        let oldTokens = tokenize(original)
        let newTokens = tokenize(improved)

        // Fast paths.
        if oldTokens.isEmpty && newTokens.isEmpty { return [] }
        if oldTokens.isEmpty {
            return merge(newTokens.map { DiffSegment(kind: .inserted, text: $0) })
        }
        if newTokens.isEmpty {
            return merge(oldTokens.map { DiffSegment(kind: .deleted, text: $0) })
        }
        if oldTokens == newTokens {
            return merge(oldTokens.map { DiffSegment(kind: .equal, text: $0) })
        }

        let raw = lcsDiff(old: oldTokens, new: newTokens)
        return merge(raw)
    }

    // MARK: - Tokenizer

    /// Splits a string into alternating word and whitespace tokens such that
    /// `tokens.joined() == s` (round-trip invariant).
    ///
    /// Whitespace runs and word runs alternate.  This ensures the LCS finds
    /// matches based on word identity alone — "Hello" in "Hello" always matches
    /// "Hello" in "Hello world today" regardless of surrounding whitespace.
    ///
    /// Example: "  hello  world " → ["  ", "hello", "  ", "world", " "]
    /// Example: "Hello world"     → ["Hello", " ", "world"]
    static func tokenize(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        // Track whether we're currently building a whitespace run or a word run.
        var buildingWhitespace = s.unicodeScalars.first.map { $0.properties.isWhitespace } ?? false

        for ch in s {
            let isSpace = ch.isWhitespace
            if isSpace == buildingWhitespace {
                // Same kind — keep accumulating.
                current.append(ch)
            } else {
                // Kind changed — emit what we have and start a new run.
                if !current.isEmpty { tokens.append(current) }
                current = String(ch)
                buildingWhitespace = isSpace
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - LCS diff

    /// Classic O(m·n) LCS-based diff that emits raw (un-merged) DiffSegment array.
    private static func lcsDiff(old: [String], new: [String]) -> [DiffSegment] {
        let m = old.count
        let n = new.count

        // Build the LCS table.
        // dp[i][j] = length of LCS of old[0..<i] and new[0..<j].
        // Use a flat array for cache locality.
        var dp = [Int](repeating: 0, count: (m + 1) * (n + 1))

        func idx(_ i: Int, _ j: Int) -> Int { i * (n + 1) + j }

        for i in 1...m {
            for j in 1...n {
                if old[i - 1] == new[j - 1] {
                    dp[idx(i, j)] = dp[idx(i - 1, j - 1)] + 1
                } else {
                    dp[idx(i, j)] = max(dp[idx(i - 1, j)], dp[idx(i, j - 1)])
                }
            }
        }

        // Walk back to produce the diff.
        var segments: [DiffSegment] = []
        var i = m
        var j = n

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && old[i - 1] == new[j - 1] {
                segments.append(DiffSegment(kind: .equal, text: old[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[idx(i, j - 1)] >= dp[idx(i - 1, j)]) {
                segments.append(DiffSegment(kind: .inserted, text: new[j - 1]))
                j -= 1
            } else {
                segments.append(DiffSegment(kind: .deleted, text: old[i - 1]))
                i -= 1
            }
        }

        segments.reverse()
        return segments
    }

    // MARK: - Merge adjacent same-kind segments

    private static func merge(_ segments: [DiffSegment]) -> [DiffSegment] {
        guard !segments.isEmpty else { return [] }
        var result: [DiffSegment] = []
        var current = segments[0]
        for next in segments.dropFirst() {
            if next.kind == current.kind {
                current = DiffSegment(kind: current.kind, text: current.text + next.text)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }
}
