// ModelFamilyDetection.swift
// PopGuy (app target)
//
// Input policy helpers used by the app and mirrored in the helper target
// (PopGuyMLXHelper/ModelRunner.swift). All three functions must be kept byte-identical
// between the two targets until the Phase 3 model catalog lands and consolidates them.
//
// NOTE: Phase 3 will replace isQwenFamily substring detection with an authoritative family
// tag from the model catalog. The catalog lookup is more reliable than id heuristics for
// edge cases.
//
// MIRROR: isQwenFamily, clampMaxTokens, sanitizeTemperature
//   keep in sync with PopGuyMLXHelper/ModelRunner.swift.

import Foundation

/// Returns `true` when the HuggingFace repo id belongs to the Qwen or QwQ reasoning family.
///
/// Matches "qwen" (covers Qwen3, Qwen3.5, Qwen2, etc.) and "qwq" (QwQ reasoning models)
/// case-insensitively. Both families require `enable_thinking: false` to suppress the reasoning
/// trace via the MLX chat-template `additionalContext`.
public func isQwenFamily(_ modelID: String) -> Bool {
    let lower = modelID.lowercased()
    return lower.contains("qwen") || lower.contains("qwq")
}

/// Maximum allowed `maxTokens` value — prevents runaway generations.
public let kMaxTokensLimit = 16384

/// Clamps `maxTokens` to 1...kMaxTokensLimit.
/// Values ≤ 0 are treated as 1; values > kMaxTokensLimit are capped.
public func clampMaxTokens(_ value: Int) -> Int {
    max(1, min(value, kMaxTokensLimit))
}

/// Sanitizes `temperature` for the Metal sampler.
/// NaN and negative values are rejected (replaced with 0.7); values above 2.0 are capped.
/// The Metal sampler's `== 0` ArgMax branch is preserved when temperature is exactly 0.
public func sanitizeTemperature(_ value: Double) -> Double {
    guard value.isFinite, value >= 0 else { return 0.7 }
    return min(value, 2.0)
}
