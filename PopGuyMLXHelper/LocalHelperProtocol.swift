// LocalHelperProtocol.swift
// PopGuyMLXHelper
//
// Stdio JSON-lines wire protocol between the PopGuy app and PopGuyMLXHelper.
// One JSON object per line. Requests flow app → helper; responses flow helper → app.
// Both copies (helper + app targets) must be kept byte-identical.

import Foundation

// MARK: - Request

/// A request sent by the parent app to the helper over stdin.
// nonisolated: prevents SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor from isolating
// Codable conformances, making encode/decode callable from any concurrency context.
public nonisolated enum HelperRequest: Codable, Equatable, Sendable {

    /// Liveness check. The helper responds with `.ready`.
    case ping

    /// Download a model by HuggingFace repo id (e.g. "mlx-community/gemma-4-e2b-it-4bit").
    /// The helper streams `.progress` lines then `.done` when complete.
    case download(modelID: String)

    /// Run inference on a loaded model. The helper streams `.token` lines then `.done`.
    case generate(
        modelID: String,
        systemPrompt: String?,
        input: String,
        maxTokens: Int,
        temperature: Double
    )

    /// Unload the current model and release GPU memory.
    case unload

    /// Query the currently loaded model id. The helper responds with `.status`.
    case status

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case type
        case modelID
        case systemPrompt
        case input
        case maxTokens
        case temperature
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ping":
            self = .ping
        case "download":
            let modelID = try container.decode(String.self, forKey: .modelID)
            self = .download(modelID: modelID)
        case "generate":
            let modelID = try container.decode(String.self, forKey: .modelID)
            let systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            let input = try container.decode(String.self, forKey: .input)
            let maxTokens = try container.decode(Int.self, forKey: .maxTokens)
            let temperature = try container.decode(Double.self, forKey: .temperature)
            self = .generate(
                modelID: modelID,
                systemPrompt: systemPrompt,
                input: input,
                maxTokens: maxTokens,
                temperature: temperature
            )
        case "unload":
            self = .unload
        case "status":
            self = .status
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown request type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping:
            try container.encode("ping", forKey: .type)
        case .download(let modelID):
            try container.encode("download", forKey: .type)
            try container.encode(modelID, forKey: .modelID)
        case .generate(let modelID, let systemPrompt, let input, let maxTokens, let temperature):
            try container.encode("generate", forKey: .type)
            try container.encode(modelID, forKey: .modelID)
            try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
            try container.encode(input, forKey: .input)
            try container.encode(maxTokens, forKey: .maxTokens)
            try container.encode(temperature, forKey: .temperature)
        case .unload:
            try container.encode("unload", forKey: .type)
        case .status:
            try container.encode("status", forKey: .type)
        }
    }
}

// MARK: - Response

/// A response sent by the helper to the parent app over stdout.
// nonisolated: same reason as HelperRequest — allows decode in any context.
public nonisolated enum HelperResponse: Codable, Equatable, Sendable {

    /// Helper is alive and ready for requests.
    case ready

    /// Download progress update for a model.
    case progress(modelID: String, fraction: Double, downloadedBytes: Int64, totalBytes: Int64)

    /// A generated token delta (streaming).
    case token(delta: String)

    /// Request completed successfully.
    case done

    /// An error occurred. The helper remains running.
    case error(message: String)

    /// The currently loaded model id, or nil when no model is loaded.
    case status(loadedModelID: String?)

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case type
        case modelID
        case fraction
        case downloadedBytes
        case totalBytes
        case delta
        case message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ready":
            self = .ready
        case "progress":
            let modelID = try container.decode(String.self, forKey: .modelID)
            let fraction = try container.decode(Double.self, forKey: .fraction)
            let downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
            let totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
            self = .progress(
                modelID: modelID,
                fraction: fraction,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes
            )
        case "token":
            let delta = try container.decode(String.self, forKey: .delta)
            self = .token(delta: delta)
        case "done":
            self = .done
        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message: message)
        case "status":
            let loadedModelID = try container.decodeIfPresent(String.self, forKey: .modelID)
            self = .status(loadedModelID: loadedModelID)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown response type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready:
            try container.encode("ready", forKey: .type)
        case .progress(let modelID, let fraction, let downloadedBytes, let totalBytes):
            try container.encode("progress", forKey: .type)
            try container.encode(modelID, forKey: .modelID)
            try container.encode(fraction, forKey: .fraction)
            try container.encode(downloadedBytes, forKey: .downloadedBytes)
            try container.encode(totalBytes, forKey: .totalBytes)
        case .token(let delta):
            try container.encode("token", forKey: .type)
            try container.encode(delta, forKey: .delta)
        case .done:
            try container.encode("done", forKey: .type)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        case .status(let loadedModelID):
            try container.encode("status", forKey: .type)
            try container.encodeIfPresent(loadedModelID, forKey: .modelID)
        }
    }
}
