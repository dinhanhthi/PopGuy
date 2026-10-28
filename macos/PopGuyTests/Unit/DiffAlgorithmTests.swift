// DiffAlgorithmTests.swift
// PopGuyTests
//
// Table-driven Swift Testing suite for DiffAlgorithm.
// Autopilot gate: xcodebuild test must pass with these cases.
//
// Property under test:
//   - Round-trip invariant: joining (equal+deleted) segments == original;
//     joining (equal+inserted) segments == improved.
//   - Correctness of segment kinds for common cases.

import Testing
@testable import PopGuy

// MARK: - Helpers

private func reconstruct(original reconstructing: Bool, _ segments: [DiffSegment]) -> String {
    segments.compactMap { segment in
        switch segment.kind {
        case .equal:    return segment.text
        case .deleted:  return reconstructing ? segment.text : nil
        case .inserted: return reconstructing ? nil : segment.text
        }
    }.joined()
}

private func reconstructOriginal(_ segments: [DiffSegment]) -> String {
    reconstruct(original: true, segments)
}

private func reconstructImproved(_ segments: [DiffSegment]) -> String {
    reconstruct(original: false, segments)
}

// MARK: - DiffAlgorithmTests

@Suite("DiffAlgorithm")
struct DiffAlgorithmTests {

    // MARK: - Identical strings

    @Test("Identical strings produce only .equal segments")
    func identicalStrings() {
        let input = "Hello world"
        let result = DiffAlgorithm.diff(original: input, improved: input)
        #expect(result.allSatisfy { $0.kind == .equal })
        #expect(reconstructOriginal(result) == input)
        #expect(reconstructImproved(result) == input)
    }

    @Test("Empty identical strings produce no segments")
    func bothEmpty() {
        let result = DiffAlgorithm.diff(original: "", improved: "")
        #expect(result.isEmpty)
    }

    // MARK: - Pure insertion

    @Test("Empty original produces all .inserted segments")
    func emptyOriginal() {
        let improved = "Hello world"
        let result = DiffAlgorithm.diff(original: "", improved: improved)
        #expect(result.allSatisfy { $0.kind == .inserted })
        #expect(reconstructOriginal(result) == "")
        #expect(reconstructImproved(result) == improved)
    }

    @Test("Pure insertion (words appended to end)")
    func pureInsertionAtEnd() {
        let original = "Hello"
        let improved = "Hello world today"
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
        // No deleted segments
        #expect(!result.contains { $0.kind == .deleted })
    }

    @Test("Pure insertion (words prepended)")
    func pureInsertionAtStart() {
        let original = "world"
        let improved = "Hello world"
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
        #expect(!result.contains { $0.kind == .deleted })
    }

    // MARK: - Pure deletion

    @Test("Empty improved produces all .deleted segments")
    func emptyImproved() {
        let original = "Hello world"
        let result = DiffAlgorithm.diff(original: original, improved: "")
        #expect(result.allSatisfy { $0.kind == .deleted })
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == "")
    }

    @Test("Pure deletion (words removed from end)")
    func pureDeletionAtEnd() {
        let original = "Hello world today"
        let improved = "Hello"
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
        #expect(!result.contains { $0.kind == .inserted })
    }

    // MARK: - Mixed edits

    @Test("Mixed edit: word replaced in middle")
    func mixedEditWordReplaced() {
        let original = "The quick brown fox"
        let improved = "The slow brown fox"
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
        #expect(result.contains { $0.kind == .deleted })
        #expect(result.contains { $0.kind == .inserted })
        #expect(result.contains { $0.kind == .equal })
    }

    @Test("Mixed edit: multiple words changed")
    func mixedEditMultipleWords() {
        let original = "The quick brown fox jumps"
        let improved = "A slow red cat leaps"
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
    }

    @Test("Mixed edit: word inserted in middle")
    func mixedEditInsertInMiddle() {
        let original = "foo bar baz"
        let improved  = "foo INSERTED bar baz"
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
    }

    // MARK: - Whitespace sensitivity

    @Test("Leading and trailing whitespace is preserved in round-trip")
    func whitespacePreservation() {
        let original = "  hello world  "
        let improved = "  hi world  "
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
    }

    @Test("Multiple internal spaces round-trip correctly")
    func multipleInternalSpaces() {
        let original = "a  b  c"
        let improved = "a  b  c"
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
    }

    // MARK: - Realistic prose

    @Test("Realistic prose: short sentence improvement")
    func realisticProse() {
        let original = "This is a very long and complicated sentence that could be improved."
        let improved = "This is a clear and concise sentence."
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original)
        #expect(reconstructImproved(result) == improved)
        // Must have both additions and deletions
        #expect(result.contains { $0.kind == .inserted })
        #expect(result.contains { $0.kind == .deleted })
    }

    // MARK: - Round-trip invariant (parametric)

    @Test(
        "Round-trip invariant holds for all parametric cases",
        arguments: [
            ("", ""),
            ("hello", "hello"),
            ("", "new text here"),
            ("old text here", ""),
            ("foo bar baz", "foo baz"),
            ("foo baz", "foo bar baz"),
            ("one two three", "one 2 three"),
            ("The quick brown fox", "The lazy dog"),
        ]
    )
    func roundTripInvariant(original: String, improved: String) {
        let result = DiffAlgorithm.diff(original: original, improved: improved)
        #expect(reconstructOriginal(result) == original,
                "original round-trip failed for (\(original.debugDescription), \(improved.debugDescription))")
        #expect(reconstructImproved(result) == improved,
                "improved round-trip failed for (\(original.debugDescription), \(improved.debugDescription))")
    }

    // MARK: - Segment properties

    @Test("No adjacent segments have the same kind (LCS is minimal)")
    func noAdjacentSameKind() {
        // Adjacent equal segments are always merged — verify for a standard case.
        let result = DiffAlgorithm.diff(original: "a b c d", improved: "a x c d")
        for i in 0..<(result.count - 1) {
            // Adjacent segments of the same kind would be wasteful / wrong for equal;
            // for inserted/deleted it's potentially valid but our implementation avoids it.
            if result[i].kind == .equal {
                #expect(result[i + 1].kind != .equal,
                        "Adjacent equal segments at \(i) and \(i+1)")
            }
        }
    }

    @Test("DiffSegment equality based on kind and text")
    func segmentEquality() {
        let a = DiffSegment(kind: .equal, text: "hello")
        let b = DiffSegment(kind: .equal, text: "hello")
        let c = DiffSegment(kind: .inserted, text: "hello")
        #expect(a == b)
        #expect(a != c)
    }
}
