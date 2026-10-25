// CLIProviderValidatorTests.swift
// PopGuyTests
//
// Tests CLIProviderValidator.validate using an injected mock provider — no real
// CLI subprocess is spawned. Covers: empty path, working (non-empty output),
// empty output, and a throwing provider.

import Foundation
import Testing
@testable import PopGuy

// MARK: - Mock

/// A Provider stub for CLI-validation tests. Emits `tokens`, or throws `error`
/// if set, when stream() is called.
private final class StubProvider: Provider, @unchecked Sendable {
    let tokens: [String]
    let error: Error?

    init(tokens: [String] = [], error: Error? = nil) {
        self.tokens = tokens
        self.error = error
    }

    nonisolated func stream(
        systemPrompt: String?,
        input: String,
        model: String,
        options: ProviderOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        if let error { throw error }
        let tokens = self.tokens
        return AsyncThrowingStream { continuation in
            for token in tokens { continuation.yield(token) }
            continuation.finish()
        }
    }
}

// MARK: - Tests

@Suite("CLIProviderValidator")
struct CLIProviderValidatorTests {

    @Test("Empty path returns .noPath without touching the factory")
    func emptyPathReturnsNoPath() async {
        let outcome = await CLIProviderValidator.validate(
            kind: .claudeCLI,
            executablePath: "   ",
            providerFactory: { _, _ in
                Issue.record("factory should not be called when path is empty")
                return StubProvider()
            }
        )
        #expect(outcome == .noPath)
    }

    @Test("Non-empty output returns .working")
    func outputReturnsWorking() async {
        let outcome = await CLIProviderValidator.validate(
            kind: .claudeCLI,
            executablePath: "/usr/local/bin/claude",
            providerFactory: { _, _ in StubProvider(tokens: ["OK"]) }
        )
        #expect(outcome == .working)
    }

    @Test("Whitespace-only output is not treated as working")
    func whitespaceOutputFails() async {
        let outcome = await CLIProviderValidator.validate(
            kind: .codexCLI,
            executablePath: "/usr/local/bin/codex",
            providerFactory: { _, _ in StubProvider(tokens: ["   ", "\n"]) }
        )
        #expect(outcome == .failed("The CLI ran but returned no output."))
    }

    @Test("Empty stream returns .failed")
    func emptyStreamFails() async {
        let outcome = await CLIProviderValidator.validate(
            kind: .geminiCLI,
            executablePath: "/usr/local/bin/gemini",
            providerFactory: { _, _ in StubProvider(tokens: []) }
        )
        if case .failed = outcome { } else {
            Issue.record("expected .failed, got \(outcome)")
        }
    }

    @Test("A throwing provider returns .failed with the error message")
    func throwingProviderFails() async {
        let outcome = await CLIProviderValidator.validate(
            kind: .claudeCLI,
            executablePath: "/usr/local/bin/claude",
            providerFactory: { _, _ in
                StubProvider(error: ProviderError.transport("CLI not found at /x."))
            }
        )
        if case .failed(let msg) = outcome {
            #expect(msg.contains("CLI not found"))
        } else {
            Issue.record("expected .failed, got \(outcome)")
        }
    }
}
