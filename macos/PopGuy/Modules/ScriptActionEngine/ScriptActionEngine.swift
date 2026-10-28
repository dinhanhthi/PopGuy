// ScriptActionEngine.swift
// PopGuy — ScriptActionEngine
//
// Executor for the four scriptable custom-action types: openURL, appleScript,
// shellScript, and runShortcut. These bypass ProviderLayer entirely — no AI,
// no streaming, no OutputHandler — matching the pattern established by
// SpeakEngine and DictionaryEngine.
//
// Isolation: @MainActor for the class (the ScriptActionRunning seam is @MainActor
// and openURL touches AppKit). All script execution — including AppleScript, run
// via an `osascript` subprocess — happens off-main through CLIProcessRunner and
// suspends rather than blocks the main actor.
//
// Security: selected text is injected into action templates only through
// PlaceholderExpander, which applies the appropriate encoding for each context
// (percent-encoding for URLs, AppleScript string escaping for OSA scripts,
// environment-variable delivery for shell scripts). The text is never
// interpolated raw into any executed string.

import AppKit
import Foundation

// MARK: - ScriptActionResult

/// The output produced by a scriptable action.
///
/// `text` is nil when the action runs for its side-effect only (e.g. opening a
/// URL) or when the executed code produced no output.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct ScriptActionResult: Sendable {
    /// Captured output text, or nil if the action produces none.
    var text: String?
}

// MARK: - ScriptActionError

/// Errors thrown by ScriptActionEngine.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ScriptActionError: Error, Sendable, LocalizedError {

    /// The URL template expanded to a string that is not a valid URL.
    case invalidURL

    /// NSAppleScript reported an error. The associated value is the error message
    /// extracted from the error dictionary (NSAppleScriptErrorMessage key).
    case appleScriptFailed(String)

    /// `/usr/bin/shortcuts` was not found on this system (requires macOS 12+).
    case shortcutsUnavailable

    /// A subprocess (shell script or Shortcuts) exited with a non-zero status.
    case processFailed(code: Int32, stderr: String)

    /// The requested action type is not scriptable and cannot be dispatched here.
    case unsupportedActionType(CustomActionType)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The URL template did not produce a valid URL."
        case .appleScriptFailed(let message):
            return "AppleScript error: \(message)"
        case .shortcutsUnavailable:
            return "The Shortcuts command-line tool was not found. Shortcuts actions require macOS 12 or later."
        case .processFailed(let code, let stderr):
            let snippet = stderr.isEmpty ? "(no output)" : String(stderr.prefix(300))
            return "Script exited with status \(code): \(snippet)"
        case .unsupportedActionType(let type):
            return "Action type '\(type.displayName)' is not a scriptable type and cannot be run by ScriptActionEngine."
        }
    }
}

// MARK: - ScriptActionEngine

/// Executes scriptable custom actions (.openURL, .appleScript, .shellScript,
/// .runShortcut). All other types throw `.unsupportedActionType`.
///
/// The class is @MainActor to satisfy the `ScriptActionRunning` seam and because
/// `openURL` touches AppKit on the main actor. All script execution
/// (`runAppleScript` via `osascript`, `runShellScript`, `runShortcut`) runs in a
/// subprocess and suspends the main actor during the async wait — never blocks it.
///
/// Conforms to `ScriptActionRunning` so `ToolbarViewModel` can hold it behind the
/// protocol seam (enabling test injection via `FakeScriptActionRunner`).
@MainActor
final class ScriptActionEngine: ScriptActionRunning {

    // MARK: - Public dispatch

    /// Convenience entry point: dispatches to the appropriate typed method based
    /// on `action.type`. Phase 3 routing calls this single entry point.
    ///
    /// - Parameters:
    ///   - action:   The custom action to execute.
    ///   - text:     The captured selection (trimmed). Used for placeholder expansion.
    ///   - fullText: The full selected text before any trimming. Exposed as
    ///               `$POPGUY_FULL_TEXT` in shell scripts; pass the same value as
    ///               `text` when no separate full selection is available.
    func run(
        _ action: CustomAction,
        text: String,
        fullText: String
    ) async throws -> ScriptActionResult {
        switch action.type {
        case .openURL:
            return try openURL(action, text: text, fullText: fullText)
        case .appleScript:
            return try await runAppleScript(action, text: text, fullText: fullText)
        case .shellScript:
            return try await runShellScript(action, text: text, fullText: fullText)
        case .runShortcut:
            return try await runShortcut(action, text: text, fullText: fullText)
        case .ai, .translation, .speech, .dictionary:
            throw ScriptActionError.unsupportedActionType(action.type)
        }
    }

