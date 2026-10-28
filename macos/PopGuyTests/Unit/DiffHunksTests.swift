// DiffHunksTests.swift
// PopGuyTests
//
// Swift Testing suite for DiffHunks (per-hunk accept/reject helpers).
//
// Properties under test:
//   - A hunk is a maximal run of consecutive non-.equal segments.
//   - merged(rejected: []) == improved; merged(rejected: all) == original.
//   - Out-of-range rejected indices are ignored.
//   - DiffView.makeAttributedString: changed runs link to their hunk, colours,
//     strikethrough, rejected hunks dimmed, text kept literal.

import AppKit
import Testing
@testable import PopGuy

private func eq(_ text: String) -> DiffSegment { DiffSegment(kind: .equal, text: text) }
private func ins(_ text: String) -> DiffSegment { DiffSegment(kind: .inserted, text: text) }
private func del(_ text: String) -> DiffSegment { DiffSegment(kind: .deleted, text: text) }

@Suite("DiffHunks")
struct DiffHunksTests {

    // MARK: - hunkRanges

    @Test("equal-only segments have no hunks")
    func equalOnlyHasNoHunks() {
        #expect(DiffHunks.hunkRanges([eq("Hello "), eq("world")]).isEmpty)
    }

    @Test("adjacent deleted+inserted form one hunk")
    func adjacentChangesFormOneHunk() {
        let segments = [eq("The "), del("cat"), ins("dog"), eq(" ran")]
        #expect(DiffHunks.hunkRanges(segments) == [1..<3])
    }

    @Test("hunks separated by equal text are distinct")
    func separatedHunksAreDistinct() {
        let segments = [del("A"), ins("B"), eq(" mid "), ins("C")]
        #expect(DiffHunks.hunkRanges(segments) == [0..<2, 3..<4])
    }

    // MARK: - hunkIndices

    @Test("hunkIndices aligns each segment with its hunk, nil for equal")
    func hunkIndicesAlignment() {
        let segments = [eq("x "), del("A"), ins("B"), eq(" mid "), ins("C"), eq(".")]
        #expect(DiffHunks.hunkIndices(segments) == [nil, 0, 0, nil, 1, nil])
    }

    // MARK: - merged

    @Test("mixed case: rejecting only the second hunk")
    func rejectSecondHunkOnly() {
        // original: "The cat ran fast."  improved: "The dog ran slowly."
        let segments = [eq("The "), del("cat"), ins("dog"), eq(" ran "), del("fast"), ins("slowly"), eq(".")]
        #expect(DiffHunks.merged(segments: segments, rejected: []) == "The dog ran slowly.")
        #expect(DiffHunks.merged(segments: segments, rejected: [0, 1]) == "The cat ran fast.")
        #expect(DiffHunks.merged(segments: segments, rejected: [1]) == "The dog ran fast.")
    }

    @Test("out-of-range rejected indices are ignored")
    func outOfRangeRejectedIgnored() {
        let segments = [eq("The "), del("cat"), ins("dog")]
        #expect(DiffHunks.merged(segments: segments, rejected: [-1, 5]) == "The dog")
    }

    @Test(
        "nothing rejected == improved, all rejected == original",
        arguments: [
            ("Hello world", "Hello brave new world"),                 // insert-only
            ("Hello brave new world", "Hello world"),                 // delete-only
            ("The cat sat on the mat.", "The dog sat on a rug."),     // replace
            ("First para here.\n\nSecond one is old.", "First paragraph here.\n\nSecond one is new.\n\nThird."), // multi-paragraph
            ("", "Brand new"),
            ("Same text", "Same text"),
        ]
    )
    func invariants(original: String, improved: String) {
        let segments = DiffAlgorithm.diff(original: original, improved: improved)
        let all = Set(DiffHunks.hunkRanges(segments).indices)
        #expect(DiffHunks.merged(segments: segments, rejected: []) == improved)
        #expect(DiffHunks.merged(segments: segments, rejected: all) == original)
    }
}

// MARK: - DiffView.makeAttributedString

/// Attributes of the run that starts at the first occurrence of `text`.
@MainActor
private func attributes(of text: String, in string: NSAttributedString) -> [NSAttributedString.Key: Any] {
    let range = (string.string as NSString).range(of: text)
    precondition(range.location != NSNotFound, "missing run \(text)")
    return string.attributes(at: range.location, effectiveRange: nil)
}

@MainActor
@Suite("DiffView attributed string")
struct DiffViewAttributedStringTests {

    private let font = NSFont.systemFont(ofSize: 13)

    private func make(_ segments: [DiffSegment], rejected: Set<Int> = []) -> NSAttributedString {
        DiffView.makeAttributedString(segments: segments, rejected: rejected, font: font)
    }

    @Test("equal runs carry no link")
    func equalRunHasNoLink() {
        let string = make([eq("The "), del("cat"), ins("dog")])
        #expect(attributes(of: "The ", in: string)[.link] == nil)
    }

    @Test("inserted run links to its hunk and is green")
    func insertedRunLinkAndColour() {
        let string = make([eq("The "), ins("dog")])
        let attrs = attributes(of: "dog", in: string)
        #expect(attrs[.link] as? URL == URL(string: "popguy-hunk://0"))
        #expect(attrs[.foregroundColor] as? NSColor == NSColor.systemGreen)
    }

    @Test("deleted run is red with strikethrough")
    func deletedRunRedStrikethrough() {
        let string = make([eq("The "), del("cat")])
        let attrs = attributes(of: "cat", in: string)
        #expect(attrs[.foregroundColor] as? NSColor == NSColor.systemRed)
        #expect(attrs[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("rejected hunk is dimmed, accepted hunk is not")
    func rejectedHunkDimmed() {
        let string = make([del("A"), eq(" mid "), ins("B")], rejected: [1])
        let accepted = attributes(of: "A", in: string)[.foregroundColor] as? NSColor
        let rejected = attributes(of: "B", in: string)[.foregroundColor] as? NSColor
        #expect(accepted?.alphaComponent == 1)
        #expect((rejected?.alphaComponent ?? 1) < 1)
    }

    @Test("markdown in segment text stays literal")
    func markdownStaysLiteral() {
        let string = make([eq("a "), ins("**x**")])
        #expect(string.string == "a **x**")
    }

    @Test("two hunks link to indices 0 and 1")
    func twoHunksIndices() {
        let string = make([eq("x "), del("A"), ins("B"), eq(" mid "), ins("C")])
        #expect(attributes(of: "A", in: string)[.link] as? URL == URL(string: "popguy-hunk://0"))
        #expect(attributes(of: "B", in: string)[.link] as? URL == URL(string: "popguy-hunk://0"))
        #expect(attributes(of: "C", in: string)[.link] as? URL == URL(string: "popguy-hunk://1"))
    }
}
