// ActionLibrary+Text.swift
// PopGuy — ActionLibrary
//
// Text Transform presets for the Action Library.
// Each preset is a shell-script action that reads the selection from
// $POPGUY_TEXT and writes the transformed result to stdout.
// afterRun: .pasteResult pastes stdout back into the source application.
//
// Shell-safety rules enforced throughout:
//   - Selection arrives ONLY via $POPGUY_TEXT — never interpolated as {text}.
//   - stdin is fed with `printf '%s' "$POPGUY_TEXT"` (not echo — echo mangles
//     leading dashes and backslashes on some shells).
//   - Only stock-macOS tools are used: tr, sed, awk, sort, paste, perl.
//     perl ships with macOS (stock /usr/bin/perl); only core modules are used
//     (Unicode::Normalize for NFD decomposition).  python3 is NOT used — it is
//     absent on clean macOS 13+ without Command Line Tools installed.
//
// Isolation: nonisolated / Sendable value-type namespace — pure factory, no state.

import Foundation

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ActionLibraryText: Sendable {

    /// Returns all Text Transform presets.
    /// Each call returns fresh CustomAction instances with new UUIDs.
    nonisolated static func all() -> [LibraryPreset] {
        [
            uppercase(),
            lowercase(),
            titleCase(),
            capitalizeWords(),
            sentenceCase(),
            slugify(),
            hyphenate(),
            underscore(),
            removeSpaces(),
            joinLines(),
            sortLines(),
            reverseLineOrder(),
            shuffleLines(),
            alternatingCase(),
            rot13(),
            reverseString(),
        ]
    }

    // MARK: - Case transforms

    nonisolated private static func uppercase() -> LibraryPreset {
        LibraryPreset(id: "text.uppercase", category: .textTransform) {
            var action = CustomAction(
                title: "UPPERCASE",
                icon: .sfSymbol("characters.uppercase"),
                type: .shellScript,
                systemPrompt: "",
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | tr '[:lower:]' '[:upper:]'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Convert the selected text to UPPERCASE."
            return action
        }
    }

    nonisolated private static func lowercase() -> LibraryPreset {
        LibraryPreset(id: "text.lowercase", category: .textTransform) {
            var action = CustomAction(
                title: "lowercase",
                icon: .sfSymbol("characters.lowercase"),
                type: .shellScript,
                systemPrompt: "",
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | tr '[:upper:]' '[:lower:]'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Convert the selected text to lowercase."
            return action
        }
    }

    nonisolated private static func titleCase() -> LibraryPreset {
        LibraryPreset(id: "text.titlecase", category: .textTransform) {
            var action = CustomAction(
                title: "Title Case",
                icon: .sfSymbol("textformat"),
                type: .shellScript,
                systemPrompt: "",
                // perl -CSD: character mode so \w, \u, \L work on non-ASCII letters.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | perl -CSD -pe 's/(\w+)/\u\L$1/g'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Convert the selected text to Title Case (every word capitalised)."
            return action
        }
    }

    nonisolated private static func capitalizeWords() -> LibraryPreset {
        LibraryPreset(id: "text.capitalize", category: .textTransform) {
            var action = CustomAction(
                title: "Capitalize Words",
                icon: .sfSymbol("textformat"),
                type: .shellScript,
                systemPrompt: "",
                // awk splits on whitespace and capitalises the first letter of each field,
                // preserving the original casing of the remaining letters (unlike .title()).
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)};print}'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Capitalise the first letter of each word; preserve the rest."
            return action
        }
    }

    nonisolated private static func sentenceCase() -> LibraryPreset {
        LibraryPreset(id: "text.sentencecase", category: .textTransform) {
            var action = CustomAction(
                title: "Sentence Case",
                icon: .sfSymbol("textformat"),
                type: .shellScript,
                systemPrompt: "",
                // Lowercase the whole text, then capitalise the first letter after
                // each sentence-ending punctuation mark (. ! ?), including the very first letter.
                // perl -CSD: character mode so \w and uc() handle non-ASCII letters correctly.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | perl -CSD -pe '$_ = lc; s/([.!?]\s+|^\s*)\K(\w)/uc($2)/ge'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Convert to sentence case: first letter of each sentence is capitalised."
            return action
        }
    }

    // MARK: - Slug / separator transforms

    nonisolated private static func slugify() -> LibraryPreset {
        LibraryPreset(id: "text.slugify", category: .textTransform) {
            var action = CustomAction(
                title: "Slugify",
                icon: .sfSymbol("link"),
                type: .shellScript,
                systemPrompt: "",
                // 1. NFD-normalise via Unicode::Normalize (core Perl module), strip combining marks (\p{M}).
                // 2. Lowercase, replace non-alphanumeric runs with hyphens, trim edge hyphens.
                // perl -CSD: character mode required for \p{M} and lc() to handle non-ASCII.
                scriptSource: #"""
printf '%s' "$POPGUY_TEXT" | perl -CSD -MUnicode::Normalize -0777 -ne '
my $t = NFD($_);
$t =~ s/\p{M}//g;
$t = lc($t);
$t =~ s/[^a-z0-9]+/-/g;
$t =~ s/^-+|-+$//g;
print $t;
'
"""#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Convert text to a URL-safe slug (lowercase, accents removed, spaces to hyphens)."
            return action
        }
    }

    nonisolated private static func hyphenate() -> LibraryPreset {
        LibraryPreset(id: "text.hyphenate", category: .textTransform) {
            var action = CustomAction(
                title: "Hyphenate",
                icon: .sfSymbol("minus"),
                type: .shellScript,
                systemPrompt: "",
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | tr ' ' '-'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Replace spaces with hyphens."
            return action
        }
    }

    nonisolated private static func underscore() -> LibraryPreset {
        LibraryPreset(id: "text.underscore", category: .textTransform) {
            var action = CustomAction(
                title: "Underscore",
                icon: .sfSymbol("minus"),
                type: .shellScript,
                systemPrompt: "",
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | tr ' ' '_'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Replace spaces with underscores."
            return action
        }
    }

    nonisolated private static func removeSpaces() -> LibraryPreset {
        LibraryPreset(id: "text.removespaces", category: .textTransform) {
            var action = CustomAction(
                title: "Remove Spaces",
                icon: .sfSymbol("arrow.left.and.right"),
                type: .shellScript,
                systemPrompt: "",
                // [:space:] removes spaces, tabs, newlines, and other whitespace.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | tr -d '[:space:]'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Remove all whitespace characters from the selected text."
            return action
        }
    }

    // MARK: - Line transforms

    nonisolated private static func joinLines() -> LibraryPreset {
        LibraryPreset(id: "text.joinlines", category: .textTransform) {
            var action = CustomAction(
                title: "Join Lines",
                icon: .sfSymbol("arrow.down.to.line"),
                type: .shellScript,
                systemPrompt: "",
                // paste -sd' ' - reads stdin and joins all lines with a space separator.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | paste -sd' ' -"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Join all lines into a single line, separated by spaces."
            return action
        }
    }

    nonisolated private static func sortLines() -> LibraryPreset {
        LibraryPreset(id: "text.sortlines", category: .textTransform) {
            var action = CustomAction(
                title: "Sort Lines",
                icon: .sfSymbol("arrow.up.arrow.down"),
                type: .shellScript,
                systemPrompt: "",
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | sort"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Sort lines alphabetically (ascending)."
            return action
        }
    }

    nonisolated private static func reverseLineOrder() -> LibraryPreset {
        LibraryPreset(id: "text.reverselineorder", category: .textTransform) {
            var action = CustomAction(
                title: "Reverse Line Order",
                icon: .sfSymbol("arrow.uturn.down"),
                type: .shellScript,
                systemPrompt: "",
                // Portable sed reverse: accumulate lines in hold space, print at EOF.
                // `tail -r` is macOS-only but not available on all installs; the sed form
                // works on any POSIX system without relying on GNU coreutils.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | sed -n '1!G;h;$p'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Reverse the order of lines (last line becomes first)."
            return action
        }
    }

    nonisolated private static func shuffleLines() -> LibraryPreset {
        LibraryPreset(id: "text.shufflelines", category: .textTransform) {
            var action = CustomAction(
                title: "Shuffle Lines",
                icon: .sfSymbol("shuffle"),
                type: .shellScript,
                systemPrompt: "",
                // sort -R is available on stock macOS (BSD sort supports -R).
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | sort -R"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Randomly shuffle the order of lines."
            return action
        }
    }

    // MARK: - Fun / encoding transforms

    nonisolated private static func alternatingCase() -> LibraryPreset {
        LibraryPreset(id: "text.alternatingcase", category: .textTransform) {
            var action = CustomAction(
                title: "aLtErNaTiNg CaSe",
                icon: .sfSymbol("textformat"),
                type: .shellScript,
                systemPrompt: "",
                // Alternate upper/lower on every alphabetic character; non-alpha chars
                // are passed through without advancing the counter.
                // perl -CSD: character mode so \p{L} and uc()/lc() handle non-ASCII letters.
                scriptSource: #"""
printf '%s' "$POPGUY_TEXT" | perl -CSD -0777 -ne '
my $i = 0;
for my $ch (split //, $_) {
    if ($ch =~ /\p{L}/) {
        print $i % 2 == 0 ? uc($ch) : lc($ch);
        $i++;
    } else {
        print $ch;
    }
}
'
"""#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Alternate UPPER and lower casing on each alphabetic character."
            return action
        }
    }

    nonisolated private static func rot13() -> LibraryPreset {
        LibraryPreset(id: "text.rot13", category: .textTransform) {
            var action = CustomAction(
                title: "ROT13",
                icon: .sfSymbol("arrow.triangle.2.circlepath"),
                type: .shellScript,
                systemPrompt: "",
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | tr 'A-Za-z' 'N-ZA-Mn-za-m'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Apply ROT13 encoding (rotate letters by 13 positions; apply twice to decode)."
            return action
        }
    }

    nonisolated private static func reverseString() -> LibraryPreset {
        LibraryPreset(id: "text.reversestring", category: .textTransform) {
            var action = CustomAction(
                title: "Reverse String",
                icon: .sfSymbol("arrow.uturn.left"),
                type: .shellScript,
                systemPrompt: "",
                // `rev` reverses per-line, not the whole string. Use perl -0777 to slurp all
                // input as one string; -CSD enables character mode so multi-byte chars aren't split.
                scriptSource: #"printf '%s' "$POPGUY_TEXT" | perl -CSD -0777 -ne 'print scalar reverse $_'"#,
                afterRun: .pasteResult,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Reverse the entire character sequence of the selected text."
            return action
        }
    }
}
