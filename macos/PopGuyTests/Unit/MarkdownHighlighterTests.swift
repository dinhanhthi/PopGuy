// MarkdownHighlighterTests.swift
// PopGuyTests
//
// Tests for the Terminal Composer's Markdown highlighter (pure text → runs).
// Covers:
//   - Fenced code (closed and unclosed) is code, and no inline rules apply inside it
//   - Inline code and a heading on prose lines get UTF-16 ranges (after an emoji)

import Foundation
import Testing
@testable import PopGuy

@Suite("Terminal Composer Markdown highlighter")
struct MarkdownHighlighterTests {

    @Test("fenced code (closed and unclosed) is code, with no inline rules inside")
    func fencedCodeIsCode() {
        let text = "Intro **bold**\n```swift\nlet a = `b` **c** _d_\n```\nAfter\n~~~\n**open**"
        let ns = text as NSString
        let runs = MarkdownHighlighter.runs(in: text)

        #expect(runs.contains(HighlightRun(range: ns.range(of: "**bold**"), style: .bold)))
        #expect(runs.contains(HighlightRun(range: ns.range(of: "```swift"), style: .codeFence)))
        #expect(runs.contains(HighlightRun(range: ns.range(of: "let a = `b` **c** _d_"), style: .codeBlock)))
        #expect(runs.contains(HighlightRun(range: ns.range(of: "```\n").prefix3, style: .codeFence)))
        // The unclosed "~~~" fence runs to the end of the text.
        #expect(runs.contains(HighlightRun(range: ns.range(of: "~~~"), style: .codeFence)))
        #expect(runs.contains(HighlightRun(range: ns.range(of: "**open**"), style: .codeBlock)))

        // Only the prose "**bold**" gets an inline style; nothing inside the fences.
        let inlineStyles: [HighlightRun.Style] = [.bold, .italic, .inlineCode]
        let inline = runs.filter { inlineStyles.contains($0.style) }
        #expect(inline == [HighlightRun(range: ns.range(of: "**bold**"), style: .bold)])
    }

    @Test("inline code and a heading get UTF-16 ranges after non-ASCII text")
    func inlineCodeAndHeadingRanges() {
        let text = "Café 🎉 uses `x_y *z*` here\n## Title 😀 `k`\nsnake_case_words and *it* _em_"
        let ns = text as NSString
        let runs = MarkdownHighlighter.runs(in: text)

        let code = ns.range(of: "`x_y *z*`")
        #expect(runs.contains(HighlightRun(range: code, style: .inlineCode)))
        #expect(runs.contains(HighlightRun(range: ns.range(of: "## Title 😀 `k`"), style: .heading(level: 2))))
        #expect(runs.contains(HighlightRun(range: ns.range(of: "`k`"), style: .inlineCode)))
        #expect(runs.contains(HighlightRun(range: ns.range(of: "*it*"), style: .italic)))
        #expect(runs.contains(HighlightRun(range: ns.range(of: "_em_"), style: .italic)))

        // No italic inside inline code, and snake_case is not italic.
        let italics = runs.filter { $0.style == .italic }.map(\.range)
        #expect(italics == [ns.range(of: "*it*"), ns.range(of: "_em_")])
        #expect(!italics.contains { NSIntersectionRange($0, code).length > 0 })
    }
}

private extension NSRange {
    /// The first three characters of the range (a fence without its newline).
    var prefix3: NSRange { NSRange(location: location, length: 3) }
}
