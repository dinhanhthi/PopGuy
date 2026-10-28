// PopClipToPopGuyAdapter.swift
// PopGuy — PluginImport
//
// Maps a decoded PopClipConfig into PopGuy CustomActions plus a skip report.
//
// Isolation: nonisolated — pure, no IO, no execution, no network.

import Foundation

// MARK: - PopClipToPopGuyAdapter

/// Adapts a decoded `PopClipConfig` to a `PluginImportResult`.
///
/// Each supported PopClip action becomes one `CustomAction`. Unsupported
/// executors, problematic icons, and plugin options produce `SkippedItem`
/// notes so the user knows what to review.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum PopClipToPopGuyAdapter {

    // MARK: - Public entry point

    /// Adapts `config` into a `PluginImportResult`.
    ///
    /// - Parameter config: A decoded `PopClipConfig` (from the reader step).
    /// - Returns: All importable actions plus a skip report for the consent sheet.
    nonisolated static func adapt(_ config: PopClipConfig) -> PluginImportResult {
        let sourceName = config.name ?? config.identifier ?? "PopClip extension"

        var imported: [CustomAction] = []
        var skipped:  [SkippedItem]  = []

        // Track whether any action has options — report once, not per action.
        var seenHasOptions = false

        for action in config.actions {
            let actionLabel = action.title ?? config.name ?? "Imported action"

            if action.hasOptions {
                seenHasOptions = true
            }

            // Resolve the executor in priority order: url > shellScript > appleScript > shortcutName.
            if let url = action.url {
                // ── URL action ──────────────────────────────────────────────
                let rewritten = rewriteURLPlaceholders(url)
                let (icon, iconNote) = resolveIcon(
                    action.icon ?? config.icon,
                    label: actionLabel
                )
                if let note = iconNote { skipped.append(note) }
                let afterRun = resolveAfterRun(action.after)
                let customAction = CustomAction(
                    title: actionLabel,
                    icon: icon,
                    type: .openURL,
                    systemPrompt: "",
                    scriptSource: rewritten,
                    afterRun: afterRun,
                    appliesWhenRegex: resolveRegex(action)
                )
                imported.append(customAction)
                skipped.append(contentsOf: requirementNotes(action))

            } else if let script = action.shellScript {
                // ── Shell script action ──────────────────────────────────────
                let (rewritten, unknownVars) = rewriteShellPlaceholders(script)
                let (icon, iconNote) = resolveIcon(
                    action.icon ?? config.icon,
                    label: actionLabel
                )
                if let note = iconNote { skipped.append(note) }
                let afterRun = resolveAfterRun(action.after)
                let customAction = CustomAction(
                    title: actionLabel,
                    icon: icon,
                    type: .shellScript,
                    systemPrompt: "",
                    scriptSource: rewritten,
                    afterRun: afterRun,
                    appliesWhenRegex: resolveRegex(action)
                )
                imported.append(customAction)
                if !unknownVars.isEmpty {
                    skipped.append(SkippedItem(
                        label: actionLabel,
                        reason: "uses PopClip variable(s) not translated: \(unknownVars.joined(separator: ", "))"
                    ))
                }
                skipped.append(contentsOf: requirementNotes(action))

            } else if let script = action.appleScript {
                // ── AppleScript action ───────────────────────────────────────
                let rewritten = rewriteAppleScriptPlaceholders(script)
                let (icon, iconNote) = resolveIcon(
                    action.icon ?? config.icon,
                    label: actionLabel
                )
                if let note = iconNote { skipped.append(note) }
                let afterRun = resolveAfterRun(action.after)
                let customAction = CustomAction(
                    title: actionLabel,
                    icon: icon,
                    type: .appleScript,
                    systemPrompt: "",
                    scriptSource: rewritten,
                    afterRun: afterRun,
                    appliesWhenRegex: resolveRegex(action)
                )
                imported.append(customAction)
                skipped.append(contentsOf: requirementNotes(action))

            } else if let shortcut = action.shortcutName {
                // ── Shortcuts action ─────────────────────────────────────────
                let (icon, iconNote) = resolveIcon(
                    action.icon ?? config.icon,
                    label: actionLabel
                )
                if let note = iconNote { skipped.append(note) }
                let afterRun = resolveAfterRun(action.after)
                let customAction = CustomAction(
                    title: actionLabel,
                    icon: icon,
                    type: .runShortcut,
                    systemPrompt: "",
                    scriptSource: shortcut,
                    afterRun: afterRun,
                    appliesWhenRegex: resolveRegex(action)
                )
                imported.append(customAction)
                skipped.append(contentsOf: requirementNotes(action))

            } else {
                // ── No supported executor ────────────────────────────────────
                let reason = unsupportedReason(action)
                skipped.append(SkippedItem(label: actionLabel, reason: reason))
            }
        }

        // One global note if any action declared options.
        if seenHasOptions {
            skipped.append(SkippedItem(
                label: sourceName,
                reason: "Plugin options are not supported (actions imported without options)"
            ))
        }

        // Safety cap: mirrors the 100-per-import cap on the native JSON import paths.
        return PluginImportResult(
            sourceName: sourceName,
            imported: Array(imported.prefix(100)),
            skipped: skipped
        )
    }

    // MARK: - Placeholder rewriting

    /// Rewrites PopClip URL placeholder tokens to PopGuy's `{text}`.
    ///
    /// Replaces `***` and `{popclip text}` / `{popclip-text}` (case-insensitive).
    nonisolated private static func rewriteURLPlaceholders(_ template: String) -> String {
        // Replace bare *** first (no regex needed).
        var result = template.replacingOccurrences(of: "***", with: "{text}")
        // Replace {popclip text} and {popclip-text}, case-insensitive.
        result = result.replacingOccurrences(
            of: #"\{popclip[\s\-]text\}"#,
            with: "{text}",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }

    /// Rewrites PopClip shell env-var tokens to PopGuy equivalents.
    ///
    /// Handles `$POPCLIP_TEXT`, `${POPCLIP_TEXT}`, and bare `POPCLIP_TEXT`
    /// for both `POPCLIP_TEXT` and `POPCLIP_FULL_TEXT`.
    ///
    /// - Returns: The rewritten script, plus any OTHER `POPCLIP_*` variable
    ///   names that were found but not translated.
    nonisolated private static func rewriteShellPlaceholders(
        _ script: String
    ) -> (rewritten: String, unknownVars: [String]) {

        var result = script

        // Whole-token replacement for the two known variables.
        // Order: replace longer token first to avoid partial matches
        // (`POPCLIP_FULL_TEXT` contains `POPCLIP_TEXT` as a prefix).
        let knownSubstitutions: [(popclip: String, popguy: String)] = [
            ("POPCLIP_FULL_TEXT", "POPGUY_FULL_TEXT"),
            ("POPCLIP_TEXT", "POPGUY_TEXT"),
        ]

        for (popclipVar, popguyVar) in knownSubstitutions {
            // $VAR form
            result = result.replacingOccurrences(of: "$\(popclipVar)", with: "$\(popguyVar)")
            // ${VAR} form
            result = result.replacingOccurrences(of: "${\(popclipVar)}", with: "${\(popguyVar)}")
            // bare VAR (whole-token: not preceded/followed by a word char)
            result = result.replacingOccurrences(
                of: #"(?<!\w)"# + popclipVar + #"(?!\w)"#,
                with: popguyVar,
                options: .regularExpression
            )
        }

        // Detect any remaining POPCLIP_* tokens (not translated).
        let unknownVars = remainingPopClipVars(in: result)

        return (result, unknownVars)
    }

    /// Rewrites `{popclip text}` / `{popclip-text}` (case-insensitive) to `{text}`
    /// in AppleScript source.
    nonisolated private static func rewriteAppleScriptPlaceholders(_ script: String) -> String {
        script.replacingOccurrences(
            of: #"\{popclip[\s\-]text\}"#,
            with: "{text}",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// Finds any `POPCLIP_*` identifiers remaining in `text` after known substitutions.
    /// Used to generate the "uses PopClip variable(s) not translated" skip note.
    nonisolated private static func remainingPopClipVars(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"POPCLIP_\w+"#) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        // Deduplicate while preserving first-occurrence order.
        var seen  = Set<String>()
        var found = [String]()
        for match in matches {
            let name = nsText.substring(with: match.range)
            if seen.insert(name).inserted { found.append(name) }
        }
        return found
    }

    // MARK: - Icon resolution

    /// Resolves a PopClip icon string to an `ActionIcon`, with an optional skip note
    /// when the format is unsupported.
    ///
    /// - `symbol:NAME`           → `.sfSymbol(NAME)`
    /// - bare emoji / `emoji:X`  → `.emoji(X)`
    /// - anything else           → `.default` + skip note
    nonisolated private static func resolveIcon(
        _ raw: String?,
        label: String
    ) -> (icon: ActionIcon, note: SkippedItem?) {

        guard let raw, !raw.isEmpty else { return (.default, nil) }

        // symbol:NAME → .sfSymbol(NAME)
        if raw.lowercased().hasPrefix("symbol:") {
            let name = String(raw.dropFirst("symbol:".count))
            return (.sfSymbol(name), nil)
        }

        // emoji:X → .emoji(X)
        if raw.lowercased().hasPrefix("emoji:") {
            let char = String(raw.dropFirst("emoji:".count))
            return (.emoji(char), nil)
        }

        // Bare emoji heuristic: a short string whose first Unicode scalar is emoji.
        if looksLikeEmoji(raw) {
            return (.emoji(raw), nil)
        }

        // Unsupported formats: text:, shape:*, square, circle, iconify:*, image:*, file paths.
        let note = SkippedItem(
            label: label,
            reason: "icon '\(raw)' not supported, using default icon"
        )
        return (.default, note)
    }

    /// Returns true when `s` appears to be a bare emoji string.
    ///
    /// Heuristic: the string is short (≤8 scalars) and the first scalar belongs to
    /// one of the common emoji Unicode ranges (or has an emoji presentation).
    nonisolated private static func looksLikeEmoji(_ s: String) -> Bool {
        guard !s.isEmpty, s.unicodeScalars.count <= 8 else { return false }
        guard let first = s.unicodeScalars.first else { return false }
        // Quick ASCII-letter exclusion: plain text labels start with ASCII letters.
        let v = first.value
        // ASCII printable (space–tilde): not emoji.
        if v >= 0x20 && v <= 0x7E { return false }
        // Common emoji scalar ranges:
        //   Emoticons:                    0x1F600–0x1F64F
        //   Misc symbols & pictographs:   0x1F300–0x1F5FF
        //   Transport & map symbols:      0x1F680–0x1F6FF
        //   Supplemental symbols:         0x1F900–0x1F9FF
        //   Symbols & pictographs ext-A:  0x1FA00–0x1FAFF
        //   Misc symbols (BMP):           0x2600–0x26FF
        //   Dingbats:                     0x2700–0x27BF
        //   Enclosed alphanumerics ext:   0x1F100–0x1F1FF (flags)
        let emojiRanges: [ClosedRange<UInt32>] = [
            0x1F300...0x1F1FFFF,  // broad emoji plane range
            0x2600...0x27BF,
        ]
        return emojiRanges.contains { $0.contains(v) }
    }

    // MARK: - After-run mapping

    /// Maps a PopClip `after` string to an `AfterRunBehavior`.
    nonisolated private static func resolveAfterRun(_ after: String?) -> AfterRunBehavior {
        switch after?.lowercased() {
        case "paste-result":             return .pasteResult
        case "copy-result":              return .copyResult
        case "show-result", "preview-result": return .showResult
        default:                         return .closeToolbar
        }
    }

    // MARK: - Regex resolution

    /// Returns the regex string for the action (empty string means always visible).
    nonisolated private static func resolveRegex(_ action: PopClipAction) -> String {
        action.regex ?? ""
    }

    // MARK: - Requirement notes

    /// Produces skip notes for any `requirements` entries that PopGuy does not enforce.
    ///
    /// `regex` is handled separately via `appliesWhenRegex`; all other entries are noted.
    nonisolated private static func requirementNotes(_ action: PopClipAction) -> [SkippedItem] {
        guard let reqs = action.requirements, !reqs.isEmpty else { return [] }
        let title = action.title ?? "Action"
        return reqs
            .filter { $0.lowercased() != "regex" }
            .map { req in
                SkippedItem(
                    label: title,
                    reason: "requirement '\(req)' not enforced"
                )
            }
    }

    // MARK: - Skip reason for unsupported actions

    /// Returns the appropriate skip reason for an action with no supported executor.
    nonisolated private static func unsupportedReason(_ action: PopClipAction) -> String {
        if action.javascript != nil || action.javascriptFile != nil {
            return "JavaScript actions are not supported"
        }
        if action.keyCombo != nil {
            return "Key-combo actions are not supported"
        }
        if action.serviceName != nil {
            return "Service actions are not supported"
        }
        return "No supported action type found"
    }
}
