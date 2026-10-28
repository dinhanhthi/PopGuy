// OCRTextRecognizer.swift
// PopGuy
//
// Extracts text from a captured screen image using the Vision framework.

import Vision
import CoreGraphics

/// Recognizes text in an image using Vision's text-recognition request.
///
/// Holds no state, so it is trivially `Sendable`. Vision's
/// `VNImageRequestHandler.perform` is synchronous and blocking, so the
/// actual recognition work runs in a detached task off the caller's actor
/// (typically MainActor) and the async wrapper only awaits its result.
enum OCRTextRecognizer {

    /// Recognizes text in `image`, returning the recognized lines joined by
    /// "\n", ordered top-to-bottom then left-to-right.
    static func recognizeText(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try recognizeTextSync(in: image)
        }.value
    }

    /// Synchronous, blocking recognition. Must run off the main actor.
    ///
    /// `nonisolated` is required because this project defaults new
    /// declarations to `@MainActor` isolation (`-default-isolation=MainActor`);
    /// without it, this method would implicitly become MainActor-isolated
    /// and calling it from `Task.detached` would defeat the point of
    /// detaching Vision's blocking work off the main actor.
    private nonisolated static func recognizeTextSync(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []

        // Vision's boundingBox is normalized with a bottom-left origin, so a
        // larger y is higher on screen. Sort top-to-bottom (descending y),
        // then left-to-right (ascending x) within a line.
        let sorted = observations.sorted { lhs, rhs in
            let lhsBox = lhs.boundingBox
            let rhsBox = rhs.boundingBox
            if lhsBox.origin.y != rhsBox.origin.y {
                return lhsBox.origin.y > rhsBox.origin.y
            }
            return lhsBox.origin.x < rhsBox.origin.x
        }

        let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
