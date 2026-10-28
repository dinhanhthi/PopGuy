// ProviderProtocolTests.swift
// PopGuyTests
//
// Proves that the Provider protocol compiles and a stub conformer
// can stream tokens through AsyncThrowingStream.

import Foundation
import Testing
@testable import PopGuy

@Suite("ProviderProtocol")
struct ProviderProtocolTests {

    // A minimal stub conformer proving the contract is implementable.
    private struct StubProvider: Provider {
        func stream(
            systemPrompt: String?,
            input: String,
            model: String,
            options: ProviderOptions
        ) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("hello")
                continuation.yield(" world")
                continuation.finish()
            }
        }
    }

    @Test("stub conformer streams all tokens")
    func stubStreamsTokens() async throws {
        let provider: any Provider = StubProvider()
        let options = ProviderOptions()
        var collected: [String] = []

        let stream = try await provider.stream(
            systemPrompt: "You are helpful.",
            input: "test input",
            model: "stub-model",
            options: options
        )
        for try await token in stream {
            collected.append(token)
        }

        #expect(collected == ["hello", " world"])
    }

    @Test("ProviderOptions default targetLanguage is nil")
    func defaultOptionsHaveNilTargetLanguage() async {
        let opts = ProviderOptions()
        #expect(opts.targetLanguage == nil)
    }

    @Test("ProviderOptions baseURL override can be set")
    func optionsBaseURLOverride() async {
        let url = URL(string: "http://localhost:11434/v1")!
        let opts = ProviderOptions(baseURL: url)
        #expect(opts.baseURL == url)
    }

    @Test("ProviderKind covers all thirteen providers")
    func providerKindCoversAll() async {
        // Exhaustively matching all cases ensures no new case is added without
        // updating this test. Count must match ProviderKind.allCases.count.
        let kinds: [ProviderKind] = [
            .openAI, .anthropic, .ollama, .deepL, .googleTranslate,
            .gemini, .glm, .openRouter, .custom,
            .claudeCLI, .codexCLI, .geminiCLI,
            .mlxLocal,
        ]
        #expect(kinds.count == 13)
        #expect(ProviderKind.allCases.count == 13)
    }

    @Test("usesLocalCLI is true for exactly claudeCLI, codexCLI, geminiCLI")
    func usesLocalCLIExactSet() async {
        let cliKinds: Set<ProviderKind> = [.claudeCLI, .codexCLI, .geminiCLI]
        for kind in ProviderKind.allCases {
            if cliKinds.contains(kind) {
                #expect(kind.usesLocalCLI, "\(kind) should have usesLocalCLI == true")
            } else {
                #expect(!kind.usesLocalCLI, "\(kind) should have usesLocalCLI == false")
            }
        }
    }

    @Test("ProviderOptions executablePath nil/non-nil round-trip")
    func optionsExecutablePathRoundTrip() async {
        let opts1 = ProviderOptions()
        #expect(opts1.executablePath == nil)

        let opts2 = ProviderOptions(executablePath: "/usr/local/bin/claude")
        #expect(opts2.executablePath == "/usr/local/bin/claude")
    }

    @Test("ProviderError is throwable")
    func providerErrorIsThrowable() async {
        let err: ProviderError = .transport("timeout")
        #expect(err.errorDescription?.isEmpty == false)
    }
}
