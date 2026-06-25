// ModelDownloader.swift
// PopGuyMLXHelper
//
// HubClient-based snapshot downloader. Wraps HuggingFace.HubClient to pre-populate the shared
// cache before ModelRunner loads a model, so that a subsequent generate request skips re-download.
// The cache directory matches what #hubDownloader(hubClient) reads: the HubClient's own HubCache.

import Foundation
import HuggingFace

// MARK: - ModelDownloader

/// Downloads a HuggingFace model snapshot into the app's custom HubCache directory.
///
/// Uses the same `HubClient` instance (and therefore the same `HubCache`) as `ModelRunner`,
/// ensuring that files downloaded here are found by the loader without re-downloading.
struct ModelDownloader: Sendable {

    let hubClient: HubClient

    /// Download a model snapshot into the shared cache, streaming progress via the callback.
    ///
    /// Idempotent: `HubClient.downloadSnapshot` skips already-cached blobs via ETag comparison
    /// before issuing each file request (swift-huggingface `HubClient+Files.swift`, ETag-aware
    /// cache flow, line ~519). Already-cached files are skipped without a network round-trip.
    ///
    /// - Parameters:
    ///   - modelID: HuggingFace repo id (e.g. "mlx-community/gemma-4-e2b-it-4bit").
    ///   - patterns: Glob patterns for the files to download.
    ///   - progressHandler: Called on the main actor with cumulative progress.
    /// - Returns: URL to the local snapshot directory.
    func downloadSnapshot(
        modelID: String,
        patterns: [String] = ["*.safetensors", "*.json", "*.jinja"],
        progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: modelID) else {
            throw DownloadError.invalidRepoID(modelID)
        }
        return try await hubClient.downloadSnapshot(
            of: repoID,
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

// MARK: - DownloadError

enum DownloadError: LocalizedError {
    case invalidRepoID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepoID(let id):
            return "Invalid HuggingFace repo id '\(id)'. Expected format 'namespace/name'."
        }
    }
}
