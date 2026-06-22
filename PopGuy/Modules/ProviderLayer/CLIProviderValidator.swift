// CLIProviderValidator.swift
// PopGuy — ProviderLayer
//
// Health-check for CLI-based providers (Claude / Codex / Gemini CLI). Unlike
// the API providers — which validate an API key against an auth endpoint via
// ProviderKeyValidator — CLI providers have no key. "Does it work?" means:
// can we spawn the configured binary and get a non-empty answer back using the
// user's subscription/OAuth login? This runs one tiny real prompt and reports
// the outcome to the Settings UI's Verify button.
//
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target)
// so the subprocess round-trip runs off the main thread.

import Foundation

nonisolated enum CLIProviderValidator {

    /// Result of a CLI provider verification.
    nonisolated enum Outcome: Sendable, Equatable {
        /// The CLI ran and returned output — the subscription login works.
        case working
        /// No path is configured for this provider.
        case noPath
        /// The CLI failed to run or returned an error (message is user-facing).
        case failed(String)
    }

    /// A minimal, deterministic prompt. Kept tiny so the check is fast and cheap.
    private static let probeInput = "Reply with the single word: OK"

    /// Verify that the CLI at `executablePath` runs and returns output.
    ///
    /// - Parameters:
    ///   - kind: A CLI provider kind (`.claudeCLI` / `.codexCLI` / `.geminiCLI`).
    ///   - executablePath: The configured binary path from SettingsStore.
    ///   - providerFactory: Injection seam for tests. When nil, the production
    ///     CLI adapter for `kind` is constructed directly.
    /// - Returns: `.working` if the CLI streamed any non-empty text, `.noPath`
    ///   when no path is set, `.failed` with a message on any error, empty output,
    ///   or a non-CLI kind.
    static func validate(
        kind: ProviderKind,
        executablePath: String,
        providerFactory: (@Sendable (ProviderKind, String) -> any Provider)? = nil
    ) async -> Outcome {
        let trimmedPath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return .noPath }

        let provider: any Provider
        if let providerFactory {
            provider = providerFactory(kind, "")
        } else {
            switch kind {
            case .claudeCLI: provider = ClaudeCLIProvider()
            case .codexCLI:  provider = CodexCLIProvider()
            case .geminiCLI: provider = GeminiCLIProvider()
            default:         return .failed("Not a CLI provider.")
            }
        }

        do {
            let stream = try await provider.stream(
                systemPrompt: nil,
                input: probeInput,
                model: "",
                options: ProviderOptions(executablePath: trimmedPath)
            )
            for try await token in stream {
                if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .working
                }
            }
            return .failed("The CLI ran but returned no output.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
