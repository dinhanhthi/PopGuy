// ScriptActionEngineTests.swift
// PopGuyTests
//
// Unit tests for ScriptActionEngine:
//   1. Dispatch guard — non-scriptable types (.ai, .translation, .speech, .dictionary)
//      throw .unsupportedActionType when passed to run(_:text:fullText:).
//   2. ScriptActionError.errorDescription — each case is non-nil, non-empty, and
//      contains a stable English keyword (pins user-facing copy).
//   3. openURL with an empty template — expandURL returns nil before NSWorkspace is
//      touched, so the call throws .invalidURL without any side effect.
//
// Side-effect-free invariants only. Real process execution (shell, AppleScript,
// Shortcuts), NSWorkspace.open on a valid URL, and openURL on a valid template are
// verified manually and are NOT tested here.
//
// Note: ScriptActionError is not Equatable, so specific-case assertions use
// do/catch + pattern matching rather than #expect(throws: specificCaseValue).

import Foundation
import Testing
@testable import PopGuy

// MARK: - Helpers

private func action(type: CustomActionType, scriptSource: String = "") -> CustomAction {
    CustomAction(
        title: "Test",
        type: type,
        systemPrompt: "",
        scriptSource: scriptSource
    )
}

// MARK: - Dispatch guard

@Suite("ScriptActionEngine dispatch guard")
@MainActor
struct ScriptActionEngineDispatchGuardTests {

    @Test(".ai throws unsupportedActionType")
    func aiThrows() async throws {
        let engine = ScriptActionEngine()
        do {
            _ = try await engine.run(action(type: .ai), text: "hello", fullText: "hello")
            Issue.record("expected unsupportedActionType to be thrown")
        } catch ScriptActionError.unsupportedActionType(let t) {
            #expect(t == .ai)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(".translation throws unsupportedActionType")
    func translationThrows() async throws {
        let engine = ScriptActionEngine()
        do {
            _ = try await engine.run(action(type: .translation), text: "hello", fullText: "hello")
            Issue.record("expected unsupportedActionType to be thrown")
        } catch ScriptActionError.unsupportedActionType(let t) {
            #expect(t == .translation)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(".speech throws unsupportedActionType")
    func speechThrows() async throws {
        let engine = ScriptActionEngine()
        do {
            _ = try await engine.run(action(type: .speech), text: "hello", fullText: "hello")
            Issue.record("expected unsupportedActionType to be thrown")
        } catch ScriptActionError.unsupportedActionType(let t) {
            #expect(t == .speech)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(".dictionary throws unsupportedActionType")
    func dictionaryThrows() async throws {
        let engine = ScriptActionEngine()
        do {
            _ = try await engine.run(action(type: .dictionary), text: "hello", fullText: "hello")
            Issue.record("expected unsupportedActionType to be thrown")
        } catch ScriptActionError.unsupportedActionType(let t) {
            #expect(t == .dictionary)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - ScriptActionError.errorDescription

@Suite("ScriptActionError errorDescription")
struct ScriptActionErrorDescriptionTests {

    @Test(".invalidURL has non-empty English description containing 'URL'")
    func invalidURL() {
        let desc = ScriptActionError.invalidURL.errorDescription
        #expect(desc != nil)
        #expect(desc?.isEmpty == false)
        #expect(desc?.contains("URL") == true)
    }

    @Test(".appleScriptFailed embeds the message and contains 'AppleScript'")
    func appleScriptFailed() {
        let desc = ScriptActionError.appleScriptFailed("can't get text").errorDescription
        #expect(desc != nil)
        #expect(desc?.isEmpty == false)
        #expect(desc?.contains("AppleScript") == true)
        #expect(desc?.contains("can't get text") == true)
    }

    @Test(".shortcutsUnavailable contains 'Shortcuts'")
    func shortcutsUnavailable() {
        let desc = ScriptActionError.shortcutsUnavailable.errorDescription
        #expect(desc != nil)
        #expect(desc?.isEmpty == false)
        #expect(desc?.contains("Shortcuts") == true)
    }

    @Test(".processFailed embeds exit code and stderr snippet")
    func processFailed() {
        let desc = ScriptActionError.processFailed(code: 127, stderr: "command not found").errorDescription
        #expect(desc != nil)
        #expect(desc?.isEmpty == false)
        #expect(desc?.contains("127") == true)
        #expect(desc?.contains("command not found") == true)
    }

    @Test(".processFailed with empty stderr uses '(no output)' fallback")
    func processFailedEmptyStderr() {
        let desc = ScriptActionError.processFailed(code: 1, stderr: "").errorDescription
        #expect(desc?.contains("(no output)") == true)
    }

    @Test(".unsupportedActionType contains the type's displayName")
    func unsupportedActionType() {
        let desc = ScriptActionError.unsupportedActionType(.ai).errorDescription
        #expect(desc != nil)
        #expect(desc?.isEmpty == false)
        // CustomActionType.ai.displayName == "AI"
        #expect(desc?.contains("AI") == true)
    }
}

// MARK: - openURL with invalid template (no NSWorkspace side effect)

@Suite("ScriptActionEngine openURL invalid template")
@MainActor
struct ScriptActionEngineOpenURLTests {

    @Test("empty template throws .invalidURL without calling NSWorkspace")
    func emptyTemplateThrowsInvalidURL() {
        // PlaceholderExpander.expandURL(template: "", text: ...) calls
        // URL(string: "") which returns nil — the guard fires and .invalidURL
        // is thrown before NSWorkspace.shared.open(_:) is ever reached.
        let engine = ScriptActionEngine()
        let a = action(type: .openURL, scriptSource: "")
        do {
            _ = try engine.openURL(a, text: "hello", fullText: "hello")
            Issue.record("expected .invalidURL to be thrown")
        } catch ScriptActionError.invalidURL {
            // pass — correct error thrown before any side effect
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - collectOutput error remap (synthetic throwing stream, no subprocess)

@Suite("ScriptActionEngine collectOutput error remap")
@MainActor
struct ScriptActionEngineCollectOutputTests {

    /// A stream that yields nothing and immediately finishes by throwing `error`.
    private func throwingStream(_ error: Error) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    @Test("ProviderError.httpError remaps to processFailed with statusCode and body")
    func httpErrorRemap() async {
        let engine = ScriptActionEngine()
        do {
            _ = try await engine.collectOutput(
                from: throwingStream(ProviderError.httpError(statusCode: 127, body: "boom"))
            )
            Issue.record("expected processFailed to be thrown")
        } catch ScriptActionError.processFailed(let code, let stderr) {
            #expect(code == 127)
            #expect(stderr == "boom")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("ProviderError.transport remaps to processFailed code -1 with the message")
    func transportRemap() async {
        let engine = ScriptActionEngine()
        do {
            _ = try await engine.collectOutput(
                from: throwingStream(ProviderError.transport("offline"))
            )
            Issue.record("expected processFailed to be thrown")
        } catch ScriptActionError.processFailed(let code, let stderr) {
            #expect(code == -1)
            #expect(stderr == "offline")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("other ProviderError cases remap to processFailed code -1 (default arm)")
    func defaultRemap() async {
        let engine = ScriptActionEngine()
        do {
            _ = try await engine.collectOutput(
                from: throwingStream(ProviderError.decodingFailed("bad json"))
            )
            Issue.record("expected processFailed to be thrown")
        } catch ScriptActionError.processFailed(let code, _) {
            #expect(code == -1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
