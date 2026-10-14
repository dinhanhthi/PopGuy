// MLXLocalProviderTests.swift
// PopGuyTests
//
// Tests for MLXLocalProvider argument routing (chat vs completion-only models)
// and CompletionOutputTrimmer.

import CryptoKit
import Foundation
import Testing
@testable import PopGuy

@Suite("MLXLocalProvider")
struct MLXLocalProviderTests {

    // MARK: - Completion model

    @Test("completion model drops the system prompt and sends the built prompt raw")
    func completionModelArgs() throws {
        let draft = "Some draft text."
        let args = try MLXLocalProvider.makeArgs(
            systemPrompt: "Improve this.",
            input: draft,
            modelID: "humanizer-12b",
            maxTokens: 4096
        )
        #expect(args.repoID == "mlx-community/humanizer-12b-OptiQ-4bit")
        #expect(args.systemPrompt == nil)
        #expect(args.input == CompletionPrompt.humanizer.build(draft: draft))
        #expect(args.rawPrompt == true)
        #expect(args.temperature == 1.0)
        #expect(args.topP == 0.95)
        #expect(args.maxTokens <= 4096)
    }

    @Test("completion prompt built from \"X\" matches the published layout hash")
    func completionInputHash() throws {
        let args = try MLXLocalProvider.makeArgs(
            systemPrompt: nil,
            input: "X",
            modelID: "humanizer-12b",
            maxTokens: 4096
        )
        let digest = SHA256.hash(data: Data(args.input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex.prefix(16) == "cc51d66b4c593fbe")
    }

    // MARK: - Chat model

    @Test("chat model args are unchanged apart from the repo id mapping")
    func chatModelArgs() throws {
        let args = try MLXLocalProvider.makeArgs(
            systemPrompt: "Improve this.",
            input: "  Draft\n",
            modelID: "gemma-4-e2b",
            maxTokens: 4096
        )
        #expect(args.repoID == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(args.systemPrompt == "Improve this.")
        #expect(args.input == "  Draft\n")
        #expect(args.maxTokens == 4096)
        #expect(args.temperature == 0.7)
        #expect(args.topP == nil)
        #expect(args.rawPrompt == false)
    }

    // MARK: - Input guard

    @Test("draft over the completion model's character limit throws with a clear message")
    func tooLongDraftThrows() {
        let draft = String(repeating: "a", count: 10_001)
        #expect {
            _ = try MLXLocalProvider.makeArgs(
                systemPrompt: nil, input: draft, modelID: "humanizer-12b", maxTokens: 4096
            )
        } throws: { error in
            guard error is MLXLocalInputError else { return false }
            return error.localizedDescription
                == "This text is too long for Humanizer 12B (4-bit). "
                + "Select a shorter passage or choose another model for this action."
        }
    }

    @Test("draft at exactly the character limit is accepted")
    func draftAtLimitAccepted() throws {
        let draft = String(repeating: "a", count: 10_000)
        _ = try MLXLocalProvider.makeArgs(
            systemPrompt: nil, input: draft, modelID: "humanizer-12b", maxTokens: 4096
        )
    }

    // MARK: - CompletionOutputTrimmer

    private func run(_ deltas: [String]) -> String {
        var trimmer = CompletionOutputTrimmer()
        return deltas.map { trimmer.feed($0) }.joined() + trimmer.finish()
    }

    @Test("trimmer drops leading and trailing whitespace")
    func trimmerTrimsEdges() {
        #expect(run(["\n\n", "Hi", " there", "\n"]) == "Hi there")
    }

    @Test("trimmer keeps whitespace between words split across deltas")
    func trimmerKeepsInnerWhitespace() {
        #expect(run(["Hi", " ", "there"]) == "Hi there")
    }
}
