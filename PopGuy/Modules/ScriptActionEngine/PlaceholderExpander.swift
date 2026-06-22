// PlaceholderExpander.swift
// PopGuy — ScriptActionEngine
//
// Injection-safe substitution of the user's selected text into scriptable
// custom actions. The selected text is UNTRUSTED — it may be attacker-crafted
// content from a webpage or document. This file is the security boundary.
//
// Isolation: nonisolated / Sendable value-type namespace — pure functions with
// no state that cross actor boundaries freely.

import Foundation

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum PlaceholderExpander: Sendable {

    // MARK: - Token

    /// The placeholder the action editor inserts into URL templates, AppleScript
    /// source, and shortcut names. This expander replaces it with the selected text.
    static let textToken = "{text}"

    // MARK: - URL expansion

    /// Expands a URL template by replacing every `{text}` token with the selected
    /// text percent-encoded for safe use inside a URL path segment or query-parameter
    /// value.
    ///
    /// **Why this is injection-safe:**
    /// The selected text is encoded with a character set that is a strict subset of
    /// `.urlQueryAllowed` with ALL structurally significant URL characters removed:
    ///
    ///   - `/ ? # & = + % @ : ;` — path separators, query/fragment delimiters,
    ///     authority separators, and encoding escapes.
    ///
    /// This prevents the selection from:
    ///   - Introducing a new path segment (`/../admin` → `..%2Fadmin`).
    ///   - Injecting query parameters (`x&admin=true` → `x%26admin%3Dtrue`).
    ///   - Escaping the authority boundary (`@` encoded, `:` encoded).
    ///   - Introducing a fragment (`#` encoded).
    ///
    /// The encoded value is then substituted verbatim into the template so it can
    /// only occupy the path or query-value slot that `{text}` marked.
    ///
    /// **Unsupported: HOST position.** A hostname cannot be percent-encoded by
    /// definition (DNS labels must be ASCII-alnum or `-`). Placing `{text}` in the
    /// host component of a template is therefore not defensible via encoding alone
    /// and is unsupported. Template authors must place `{text}` in the path or
    /// query position only (e.g. `https://example.com/search?q={text}` or
    /// `https://example.com/lookup/{text}`).
    ///
    /// **Caller contract: consume the URL opaquely.** The encoding guarantee holds
    /// end-to-end only if callers pass the returned `URL` straight to `NSWorkspace.open`
    /// / `URLRequest` and never reconstruct from `url.path` (which silently re-decodes
    /// percent-encoding and would resurrect a `../` path traversal).
    ///
    /// - Parameters:
    ///   - template: A URL string containing zero or more `{text}` tokens.
    ///   - text:     The untrusted selected text to substitute.
    /// - Returns: A `URL` with all tokens replaced, or `nil` if the expanded string
    ///            is not a valid URL.
    nonisolated static func expandURL(template: String, text: String) -> URL? {
        // Start from urlQueryAllowed (which already excludes most structural chars)
        // and additionally remove path/authority/encoding structural characters so
        // the substituted selection is safe in both path and query-value positions.
        var allowedChars = CharacterSet.urlQueryAllowed
        allowedChars.remove(charactersIn: "/?#&=+%@:;")

        // `?? ""` is unreachable in practice (percent-encoding a String against a valid
        // CharacterSet never returns nil) but fails safe — an empty value cannot inject.
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowedChars) ?? ""
        let expanded = template.replacingOccurrences(of: textToken, with: encoded)
        return URL(string: expanded)
    }

    // MARK: - AppleScript expansion

    /// Expands an AppleScript source string by replacing every `{text}` token with
    /// a fully-quoted AppleScript string literal containing the selected text.
    ///
    /// **Why this is injection-safe:**
    /// AppleScript string literals are delimited by double-quotes and interpret only
    /// two escape sequences: `\"` (literal quote) and `\\` (literal backslash). By
    /// escaping those two characters — in the correct order, backslash first — and
    /// wrapping the result in double-quotes, the substituted value is confined to a
    /// complete, self-contained literal. The selection cannot break out of the string,
    /// inject additional AppleScript statements, or terminate the literal early.
    ///
    /// Escape order:
    ///   1. `\` → `\\` (must be first, or the `\"` sequences added below get re-escaped)
    ///   2. `"` → `\"`
    ///
    /// Example: `set x to {text}` with text `a"b\c` → `set x to "a\"b\\c"`
    ///
    /// - Parameters:
    ///   - source: An AppleScript string containing zero or more `{text}` tokens.
    ///   - text:   The untrusted selected text to substitute.
    /// - Returns: The AppleScript source with all tokens replaced by quoted literals.
    nonisolated static func expandAppleScript(source: String, text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")   // backslash first
            .replacingOccurrences(of: "\"", with: "\\\"")   // then double-quote
        let literal = "\"\(escaped)\""
        return source.replacingOccurrences(of: textToken, with: literal)
    }

    // MARK: - Shell environment

    /// Returns an environment dictionary for shell script actions containing the
    /// selected text as a safe environment variable.
    ///
    /// **Why this is injection-safe:**
    /// Shell scripts receive the selected text as an environment variable value, not
    /// via string interpolation into the command string. There is no shell word-splitting,
    /// glob expansion, or command-substitution applied to environment variable values.
    /// The script must explicitly read `$POPGUY_TEXT` — a value the script author
    /// controls. A hostile selection (`; rm -rf ~`) lands as a literal string in the
    /// variable, harmless unless the script re-interpolates it without quoting (which
    /// is a script-author bug, not a PopGuy bug).
    ///
    /// **Leading tilde is expanded.** A value of `~` or a `~/…` prefix is rewritten to
    /// the user's home directory, matching what a shell does for a *typed* tilde. This
    /// is necessary because tilde expansion does NOT happen on the contents of an
    /// environment variable (the shell only expands a literal, unquoted `~` in command
    /// text) — so a selection of `~/Downloads` would otherwise reach `open`/`cd` as the
    /// literal string `~/Downloads` and fail. Expanding it to an absolute path makes
    /// `open -R "$POPGUY_TEXT"` behave like `open -R ~/Downloads` typed in a terminal.
    /// `~user` forms are left unchanged. This stays injection-safe: the result is still
    /// delivered only as an environment-variable value, never interpolated into the
    /// command string.
    ///
    /// - Parameters:
    ///   - text:          The untrusted selected text (primary selection, trimmed).
    ///   - fullText:      The full selected text before any trimming (for completeness).
    ///   - homeDirectory: The home directory used for tilde expansion. Defaults to the
    ///                    current user's home; injectable for tests. Matches the `HOME`
    ///                    the subprocess receives.
    /// - Returns: A dictionary mapping `POPGUY_TEXT` and `POPGUY_FULL_TEXT` to the
    ///            corresponding values. Pass this as the process environment (merged
    ///            with or replacing the inherited environment as appropriate).
    nonisolated static func shellEnvironment(
        text: String,
        fullText: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String: String] {
        return [
            "POPGUY_TEXT": expandingLeadingTilde(text, home: homeDirectory),
            "POPGUY_FULL_TEXT": expandingLeadingTilde(fullText, home: homeDirectory)
        ]
    }

    /// Expands a leading `~` / `~/` to `home`, like a shell's tilde-prefix expansion.
    /// Leaves the string unchanged when there is no leading tilde or it is a `~user`
    /// form (e.g. `~alice/x`), which this intentionally does not resolve.
    nonisolated private static func expandingLeadingTilde(_ s: String, home: String) -> String {
        if s == "~" { return home }
        if s.hasPrefix("~/") { return home + String(s.dropFirst()) }
        return s
    }
}

