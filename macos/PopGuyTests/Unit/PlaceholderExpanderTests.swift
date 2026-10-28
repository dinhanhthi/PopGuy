// PlaceholderExpanderTests.swift
// PopGuyTests
//
// Unit tests for PlaceholderExpander — the injection-safety boundary for
// scriptable custom actions. The selected text is UNTRUSTED (attacker-crafted),
// so these tests deliberately use adversarial inputs to verify confinement.
//
// Replaces the uncalled #if DEBUG _selfCheck() block that was in
// PlaceholderExpander.swift — same invariants, now executed on every test run.
//
// Test framework: Swift Testing (import Testing, @Test / #expect).

import Foundation
import Testing
@testable import PopGuy

// MARK: - PlaceholderExpanderTests

@Suite("PlaceholderExpander")
struct PlaceholderExpanderTests {

    // MARK: - AppleScript expansion

    @Test("backslash and double-quote are both escaped (canonical case from original selfCheck)")
    func appleScriptCanonicalEscape() {
        // Input:    a"b\c
        // Expected: set x to "a\"b\\c"
        let result = PlaceholderExpander.expandAppleScript(
            source: "set x to \(PlaceholderExpander.textToken)",
            text: #"a"b\c"#
        )
        #expect(result == #"set x to "a\"b\\c""#)
    }

    @Test("AppleScript breakout attempt: shell-injection string stays inside literal")
    func appleScriptBreakoutShellInjection() {
        // An adversary tries to close the AppleScript string and inject a command:
        //   input:    "; do shell script "rm -rf ~"
        //   After escaping: \" and \"rm -rf ~\" inside a quoted literal.
        let malicious = #""; do shell script "rm -rf ~""#
        let result = PlaceholderExpander.expandAppleScript(
            source: "set x to \(PlaceholderExpander.textToken)",
            text: malicious
        )
        // The expander must have escaped each " → \" so the outer delimiters are
        // the ones it added.  The expansion must:
        //   1. Start with: set x to "
        //   2. End with:   "
        //   3. Contain the escaped injection sequence (\" not raw ").
        #expect(result.hasPrefix(#"set x to ""#))
        #expect(result.hasSuffix("\""))
        // The raw (unescaped) injection phrase must NOT appear verbatim — every "
        // in the selection must now be a \" sequence.
        #expect(!result.contains(#""; do shell script ""#))
        // The escaped version must be present.
        #expect(result.contains(#"\"; do shell script \""#))
    }

    @Test("backslash-only selection")
    func appleScriptBackslashOnly() {
        let result = PlaceholderExpander.expandAppleScript(
            source: PlaceholderExpander.textToken,
            text: "\\"
        )
        // Single backslash → "\\\\"  (four chars: quote, backslash, backslash, quote)
        #expect(result == "\"\\\\\"")
    }

    @Test("quote-only selection")
    func appleScriptQuoteOnly() {
        let result = PlaceholderExpander.expandAppleScript(
            source: PlaceholderExpander.textToken,
            text: "\""
        )
        // Single double-quote → "\\""
        #expect(result == "\"\\\"\"")
    }

    @Test("empty selection produces empty AppleScript string literal")
    func appleScriptEmpty() {
        let result = PlaceholderExpander.expandAppleScript(
            source: "set x to \(PlaceholderExpander.textToken)",
            text: ""
        )
        #expect(result == #"set x to """#)
    }

    @Test("newline in selection passes through literally (not escaped)")
    func appleScriptNewline() {
        // expandAppleScript escapes only \ and " — newline passes through verbatim.
        let result = PlaceholderExpander.expandAppleScript(
            source: PlaceholderExpander.textToken,
            text: "line1\nline2"
        )
        #expect(result == "\"line1\nline2\"")
    }

    @Test("unicode selection passes through literally")
    func appleScriptUnicode() {
        let result = PlaceholderExpander.expandAppleScript(
            source: PlaceholderExpander.textToken,
            text: "héllo wörld 🌍"
        )
        #expect(result == "\"héllo wörld 🌍\"")
    }

