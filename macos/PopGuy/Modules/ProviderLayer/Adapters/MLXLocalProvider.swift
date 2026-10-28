// MLXLocalProvider.swift
// PopGuy — ProviderLayer/Adapters
//
// Provider adapter for the on-device MLX engine (PopGuyMLXHelper subprocess).
//
// No API key, no base URL. All inference is local via MLXHelperManager.
// Temperature defaults to 0.7 (sanitized); maxTokens comes from ProviderOptions.
// Completion-only models (CompletionPrompt) are sent their fixed prompt in raw
// mode with the prompt's own sampling, and their output is edge-trimmed.
//
// Family is intentionally not looked up here: HelperRequest.generate must stay
// byte-identical with the helper-side copy of LocalHelperProtocol.swift (no family
// field on the wire), so there is no way to forward a resolved family. The helper
// resolves family itself via its own isQwenFamily() heuristic. Catalog-family
// consolidation is deferred to a future phase.

import Foundation

// MARK: - MLXLocalProvider

/// Streams tokens from the on-device MLX helper subprocess.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct MLXLocalProvider: Provider {

    // MARK: - Provider

    func stream(
        systemPrompt: String?,
        input: String,
        model: String,
        options: ProviderOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        let args = try Self.makeArgs(
            systemPrompt: systemPrompt,
            input: input,
            modelID: model,
            maxTokens: options.maxTokens
        )

        do {
            let tokens = try await MLXHelperManager.shared.generate(
                modelID: args.repoID,
                systemPrompt: args.systemPrompt,
                input: args.input,
                maxTokens: args.maxTokens,
                temperature: args.temperature,
                rawPrompt: args.rawPrompt,
                topP: args.topP
            )
            return args.rawPrompt ? Self.trimmed(tokens) : tokens
        } catch let helperError as MLXHelperError {
            throw ProviderError.transport(helperError.localizedDescription)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }
    // MARK: - Arguments

    /// Resolves the helper arguments for `modelID`.
    ///
    /// Chat models get the action's system prompt and input as-is. Completion-only
    /// models (see `CompletionPrompt`) get their fixed prompt in raw mode instead:
    /// the system prompt (action, global prompt, Preserve formatting) is dropped
    /// because the model was trained on one exact layout.
    static func makeArgs(
        systemPrompt: String?,
        input: String,
        modelID: String,
        maxTokens: Int
    ) throws -> MLXGenerateArgs {
        // Inline the clamping/sanitizing rather than calling the MainActor-isolated
        // global helpers from ModelFamilyDetection.swift (inferred MainActor due to
        // SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor on the app target).
        let clampedMaxTokens = max(1, min(maxTokens, 16384))

        // The action stores the catalog id (e.g. "gemma-4-e2b"); the helper needs the
        // HuggingFace repo id (e.g. "mlx-community/gemma-4-e2b-it-4bit") to load the model.
        // Map id -> repoID via the catalog, matching the download path. Fall back to the
        // raw value so a directly-entered repo id still works.
        let catalogModel = LocalModelCatalog.model(for: modelID)
        let repoID = catalogModel?.repoID ?? modelID

        guard let catalogModel, let prompt = catalogModel.completionPrompt else {
            return MLXGenerateArgs(
                repoID: repoID,
                systemPrompt: systemPrompt,
                input: input,
                maxTokens: clampedMaxTokens,
                temperature: 0.7,  // ProviderOptions has no temperature field; use safe default.
                rawPrompt: false,
                topP: nil
            )
        }

        let draftLength = input.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard draftLength <= prompt.maxInputCharacters else {
            throw MLXLocalInputError.inputTooLong(modelName: catalogModel.displayName)
        }

        return MLXGenerateArgs(
            repoID: repoID,
            systemPrompt: nil,
            input: prompt.build(draft: input),
            maxTokens: min(clampedMaxTokens, prompt.maxNewTokens(forDraft: input)),
            temperature: prompt.temperature,
            rawPrompt: true,
            topP: prompt.topP
        )
    }

    // MARK: - Output trimming

    /// Wraps a completion model's token stream with `CompletionOutputTrimmer`.
    private static func trimmed(
        _ tokens: AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var trimmer = CompletionOutputTrimmer()
                do {
                    for try await delta in tokens {
                        let text = trimmer.feed(delta)
                        if !text.isEmpty { continuation.yield(text) }
                    }
                    let tail = trimmer.finish()
                    if !tail.isEmpty { continuation.yield(tail) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - MLXGenerateArgs

/// Arguments forwarded to `MLXHelperManager.generate` for one request.
nonisolated struct MLXGenerateArgs: Sendable {
    let repoID: String
    let systemPrompt: String?
    let input: String
    let maxTokens: Int
    let temperature: Double
    let rawPrompt: Bool
    let topP: Double?
}

// MARK: - MLXLocalInputError

/// Input rejected before reaching the helper. The message is shown to the user as-is.
nonisolated enum MLXLocalInputError: LocalizedError {
    case inputTooLong(modelName: String)

    var errorDescription: String? {
        switch self {
        case .inputTooLong(let modelName):
            return "This text is too long for \(modelName). "
                + "Select a shorter passage or choose another model for this action."
        }
    }
}

// MARK: - CompletionOutputTrimmer

/// Trims a completion model's streamed output without buffering the whole result.
///
/// Leading whitespace is dropped; trailing whitespace is held back until more
/// text arrives, so whitespace between words survives while the final trailing
/// whitespace is never emitted.
nonisolated struct CompletionOutputTrimmer {
    private var started = false
    private var pendingWhitespace = ""

    /// Returns the text to emit now for `delta`.
    mutating func feed(_ delta: String) -> String {
        var output = ""
        for character in delta {
            if character.isWhitespace {
                if started { pendingWhitespace.append(character) }
            } else {
                output += pendingWhitespace
                output.append(character)
                pendingWhitespace = ""
                started = true
            }
        }
        return output
    }

    /// Returns the text to emit at end of stream (held whitespace is dropped).
    mutating func finish() -> String {
        pendingWhitespace = ""
        return ""
    }
}