    // MARK: - openURL

    /// Opens a URL in the default application, optionally interpolating the
    /// selected text into the URL template.
    ///
    /// - Parameters:
    ///   - action:   Must have `type == .openURL`. `action.scriptSource` is the
    ///               URL template, e.g. `https://www.google.com/search?q={text}`.
    ///   - text:     The captured selection. `{text}` tokens are replaced with
    ///               the percent-encoded selection.
    ///   - fullText: Unused for URL expansion (URL templates only support `{text}`).
    /// - Returns: `ScriptActionResult(text: nil)` — URL open produces no text output.
    /// - Throws: `.invalidURL` when the expanded template is not a valid URL.
    func openURL(
        _ action: CustomAction,
        text: String,
        fullText: String
    ) throws -> ScriptActionResult {
        guard let url = PlaceholderExpander.expandURL(
            template: action.scriptSource,
            text: text
        ) else {
            throw ScriptActionError.invalidURL
        }
        // Consume the URL opaquely — do NOT reconstruct from url.path or url.absoluteString.
        // PlaceholderExpander.expandURL documents that the injection-safety guarantee
        // holds only when the URL is passed directly to NSWorkspace.open without
        // round-tripping through url.path (which silently decodes percent-encoding).
        if !NSWorkspace.shared.open(url) {
            // open() failing is extremely rare (e.g. no handler for the scheme).
            // Treat it as an invalid URL — the caller shows a toast error.
            throw ScriptActionError.invalidURL
        }
        return ScriptActionResult(text: nil)
    }

    // MARK: - runAppleScript

    /// Executes an AppleScript snippet with the selected text injected as a
    /// properly-escaped string literal.
    ///
    /// **Runs out-of-process via `/usr/bin/osascript`.** The expanded source is
    /// piped to `osascript -` on stdin and evaluated in a subprocess. This keeps
    /// the main actor free: unlike in-process `NSAppleScript.executeAndReturnError`
    /// (synchronous, main-thread-only), the async subprocess wait suspends rather
    /// than blocks, so the toolbar UI keeps rendering while the script runs — in
    /// particular while a first-run Automation (TCC) prompt is on screen. It also
    /// makes the call cancellable (`Process.terminate()` via the stream's
    /// termination handler) and immune to a blocked-main-thread hang.
    ///
    /// TCC attribution is unchanged in practice: macOS attributes the Apple events
    /// to the *responsible* process (PopGuy, the parent), not to `osascript`, so an
    /// existing "PopGuy → <app>" Automation grant still applies.
    ///
    /// The source is fed via stdin only — never through a shell — so the injection
    /// safety of `PlaceholderExpander.expandAppleScript` (quoted, escaped literals)
    /// is preserved end-to-end.
    ///
    /// - Parameters:
    ///   - action:   Must have `type == .appleScript`. `action.scriptSource` is
    ///               the AppleScript source, which may contain `{text}` tokens.
    ///   - text:     The captured selection. Injected as a safely-escaped
    ///               AppleScript string literal wherever `{text}` appears.
    ///   - fullText: Unused for AppleScript expansion (only `{text}` is supported).
    /// - Returns: `ScriptActionResult(text:)` with osascript's stdout (trimmed),
    ///            or `text: nil` if the script produced no output.
    /// - Throws: `.appleScriptFailed(_)` when osascript exits non-zero (the stderr
    ///           message, e.g. a "-1743 Not authorized" automation denial).
    func runAppleScript(
        _ action: CustomAction,
        text: String,
        fullText: String
    ) async throws -> ScriptActionResult {
        let source = PlaceholderExpander.expandAppleScript(
            source: action.scriptSource,
            text: text
        )

        let stream = CLIProcessRunner.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-"],
            stdin: source
        )

