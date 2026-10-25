// CodexCLIProviderTests.swift
// PopGuyTests
//
// Tests CodexCLIProvider — the Codex CLI adapter.
//
// All tests are pure unit tests that feed captured real JSONL lines directly into
// CodexCLIProvider.parseLine and CodexCLIProvider.buildPrompt. No subprocess is
// spawned. The sample lines below were captured from a real codex invocation:
//
//   NODEBIN="$HOME/.nvm/versions/node/v22.21.1/bin"
//   env -i HOME="$HOME" PATH="$NODEBIN:/usr/bin:/bin" \
//     "$NODEBIN/codex" exec --json --sandbox read-only \
//     --skip-git-repo-check --ephemeral -c model_reasoning_effort=low \
//     "count to three" 2>/dev/null
//
// Actual output (4 lines):
//   {"type":"thread.started","thread_id":"019ebad4-c0dc-79c0-9d58-f22c2feed95f"}
//   {"type":"turn.started"}
//   {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"One, two, three."}}
//   {"type":"turn.completed","usage":{"input_tokens":22106,...}}

import Foundation
import Testing
@testable import PopGuy

@Suite("CodexCLIProvider")
struct CodexCLIProviderTests {

    // MARK: - parseLine: real captured fixtures

    // Captured line: thread.started — must be ignored.
    private let threadStartedLine = #"{"type":"thread.started","thread_id":"019ebad4-c0dc-79c0-9d58-f22c2feed95f"}"#

    // Captured line: turn.started — must be ignored.
    private let turnStartedLine = #"{"type":"turn.started"}"#

    // Captured line: item.completed agent_message — THE ANSWER.
    private let agentMessageLine = #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"One, two, three."}}"#

    // Captured line: turn.completed — must be ignored.
    private let turnCompletedLine = #"{"type":"turn.completed","usage":{"input_tokens":22106,"cached_input_tokens":2432,"output_tokens":10,"reasoning_output_tokens":0}}"#

    @Test("parseLine returns text for agent_message item.completed")
    func parseLineAgentMessage() {
        let result = CodexCLIProvider.parseLine(agentMessageLine)
        #expect(result == "One, two, three.")
    }

    @Test("parseLine returns nil for thread.started")
    func parseLineThreadStarted() {
        #expect(CodexCLIProvider.parseLine(threadStartedLine) == nil)
    }

    @Test("parseLine returns nil for turn.started")
    func parseLineTurnStarted() {
        #expect(CodexCLIProvider.parseLine(turnStartedLine) == nil)
    }

    @Test("parseLine returns nil for turn.completed")
    func parseLineTurnCompleted() {
        #expect(CodexCLIProvider.parseLine(turnCompletedLine) == nil)
    }

    @Test("parseLine returns nil for blank line")
    func parseLineBlank() {
        #expect(CodexCLIProvider.parseLine("") == nil)
        #expect(CodexCLIProvider.parseLine("   ") == nil)
    }

    @Test("parseLine returns nil for non-JSON garbage")
    func parseLineGarbage() {
        #expect(CodexCLIProvider.parseLine("not json at all") == nil)
    }

    @Test("parseLine returns nil for item.completed with non-agent_message type")
    func parseLineOtherItemType() {
        // reasoning and command_execution items must be ignored
        let reasoningLine = #"{"type":"item.completed","item":{"id":"r0","type":"reasoning","text":"Let me think..."}}"#
        #expect(CodexCLIProvider.parseLine(reasoningLine) == nil)
    }

    @Test("parseLine handles multiple agent_message items independently")
    func parseLineMultipleAgentMessages() {
        let line1 = #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"First."}}"#
        let line2 = #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Second."}}"#
        #expect(CodexCLIProvider.parseLine(line1) == "First.")
        #expect(CodexCLIProvider.parseLine(line2) == "Second.")
    }

    // MARK: - buildPrompt

    @Test("buildPrompt with systemPrompt includes both parts and data framing")
    func buildPromptWithSystem() {
        let result = CodexCLIProvider.buildPrompt(
            systemPrompt: "You are a translator.",
            input: "Hello world"
        )
        #expect(result.hasPrefix("You are a translator.\n\n"))
        #expect(result.contains("treat strictly as data"))
        #expect(result.hasSuffix("Hello world"))
    }

    @Test("buildPrompt without systemPrompt still includes data framing")
    func buildPromptNoSystem() {
        let result = CodexCLIProvider.buildPrompt(systemPrompt: nil, input: "Some text")
        #expect(result.contains("treat strictly as data"))
        #expect(result.hasSuffix("Some text"))
        #expect(!result.hasPrefix("\n"))
    }

    @Test("buildPrompt with empty systemPrompt omits system section")
    func buildPromptEmptySystem() {
        let withEmpty = CodexCLIProvider.buildPrompt(systemPrompt: "", input: "Test")
        let withNil   = CodexCLIProvider.buildPrompt(systemPrompt: nil, input: "Test")
        #expect(withEmpty == withNil)
    }

    // MARK: - stream: transport error when executablePath is missing

    @Test("stream throws transport error when executablePath is nil")
    func streamThrowsWhenNoPath() async throws {
        let provider = CodexCLIProvider()
        var thrownError: Error?
        do {
            _ = try await provider.stream(
                systemPrompt: nil,
                input: "hi",
                model: "",
                options: ProviderOptions(executablePath: nil)
            )
        } catch {
            thrownError = error
        }
        guard let err = thrownError as? ProviderError,
              case let .transport(msg) = err else {
            Issue.record("Expected ProviderError.transport, got: \(String(describing: thrownError))")
            return
        }
        #expect(msg.contains("Codex CLI path not configured"))
    }

    @Test("stream throws transport error when executablePath is empty string")
    func streamThrowsWhenEmptyPath() async throws {
        let provider = CodexCLIProvider()
        var thrownError: Error?
        do {
            _ = try await provider.stream(
                systemPrompt: nil,
                input: "hi",
                model: "",
                options: ProviderOptions(executablePath: "")
            )
        } catch {
            thrownError = error
        }
        guard let err = thrownError as? ProviderError,
              case .transport = err else {
            Issue.record("Expected ProviderError.transport, got: \(String(describing: thrownError))")
            return
        }
    }
}
