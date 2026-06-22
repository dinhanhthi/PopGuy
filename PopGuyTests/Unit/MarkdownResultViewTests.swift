// MarkdownResultViewTests.swift
// PopGuyTests
//
// Unit tests for `classifyLines` and `strippedAttributedString` used by MarkdownResultView.
// Tests are isolated to the pure logic; no SwiftUI rendering.

import Foundation
import Testing
@testable import PopGuy

// MARK: - MarkdownResultViewTests

@Suite("MarkdownResultView — classifyLines")
@MainActor
struct MarkdownResultViewTests {

    // MARK: - Bullet lines

    @Test("dash-prefixed line is classified as bullet")
    func bulletDashLine() {
        let lines = classifyLines("- alpha")
        guard case .bullet(let content) = lines.first else {
            Issue.record("Expected .bullet, got \(String(describing: lines.first))")
            return
        }
        #expect(content == "alpha")
    }

    // MARK: - Ordered list lines

    @Test("single-digit ordered line is classified correctly")
    func orderedSingleDigit() {
        let lines = classifyLines("1. one")
        guard case .ordered(let number, let content) = lines.first else {
            Issue.record("Expected .ordered, got \(String(describing: lines.first))")
            return
        }
        #expect(number == 1)
        #expect(content == "one")
    }

    @Test("two-digit ordered line is classified correctly")
    func orderedTwoDigits() {
        let lines = classifyLines("10. item")
        guard case .ordered(let number, let content) = lines.first else {
            Issue.record("Expected .ordered, got \(String(describing: lines.first))")
            return
        }
        #expect(number == 10)
        #expect(content == "item")
    }

    // MARK: - Paragraph lines

    @Test("plain prose line is classified as paragraph")
    func plainParagraph() {
        let lines = classifyLines("Just a regular sentence.")
        guard case .paragraph(let content) = lines.first else {
            Issue.record("Expected .paragraph, got \(String(describing: lines.first))")
            return
        }
        #expect(content == "Just a regular sentence.")
    }

    @Test("empty string produces paragraph with empty content")
    func emptyLineIsParagraph() {
        let lines = classifyLines("")
        guard case .paragraph(let content) = lines.first else {
            Issue.record("Expected .paragraph, got \(String(describing: lines.first))")
            return
        }
        #expect(content == "")
    }

    @Test("bullet marker with no content is classified as paragraph")
    func bulletWithNoContent() {
        // "- " (dash space, empty content after) is NOT treated as a bullet because
        // the classifier requires at least one trailing character.
        let lines = classifyLines("- ")
        guard case .paragraph = lines.first else {
            Issue.record("Expected .paragraph for empty-content bullet, got \(String(describing: lines.first))")
            return
        }
    }

    // MARK: - Ordered-list digit bound (1–2 digits max)

    @Test("4-digit year-initial sentence is not classified as ordered list item")
    func yearInitialSentenceIsNotOrdered() {
        // "2026. Something" starts with 4 digits before the period — the tightened
        // /^(\d{1,2})\./ regex requires at most 2 digits, so this must fall through
        // to .paragraph. This guards against the previous /^(\d+)\./ unbounded match.
        let lines = classifyLines("2026. Something happened this year.")
        guard case .paragraph = lines.first else {
            Issue.record("Expected .paragraph for 4-digit year sentence, got \(String(describing: lines.first))")
            return
        }
    }

    // MARK: - Alternate bullet markers

    @Test("star-prefixed line is classified as bullet")
    func bulletStarLine() {
        let lines = classifyLines("* star")
        guard case .bullet(let content) = lines.first else {
            Issue.record("Expected .bullet for '* star', got \(String(describing: lines.first))")
            return
        }
        #expect(content == "star")
    }

    @Test("plus-prefixed line is classified as bullet")
    func bulletPlusLine() {
        let lines = classifyLines("+ plus")
        guard case .bullet(let content) = lines.first else {
            Issue.record("Expected .bullet for '+ plus', got \(String(describing: lines.first))")
            return
        }
        #expect(content == "plus")
    }

    // MARK: - Multi-line classifyLines

    @Test("multi-line input produces correct 4-element classification")
    func multiLineClassification() {
        let lines = classifyLines("- alpha\n1. item\n\nplain")
        #expect(lines.count == 4)

        guard case .bullet(let c0) = lines[0] else {
            Issue.record("lines[0]: expected .bullet, got \(lines[0])")
            return
        }
        #expect(c0 == "alpha")

        guard case .ordered(let num, let c1) = lines[1] else {
            Issue.record("lines[1]: expected .ordered, got \(lines[1])")
            return
        }
        #expect(num == 1)
        #expect(c1 == "item")

        guard case .paragraph(let c2) = lines[2] else {
            Issue.record("lines[2]: expected .paragraph, got \(lines[2])")
            return
        }
        #expect(c2 == "")

        guard case .paragraph(let c3) = lines[3] else {
            Issue.record("lines[3]: expected .paragraph, got \(lines[3])")
            return
        }
        #expect(c3 == "plain")
    }
}

// MARK: - strippedAttributedString tests

@Suite("MarkdownResultView — strippedAttributedString")
struct StrippedAttributedStringTests {

    @Test("link attribute is removed from link markdown")
    func linkAttributeStripped() {
        let result = strippedAttributedString("[click](http://evil.example)")
        #expect(result.runs.allSatisfy { $0.link == nil })
        #expect(String(result.characters).contains("click"))
    }

    @Test("imageURL attribute is removed from image markdown")
    func imageAttributeStripped() {
        let result = strippedAttributedString("![x](http://tracker.example)")
        #expect(result.runs.allSatisfy { $0.imageURL == nil && $0.link == nil })
    }
}
