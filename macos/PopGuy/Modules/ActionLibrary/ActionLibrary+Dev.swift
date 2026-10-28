// ActionLibrary+Dev.swift
// PopGuy — ActionLibrary
//
// Developer Tools presets for the Action Library.
// Each preset is a shell-script action that reads the selection from
// $POPGUY_TEXT and writes the result to stdout.
//
// Shell-safety rules enforced throughout:
//   - Selection arrives ONLY via $POPGUY_TEXT — never interpolated as {text}.
//   - stdin is fed with `printf '%s' "$POPGUY_TEXT"` (not echo — echo mangles
//     leading dashes and backslashes on some shells).
//   - Only stock-macOS tools are used: base64, shasum, md5, date, bc, awk, tr, wc, perl.
//     perl ships with macOS (stock /usr/bin/perl); only core modules are used
//     (JSON::PP for JSON pretty-printing).  python3 is NOT used — it is absent
//     on clean macOS 13+ without Command Line Tools installed.
//
// Isolation: nonisolated / Sendable value-type namespace — pure factory, no state.

import Foundation

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ActionLibraryDev: Sendable {

    /// Returns all Developer Tools presets.
    /// Each call returns fresh CustomAction instances with new UUIDs.
    nonisolated static func all() -> [LibraryPreset] {
        [
            base64Encode(),
            base64Decode(),
            urlEncode(),
            urlDecode(),
            htmlEncode(),
            htmlDecode(),
            sha256(),
            md5Hash(),
            unixTimeToDate(),
            dateToUnixTime(),
            jsonPrettyPrint(),
            wordCount(),
            characterCount(),
            lineCount(),
            calculate(),
        ]
    }

    // MARK: - Encoding / Decoding

    nonisolated private static func base64Encode() -> LibraryPreset {
        LibraryPreset(id: "dev.base64encode", category: .devTools) {
            var action = CustomAction(
                title: "Base64 Encode",
                icon: .sfSymbol("chevron.left.forwardslash.chevron.right"),
                type: .shellScript,
                systemPrompt: "",
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | base64"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Encode the selected text as Base64."
            return action
        }
    }

    nonisolated private static func base64Decode() -> LibraryPreset {
        LibraryPreset(id: "dev.base64decode", category: .devTools) {
            var action = CustomAction(
                title: "Base64 Decode",
                icon: .sfSymbol("chevron.left.forwardslash.chevron.right"),
                type: .shellScript,
                systemPrompt: "",
                // BSD base64 uses -D to decode (GNU uses -d).
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | base64 -D"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Decode a Base64-encoded string."
            return action
        }
    }

    nonisolated private static func urlEncode() -> LibraryPreset {
        LibraryPreset(id: "dev.urlencode", category: .devTools) {
            var action = CustomAction(
                title: "URL Encode",
                icon: .sfSymbol("link"),
                type: .shellScript,
                systemPrompt: "",
                // Byte mode (no -C): URL-encodes each UTF-8 byte of the input, producing
                // the correct %XX escape per byte (e.g. é → %C3%A9).
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | perl -pe 's/([^A-Za-z0-9_.~-])/sprintf("%%%02X",ord($1))/ge'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Percent-encode the selected text for use in a URL."
            return action
        }
    }

    nonisolated private static func urlDecode() -> LibraryPreset {
        LibraryPreset(id: "dev.urldecode", category: .devTools) {
            var action = CustomAction(
                title: "URL Decode",
                icon: .sfSymbol("link"),
                type: .shellScript,
                systemPrompt: "",
                // Byte mode (no -C): converts each %XX escape to the corresponding byte,
                // restoring UTF-8 multibyte sequences correctly.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | perl -pe 's/%([0-9A-Fa-f]{2})/chr(hex($1))/ge'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Decode a percent-encoded URL string."
            return action
        }
    }

    nonisolated private static func htmlEncode() -> LibraryPreset {
        LibraryPreset(id: "dev.htmlencode", category: .devTools) {
            var action = CustomAction(
                title: "HTML Encode",
                icon: .sfSymbol("chevron.left.forwardslash.chevron.right"),
                type: .shellScript,
                systemPrompt: "",
                // Encode the 5 HTML special characters; & must be replaced first to avoid
                // double-encoding.  Apostrophe uses \x27 to stay single-quote-safe in the shell.
                // BSD sed has a footgun with & in replacements, so perl is used here instead.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | perl -pe 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/\x27/\&#39;/g'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Escape HTML special characters (&, <, >, \")."
            return action
        }
    }

    nonisolated private static func htmlDecode() -> LibraryPreset {
        LibraryPreset(id: "dev.htmldecode", category: .devTools) {
            var action = CustomAction(
                title: "HTML Decode",
                icon: .sfSymbol("chevron.left.forwardslash.chevron.right"),
                type: .shellScript,
                systemPrompt: "",
                // Decode the 5 HTML entities; &amp; must be decoded last to avoid
                // converting &amp;lt; into < instead of &lt;.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | perl -pe 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/\x27/g; s/&amp;/\&/g'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Unescape HTML entities back to plain text."
            return action
        }
    }

    // MARK: - Hashing

    nonisolated private static func sha256() -> LibraryPreset {
        LibraryPreset(id: "dev.sha256", category: .devTools) {
            var action = CustomAction(
                title: "SHA-256",
                icon: .sfSymbol("number"),
                type: .shellScript,
                systemPrompt: "",
                // shasum -a 256 prints "<hash>  -"; awk extracts just the hash.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | shasum -a 256 | awk '{print $1}'"#,
                afterRun: .showResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Compute the SHA-256 hash of the selected text."
            return action
        }
    }

    nonisolated private static func md5Hash() -> LibraryPreset {
        LibraryPreset(id: "dev.md5", category: .devTools) {
            var action = CustomAction(
                title: "MD5",
                icon: .sfSymbol("number"),
                type: .shellScript,
                systemPrompt: "",
                // BSD md5 (stock macOS) prints the hash directly to stdout.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | md5"#,
                afterRun: .showResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Compute the MD5 hash of the selected text."
            return action
        }
    }

    // MARK: - Date / Time

    nonisolated private static func unixTimeToDate() -> LibraryPreset {
        LibraryPreset(id: "dev.unixtimetodate", category: .devTools) {
            var action = CustomAction(
                title: "Unix Time → Date",
                icon: .sfSymbol("clock"),
                type: .shellScript,
                systemPrompt: "",
                // BSD date -r <epoch> converts Unix epoch seconds to a human-readable date.
                // The selection must be a plain integer (epoch seconds).
                scriptSource: #"date -r "$(printf '%s' "$POPGUY_TEXT")""#,
                afterRun: .showResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Convert a Unix timestamp (epoch seconds) to a human-readable date."
            return action
        }
    }

    nonisolated private static func dateToUnixTime() -> LibraryPreset {
        LibraryPreset(id: "dev.datetounixtime", category: .devTools) {
            var action = CustomAction(
                title: "Date → Unix Time",
                icon: .sfSymbol("clock"),
                type: .shellScript,
                systemPrompt: "",
                // ⚠ verify scheme — format-sensitive: input must be "YYYY-MM-DD HH:MM:SS".
                // BSD date -j -f "<format>" "<input>" +%s converts to epoch seconds.
                scriptSource: #"date -j -f "%Y-%m-%d %H:%M:%S" "$(printf '%s' "$POPGUY_TEXT")" +%s"#,
                afterRun: .showResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Convert a date string (YYYY-MM-DD HH:MM:SS) to a Unix timestamp."
            return action
        }
    }

    // MARK: - JSON

    nonisolated private static func jsonPrettyPrint() -> LibraryPreset {
        LibraryPreset(id: "dev.jsonprettyprint", category: .devTools) {
            var action = CustomAction(
                title: "JSON Pretty-Print",
                icon: .sfSymbol("curlybraces"),
                type: .shellScript,
                systemPrompt: "",
                // JSON::PP is a core Perl module (no CPAN required). ->pretty adds newlines/
                // indentation; ->canonical sorts keys alphabetically for consistent output.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | perl -0777 -MJSON::PP -ne 'print JSON::PP->new->pretty->canonical->encode(JSON::PP::decode_json($_))'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Format JSON with indentation for readability."
            return action
        }
    }

    // MARK: - Counts

    nonisolated private static func wordCount() -> LibraryPreset {
        LibraryPreset(id: "dev.wordcount", category: .devTools) {
            var action = CustomAction(
                title: "Word Count",
                icon: .sfSymbol("textformat.123"),
                type: .shellScript,
                systemPrompt: "",
                // tr -d ' ' strips the leading spaces that wc -w pads on macOS.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | wc -w | tr -d ' '"#,
                afterRun: .showResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Count the number of words in the selected text."
            return action
        }
    }

    nonisolated private static func characterCount() -> LibraryPreset {
        LibraryPreset(id: "dev.charactercount", category: .devTools) {
            var action = CustomAction(
                title: "Character Count",
                icon: .sfSymbol("textformat.123"),
                type: .shellScript,
                systemPrompt: "",
                // wc -m counts Unicode characters (not bytes); tr strips padding spaces.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | wc -m | tr -d ' '"#,
                afterRun: .showResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Count the number of Unicode characters in the selected text."
            return action
        }
    }

    nonisolated private static func lineCount() -> LibraryPreset {
        LibraryPreset(id: "dev.linecount", category: .devTools) {
            var action = CustomAction(
                title: "Line Count",
                icon: .sfSymbol("list.number"),
                type: .shellScript,
                systemPrompt: "",
                // tr strips the leading spaces that wc -l pads on macOS.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | wc -l | tr -d ' '"#,
                afterRun: .showResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Count the number of lines in the selected text."
            return action
        }
    }

    // MARK: - Math

    nonisolated private static func calculate() -> LibraryPreset {
        LibraryPreset(id: "dev.calculate", category: .devTools) {
            var action = CustomAction(
                title: "Calculate",
                icon: .sfSymbol("function"),
                type: .shellScript,
                systemPrompt: "",
                // bc -l evaluates the expression with math library (supports sin, cos, etc.).
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | bc -l"#,
                afterRun: .showResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Evaluate the selected mathematical expression using bc."
            return action
        }
    }
}
