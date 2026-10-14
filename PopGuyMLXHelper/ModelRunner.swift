// ModelRunner.swift
// PopGuyMLXHelper
//
// Actor that owns a resident ModelContainer. Handles model loading via the official MLXHuggingFace
// macro integration (HubClient + Tokenizers.AutoTokenizer), caching (one model at a time), and
// streaming token generation.
//
// No-think policy: for the Qwen model family, enable_thinking: false is injected into
// UserInput.additionalContext so the chat-template suppresses the reasoning trace.
// Gemma models need no special context.
//
// Raw mode: the input is tokenized as-is and fed straight to the model, bypassing the chat
// template (and its stdout warning when a model ships none). System prompt and the Qwen
// no-think context are ignored in this mode.

import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

// MARK: - Shared HubClient

/// App-support cache directory: ~/Library/Application Support/PopGuy/models/huggingface/hub/
///
/// This directory is passed to `HubCache` so that `#hubDownloader(sharedHubClient)` and
/// `ModelDownloader` both read/write the same location.
///
/// Exposed as a top-level constant so `main.swift`'s disk-polling progress sampler can
/// derive the model's `blobs/` path without re-deriving the cache root independently.
let sharedHubCacheDir: URL = {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return appSupport
        .appending(component: "PopGuy", directoryHint: .isDirectory)
        .appending(component: "models", directoryHint: .isDirectory)
        .appending(component: "huggingface", directoryHint: .isDirectory)
        .appending(component: "hub", directoryHint: .isDirectory)
}()

let sharedHubClient: HubClient = {
    let cache = HubCache(cacheDirectory: sharedHubCacheDir)
    return HubClient(cache: cache)
}()

// MARK: - Input policy helpers (mirrored in app target)
//
// MIRROR: isQwenFamily, clampMaxTokens, sanitizeTemperature
//   keep byte-identical with PopGuy/Modules/ProviderLayer/LocalEngine/ModelFamilyDetection.swift
//   until the Phase 3 model catalog consolidates them.

/// Returns `true` when the HuggingFace repo id belongs to the Qwen or QwQ reasoning family.
///
/// Matches "qwen" (covers Qwen3, Qwen3.5, Qwen2, etc.) and "qwq" (QwQ reasoning models)
/// case-insensitively. Both families require `enable_thinking: false` to suppress the reasoning
/// trace via the chat-template `additionalContext`.
func isQwenFamily(_ modelID: String) -> Bool {
    let lower = modelID.lowercased()
    return lower.contains("qwen") || lower.contains("qwq")
}

/// Maximum allowed `maxTokens` value — prevents runaway generations.
let kMaxTokensLimit = 16384

/// Clamps `maxTokens` to 1...kMaxTokensLimit.
/// Values ≤ 0 are treated as 1; values > kMaxTokensLimit are capped.
func clampMaxTokens(_ value: Int) -> Int {
    max(1, min(value, kMaxTokensLimit))
}

/// Sanitizes `temperature` for the Metal sampler.
/// NaN and negative values are rejected (replaced with 0.7); values above 2.0 are capped.
/// The Metal sampler's `== 0` ArgMax branch is preserved when temperature is exactly 0.
func sanitizeTemperature(_ value: Double) -> Double {
    guard value.isFinite, value >= 0 else { return 0.7 }
    return min(value, 2.0)
}

/// Helper-only (not mirrored). Sanitizes `topP`: nil, non-finite or outside (0, 1] → 1.0 (disabled).
func sanitizeTopP(_ value: Double?) -> Double {
    guard let value, value.isFinite, value > 0, value <= 1 else { return 1.0 }
    return value
}

// MARK: - ModelRunner

/// Actor that manages a single resident ModelContainer.
///
/// Loading a different model automatically unloads the current one.
/// Generation is serialized through actor isolation — only one inference runs at a time.
actor ModelRunner {

    private var currentModelID: String?
    private var container: ModelContainer?

    // MARK: - Lifecycle

    /// Unload the currently cached model and release GPU memory.
    func unload() {
        container = nil
        currentModelID = nil
    }

    /// Returns the id of the currently loaded model, or nil when nothing is loaded.
    func loadedModelID() -> String? {
        currentModelID
    }

    // MARK: - Generation

    /// Generate a streaming response for the given input.
    ///
    /// The returned `AsyncThrowingStream` yields token delta strings. The stream ends when
    /// generation reaches the EOS token or `maxTokens` is exhausted.
    ///
    /// Inputs are sanitized before use: `maxTokens` is clamped to 1...16384; `temperature`
    /// is forced finite and non-negative (NaN/negative → 0.7, max 2.0).
    ///
    /// For Qwen/QwQ models, `enable_thinking: false` is injected into `UserInput.additionalContext`
    /// to suppress the reasoning trace via the chat template.
    ///
    /// When `rawPrompt` is true, `input` is tokenized directly (no chat template) and
    /// `systemPrompt` is ignored. `topP` nil or out of (0, 1] disables nucleus sampling.
    func generate(
        modelID: String,
        systemPrompt: String?,
        input: String,
        maxTokens: Int,
        temperature: Double,
        rawPrompt: Bool,
        topP: Double?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let loaded = try await self.ensureLoaded(modelID: modelID)

                    let params = GenerateParameters(
                        maxTokens: clampMaxTokens(maxTokens),
                        temperature: Float(sanitizeTemperature(temperature)),
                        topP: Float(sanitizeTopP(topP))
                    )

                    let lmInput: LMInput
                    if rawPrompt {
                        let tokens = await loaded.encode(input)
                        #if DEBUG
                        // stderr only: stdout is the JSON line protocol.
                        let head = tokens.prefix(5).map(String.init).joined(separator: ",")
                        FileHandle.standardError.write(Data("raw prompt tokens: [\(head)]\n".utf8))
                        #endif
                        lmInput = LMInput(tokens: MLXArray(tokens))
                    } else {
                        var messages: [Chat.Message] = []
                        if let system = systemPrompt, !system.isEmpty {
                            messages.append(.system(system))
                        }
                        messages.append(.user(input))

                        let additionalContext: [String: any Sendable]? =
                            isQwenFamily(modelID) ? ["enable_thinking": false] : nil

                        let userInput = UserInput(
                            chat: messages,
                            additionalContext: additionalContext
                        )

                        lmInput = try await loaded.prepare(input: userInput)
                    }
                    let stream = try await loaded.generate(input: lmInput, parameters: params)

                    for await generation in stream {
                        switch generation {
                        case .chunk(let text):
                            continuation.yield(text)
                        case .info:
                            break
                        case .toolCall:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    /// Returns the cached ModelContainer if it matches `modelID`, or downloads and loads a new one.
    private func ensureLoaded(modelID: String) async throws -> ModelContainer {
        if let existing = container, currentModelID == modelID {
            return existing
        }
        container = nil
        currentModelID = nil

        let loaded = try await loadModelContainer(
            from: #hubDownloader(sharedHubClient),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: modelID)
        )

        container = loaded
        currentModelID = modelID
        return loaded
    }
}