        do {
            return try await collectOutput(from: stream)
        } catch let ScriptActionError.processFailed(_, stderr) {
            // Re-surface as an AppleScript error so the "AppleScript error: …"
            // prefix and the osascript stderr (e.g. the -1743 automation denial)
            // reach the user unchanged.
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScriptActionError.appleScriptFailed(
                trimmed.isEmpty ? "Unknown AppleScript error." : trimmed
            )
        }
    }

    // MARK: - runShellScript

    /// Runs the action's shell command via `/bin/zsh -lc` and captures stdout.
    ///
    /// The environment is built from scratch (never inherited) following the
    /// CLIProcessRunner pattern. `POPGUY_TEXT` and `POPGUY_FULL_TEXT` are merged
    /// in from `PlaceholderExpander.shellEnvironment(text:fullText:)` so scripts
    /// access the selection safely as environment variables without any risk of
    /// shell word-splitting or injection.
    ///
    /// Note: the task spec says `-lc` (login shell) while the phase plan says `-c`.
    /// This implementation follows the task spec (`-lc`) so the user's `.zprofile`
    /// and brew paths are available to scripts.
    ///
    /// - Parameters:
    ///   - action:   Must have `type == .shellScript`. `action.scriptSource` is
    ///               the shell command (passed as a single argument to zsh).
    ///   - text:     The captured selection. Exposed as `$POPGUY_TEXT`.
    ///   - fullText: The full selection. Exposed as `$POPGUY_FULL_TEXT`.
    /// - Returns: `ScriptActionResult(text:)` with trimmed stdout, or `text: nil`
    ///            if stdout was empty after trimming.
    /// - Throws: `.processFailed(code:stderr:)` on non-zero exit.
    func runShellScript(
        _ action: CustomAction,
        text: String,
        fullText: String
    ) async throws -> ScriptActionResult {
        let env = PlaceholderExpander.shellEnvironment(text: text, fullText: fullText)

        // action.scriptSource is user-authored config and must NEVER contain interpolated
        // selection text — the untrusted selection reaches the script only via $POPGUY_TEXT env var.
        let stream = CLIProcessRunner.run(
            executablePath: "/bin/zsh",
            arguments: ["-lc", action.scriptSource],
            extraEnv: env
        )

        return try await collectOutput(from: stream)
    }

    // MARK: - runShortcut

    /// Runs a named Apple Shortcut, passing the selected text on stdin and
    /// capturing stdout as the result.
    ///
    /// The Shortcuts CLI (`/usr/bin/shortcuts`) ships with macOS 12 and later.
    /// This method guards for its presence and throws `.shortcutsUnavailable`
    /// rather than letting CLIProcessRunner produce a generic transport error.
    ///
    /// - Parameters:
    ///   - action:   Must have `type == .runShortcut`. `action.scriptSource` is
    ///               the shortcut name as it appears in the Shortcuts app.
    ///   - text:     The captured selection, written to the shortcut's stdin.
    ///   - fullText: Unused (Shortcuts receives input via stdin, not environment).
    /// - Returns: `ScriptActionResult(text:)` with trimmed stdout, or `text: nil`
    ///            if stdout was empty after trimming.
    /// - Throws: `.shortcutsUnavailable` when `/usr/bin/shortcuts` is absent;
    ///           `.processFailed(code:stderr:)` on non-zero exit.
    func runShortcut(
        _ action: CustomAction,
        text: String,
        fullText: String
    ) async throws -> ScriptActionResult {
        let shortcutsPath = "/usr/bin/shortcuts"
        guard FileManager.default.fileExists(atPath: shortcutsPath) else {
            throw ScriptActionError.shortcutsUnavailable
        }

        let stream = CLIProcessRunner.run(
            executablePath: shortcutsPath,
            arguments: ["run", action.scriptSource, "-i", "-", "-o", "-"],
            stdin: text
        )

        return try await collectOutput(from: stream)
    }

    // MARK: - Private helpers

    /// Drains an `AsyncThrowingStream<String, Error>` produced by `CLIProcessRunner`,
    /// accumulates all lines, trims the combined output, and returns a
    /// `ScriptActionResult`. Remaps `ProviderError` cases to `ScriptActionError`.
    ///
    /// `Task.checkCancellation()` is called on each iteration so cancelling the
    /// parent task stops the loop promptly — this fires the stream's `onTermination`
    /// handler, which calls `Process.terminate()` via `RunState`.
    // internal (not private) so unit tests can feed a synthetic throwing stream and
    // verify the ProviderError → ScriptActionError remap without spawning a process.
    func collectOutput(
        from stream: AsyncThrowingStream<String, Error>
    ) async throws -> ScriptActionResult {
        var lines: [String] = []
        do {
            for try await line in stream {
                try Task.checkCancellation()
                lines.append(line)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderError {
            // Remap CLIProcessRunner's ProviderError to ScriptActionError.
            switch error {
            case .httpError(let statusCode, let body):
                throw ScriptActionError.processFailed(
                    code: Int32(statusCode),
                    stderr: body ?? ""
                )
            case .transport(let message):
                throw ScriptActionError.processFailed(code: -1, stderr: message)
            default:
                throw ScriptActionError.processFailed(code: -1, stderr: error.localizedDescription)
            }
        }

        let output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ScriptActionResult(text: output.isEmpty ? nil : output)
    }
}
