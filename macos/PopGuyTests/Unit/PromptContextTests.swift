// PromptContextTests.swift
// PopGuyTests
//
// Swift Testing suite for PromptContext and PromptTemplate.expand.
//
// Properties under test:
//   - All context tokens and {{text}} expand in a single left-to-right pass.
//   - Substituted values are never re-scanned (no token injection).
//   - consumedText reflects the template only, never the substituted values.
//   - Unknown and unterminated tokens stay literal.

import Foundation
import Testing
@testable import PopGuy

@Suite("PromptContext")
struct PromptContextTests {

    private let context = PromptContext(
        appName: "Safari",
        domain: "example.com",
        date: "2026-10-08",
        language: "fr"
    )

    @Test("All four context tokens expand")
    func contextTokensExpand() {
        let result = PromptTemplate.expand(
            "{{app}}|{{domain}}|{{date}}|{{language}}",
            text: "sel",
            context: context
        )
        #expect(result.output == "Safari|example.com|2026-10-08|fr")
        #expect(result.consumedText == false)
    }

    @Test("{{text}} expands and sets consumedText")
    func textTokenExpands() {
        let result = PromptTemplate.expand("Fix: {{text}}", text: "hello", context: context)
        #expect(result.output == "Fix: hello")
        #expect(result.consumedText == true)
    }

    @Test("Selection containing a token stays literal")
    func selectionNotRescanned() {
        let result = PromptTemplate.expand("{{text}}", text: "see {{app}}", context: context)
        #expect(result.output == "see {{app}}")
        #expect(result.consumedText == true)
    }

    @Test("App name equal to {{text}} is not spliced; consumedText follows the template")
    func contextValueNotRescanned() {
        let ctx = PromptContext(appName: "{{text}}", domain: "", date: "", language: "")
        let result = PromptTemplate.expand("From {{app}}", text: "secret", context: ctx)
        #expect(result.output == "From {{text}}")
        #expect(result.consumedText == false)
    }

    @Test("Unknown and unterminated tokens stay literal")
    func unknownAndUnterminatedLiteral() {
        let result = PromptTemplate.expand("{{foo}} and {{app", text: "x", context: context)
        #expect(result.output == "{{foo}} and {{app")
        #expect(result.consumedText == false)
    }

    @Test("Empty context values expand to empty")
    func emptyValues() {
        let result = PromptTemplate.expand("[{{app}}][{{domain}}][{{date}}][{{language}}]", text: nil, context: .empty)
        #expect(result.output == "[][][][]")
    }

    @Test("text: nil keeps {{text}} literal")
    func nilTextKeepsToken() {
        let result = PromptTemplate.expand("{{text}} on {{app}}", text: nil, context: context)
        #expect(result.output == "{{text}} on Safari")
        #expect(result.consumedText == false)
    }

    // MARK: - PromptContext

    @Test("dateString formats yyyy-MM-dd in the given time zone")
    func dateStringFormat() throws {
        // 2026-10-08T12:00:00Z
        let date = Date(timeIntervalSince1970: 1_791_460_800)
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(PromptContext.dateString(for: date, timeZone: utc) == "2026-10-08")
    }

    @Test("Newlines and control characters collapse to a single line")
    func valuesFlattened() {
        let ctx = PromptContext(appName: "  My\nApp\t\r\nX  ", domain: "a\u{0}b", date: "", language: "")
        #expect(ctx.appName == "My App X")
        #expect(ctx.domain == "a b")
    }
}