    @Test("multiple {text} tokens are all replaced")
    func appleScriptMultipleTokens() {
        let result = PlaceholderExpander.expandAppleScript(
            source: "\(PlaceholderExpander.textToken) and \(PlaceholderExpander.textToken)",
            text: "hi"
        )
        #expect(result == "\"hi\" and \"hi\"")
    }

    // MARK: - URL expansion

    @Test("& in selection is percent-encoded (no query-parameter injection)")
    func urlAmpersandEncoded() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/?q=\(PlaceholderExpander.textToken)",
            text: "a&b"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("%26"))
        #expect(!url!.absoluteString.contains("a&b"))
    }

    @Test("= in selection is percent-encoded (no key=value injection)")
    func urlEqualsEncoded() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/?q=\(PlaceholderExpander.textToken)",
            text: "key=value"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("%3D"))
    }

    @Test("? in selection is percent-encoded (no extra query string)")
    func urlQuestionMarkEncoded() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/search/\(PlaceholderExpander.textToken)",
            text: "foo?bar"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("%3F"))
        #expect(!url!.absoluteString.contains("foo?bar"))
    }

    @Test("# in selection is percent-encoded (no fragment injection)")
    func urlHashEncoded() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/?q=\(PlaceholderExpander.textToken)",
            text: "a#fragment"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("%23"))
    }

    @Test("/ in selection is percent-encoded (no path-segment injection)")
    func urlSlashEncoded() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/lookup/\(PlaceholderExpander.textToken)",
            text: "../admin"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("%2F"))
        #expect(!url!.absoluteString.contains("../admin"))
    }

    @Test(": in selection is percent-encoded (no authority injection)")
    func urlColonEncoded() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/lookup/\(PlaceholderExpander.textToken)",
            text: "evil:8080"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("%3A"))
    }

    @Test("@ in selection is percent-encoded (no authority boundary injection)")
    func urlAtEncoded() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/lookup/\(PlaceholderExpander.textToken)",
            text: "user@evil.com"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("%40"))
    }

    @Test("space in selection is percent-encoded to %20")
    func urlSpaceEncoded() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/?q=\(PlaceholderExpander.textToken)",
            text: "hello world"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("hello%20world"))
    }

    @Test("normal word round-trips through URL encoding unchanged (visible form)")
    func urlNormalWordRoundTrip() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/?q=\(PlaceholderExpander.textToken)",
            text: "swift"
        )
        #expect(url != nil)
        #expect(url!.absoluteString.contains("swift"))
    }

    @Test("empty template returns nil")
    func urlEmptyTemplateReturnsNil() {
        let url = PlaceholderExpander.expandURL(template: "", text: "anything")
        #expect(url == nil)
    }

    @Test("multiple & and = in selection are all encoded")
    func urlMultipleInjectionChars() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/?q=\(PlaceholderExpander.textToken)",
            text: "a b&c=d"
        )
        #expect(url != nil)
        let abs = url!.absoluteString
        // Original selfCheck invariant: a b&c encodes to a%20b%26c
        #expect(abs.contains("a%20b%26c%3Dd"))
    }

    @Test("multiple {text} tokens in a URL template are each encoded independently")
    func urlMultipleTokens() {
        // Global replacement must encode BOTH occurrences — a regression that only
        // replaced the first token (or shared one encoding) would be caught here.
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/?q=\(PlaceholderExpander.textToken)&sort=\(PlaceholderExpander.textToken)",
            text: "a&b"
        )
        #expect(url != nil)
        let abs = url!.absoluteString
        // Both the q and sort values must carry the encoded selection; the literal
        // template `&` between params survives, the selection's `&` is encoded.
        #expect(abs == "https://x.com/?q=a%26b&sort=a%26b")
    }

    @Test("path-segment template keeps the selection encoded and the host unchanged")
    func urlPathSegmentHostUnchanged() {
        // A {text} in the path must not collapse the authority: %2F stays encoded
        // and the host remains the template's host, not an injected one.
        let url = PlaceholderExpander.expandURL(
            template: "https://example.com/lookup/\(PlaceholderExpander.textToken)",
            text: "../../evil.com"
        )
        #expect(url != nil)
        #expect(url!.host == "example.com")
        #expect(url!.absoluteString.contains("%2F"))
    }

    // MARK: - Single-pass substitution

    @Test("{text} token in the SELECTION does not cause re-substitution (single pass)")
    func singlePassAppleScript() {
        // If the expander ran multiple passes, the {text} inside the selection would
        // be expanded again. It must not.
        let result = PlaceholderExpander.expandAppleScript(
            source: "set x to \(PlaceholderExpander.textToken)",
            text: PlaceholderExpander.textToken   // selection IS "{text}"
        )
        // The {text} in the selection is just a string; it ends up quoted verbatim.
        #expect(result == #"set x to "{text}""#)
    }

    @Test("{text} token in the SELECTION does not cause re-substitution in URL (single pass)")
    func singlePassURL() {
        let url = PlaceholderExpander.expandURL(
            template: "https://x.com/?q=\(PlaceholderExpander.textToken)",
            text: PlaceholderExpander.textToken   // selection IS "{text}"
        )
        #expect(url != nil)
        // {text} braces are encoded to %7B and %7D — not expanded.
        #expect(url!.absoluteString.contains("%7Btext%7D"))
    }

    // MARK: - Shell environment

    @Test("shellEnvironment returns POPGUY_TEXT with the given text")
    func shellEnvironmentPopguyText() {
        let env = PlaceholderExpander.shellEnvironment(text: "hello", fullText: "hello world")
        #expect(env["POPGUY_TEXT"] == "hello")
    }

    @Test("shellEnvironment returns POPGUY_FULL_TEXT with the given fullText")
    func shellEnvironmentPopguyFullText() {
        let env = PlaceholderExpander.shellEnvironment(text: "hello", fullText: "hello world")
        #expect(env["POPGUY_FULL_TEXT"] == "hello world")
    }

    @Test("shellEnvironment returns exactly two keys")
    func shellEnvironmentTwoKeys() {
        let env = PlaceholderExpander.shellEnvironment(text: "x", fullText: "y")
        #expect(env.count == 2)
        #expect(env.keys.contains("POPGUY_TEXT"))
        #expect(env.keys.contains("POPGUY_FULL_TEXT"))
    }

    @Test("shellEnvironment preserves adversarial selection verbatim (no escaping)")
    func shellEnvironmentAdversarialText() {
        // The env-var value must be the literal selection — no escaping, no truncation.
        // A mid/trailing tilde (not a leading tilde-prefix) is left untouched.
        let adversarial = "; rm -rf ~"
        let env = PlaceholderExpander.shellEnvironment(text: adversarial, fullText: adversarial)
        #expect(env["POPGUY_TEXT"] == adversarial)
    }

    // MARK: - shellEnvironment leading-tilde expansion

    @Test("leading ~/ expands to the home directory (both vars)")
    func shellEnvironmentTildeSlashExpands() {
        let env = PlaceholderExpander.shellEnvironment(
            text: "~/Downloads", fullText: "~/Downloads", homeDirectory: "/Users/test"
        )
        #expect(env["POPGUY_TEXT"] == "/Users/test/Downloads")
        #expect(env["POPGUY_FULL_TEXT"] == "/Users/test/Downloads")
    }

    @Test("a bare ~ expands to the home directory")
    func shellEnvironmentBareTildeExpands() {
        let env = PlaceholderExpander.shellEnvironment(
            text: "~", fullText: "~", homeDirectory: "/Users/test"
        )
        #expect(env["POPGUY_TEXT"] == "/Users/test")
    }

    @Test("~user form is NOT expanded")
    func shellEnvironmentNamedTildeUntouched() {
        let env = PlaceholderExpander.shellEnvironment(
            text: "~alice/x", fullText: "~alice/x", homeDirectory: "/Users/test"
        )
        #expect(env["POPGUY_TEXT"] == "~alice/x")
    }

    @Test("non-leading tilde and plain text are untouched")
    func shellEnvironmentNoLeadingTildeUntouched() {
        let env = PlaceholderExpander.shellEnvironment(
            text: "a ~/b", fullText: "plain text", homeDirectory: "/Users/test"
        )
        #expect(env["POPGUY_TEXT"] == "a ~/b")
        #expect(env["POPGUY_FULL_TEXT"] == "plain text")
    }
}
