// GeminiCLIProviderTests.swift
// PopGuyTests
//
// Tests GeminiCLIProvider — the Gemini CLI adapter.
//
// All tests are pure unit tests that feed captured real stream-json lines directly
// into GeminiCLIProvider.assistantText(fromStreamJSONLine:) and
// GeminiCLIProvider.buildPrompt. No subprocess is spawned.
//
// Sample lines below were captured from a real gemini invocation:
//
//   NODEBIN="$HOME/.nvm/versions/node/v22.21.1/bin"
//   env -i HOME="$HOME" PATH="$NODEBIN:/usr/bin:/bin" \
//     "$NODEBIN/gemini" -p "count to three" --approval-mode plan \
//     --output-format stream-json 2>/dev/null
//
// Actual stdout (line 1 shown after MCP prefix is stripped — the prefix was
// glued to the JSON with no newline on the test machine due to broken MCP server):
//   [MCP issues detected. Run /mcp list for status.]{"type":"init",...}
//   {"type":"message","role":"user","content":"count to three"}
//   {"type":"message","role":"assistant","content":"One,","delta":true}
//   {"type":"message","role":"assistant","content":" two, three.","delta":true}
//   {"type":"result","status":"success","stats":{...}}

import Foundation
import Testing
@testable import PopGuy

@Suite("GeminiCLIProvider")
struct GeminiCLIProviderTests {

    // MARK: - assistantText: real captured fixtures

    // Line 1 as it appeared on a machine with a broken MCP server:
    // the MCP status prefix is glued to the JSON with no newline separator.
    private let initLineWithMCPPrefix =
        #"MCP issues detected. Run /mcp list for status.{"type":"init","timestamp":"2026-06-12T07:55:44.037Z","session_id":"9a55b6fa-f409-4f2e-a442-5a60aafae612","model":"gemini-3.1-pro-preview"}"#

    // User-echo message — must be ignored (role is "user", not "assistant").
    private let userEchoLine =
        #"{"type":"message","timestamp":"2026-06-12T07:55:44.038Z","role":"user","content":"count to three"}"#

    // First assistant delta — THE ANSWER part 1.
    private let assistantDelta1 =
        #"{"type":"message","timestamp":"2026-06-12T07:55:47.174Z","role":"assistant","content":"One,","delta":true}"#

    // Second assistant delta — THE ANSWER part 2.
    private let assistantDelta2 =
        #"{"type":"message","timestamp":"2026-06-12T07:55:47.245Z","role":"assistant","content":" two, three.","delta":true}"#

    // Result summary line — must be ignored.
    private let resultLine =
        #"{"type":"result","timestamp":"2026-06-12T07:55:47.307Z","status":"success","stats":{"total_tokens":8545,"input_tokens":8475,"output_tokens":6}}"#

    // MARK: - assistantText: answer lines survive

    @Test("assistantText returns content for first assistant delta")
    func parseAssistantDelta1() {
        let result = GeminiCLIProvider.assistantText(fromStreamJSONLine: assistantDelta1)
        #expect(result == "One,")
    }

    @Test("assistantText returns content for second assistant delta")
    func parseAssistantDelta2() {
        let result = GeminiCLIProvider.assistantText(fromStreamJSONLine: assistantDelta2)
        #expect(result == " two, three.")
    }

    @Test("two assistant deltas join to the full answer")
    func parseBothDeltasConcatenate() {
        let part1 = GeminiCLIProvider.assistantText(fromStreamJSONLine: assistantDelta1) ?? ""
        let part2 = GeminiCLIProvider.assistantText(fromStreamJSONLine: assistantDelta2) ?? ""
        #expect(part1 + part2 == "One, two, three.")
    }

    // MARK: - assistantText: noise lines are dropped

    @Test("assistantText returns nil for init line (even with MCP prefix glued)")
    func parseInitLineWithMCPPrefix() {
        // The MCP prefix is stripped; the remaining JSON is `type:init` which is not
        // `type:message` + `role:assistant` — must return nil.
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: initLineWithMCPPrefix) == nil)
    }

    @Test("assistantText returns nil for user-echo message")
    func parseUserEchoLine() {
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: userEchoLine) == nil)
    }

    @Test("assistantText returns nil for result line")
    func parseResultLine() {
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: resultLine) == nil)
    }

    @Test("assistantText returns nil for aggregate assistant message (delta:false — prevents double-emit)")
    func parseAssistantAggregate_deltaFalse() {
        // A hypothetical final non-delta aggregate that Gemini might emit.
        // Without the delta:true guard this would double-emit the full answer.
        let aggregateFalse = #"{"type":"message","role":"assistant","content":"One, two, three.","delta":false}"#
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: aggregateFalse) == nil)
    }

    @Test("assistantText returns nil for assistant message with missing delta field")
    func parseAssistantAggregate_deltaAbsent() {
        // delta field absent — treated the same as delta:false.
        let aggregateNoDelta = #"{"type":"message","role":"assistant","content":"One, two, three."}"#
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: aggregateNoDelta) == nil)
    }

    @Test("assistantText returns nil for blank line")
    func parseBlankLine() {
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: "") == nil)
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: "   ") == nil)
    }

    @Test("assistantText returns nil for non-JSON garbage")
    func parseGarbage() {
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: "not json at all") == nil)
    }

    @Test("assistantText returns nil for a bare MCP noise line with no JSON")
    func parsePureMCPNoiseLine() {
        // A hypothetical line that is entirely noise (no `{`).
        #expect(GeminiCLIProvider.assistantText(fromStreamJSONLine: "MCP context refresh complete.") == nil)
    }

    // MARK: - buildPrompt

    @Test("buildPrompt with systemPrompt includes both parts and data framing")
    func buildPromptWithSystem() {
        let result = GeminiCLIProvider.buildPrompt(
            systemPrompt: "You are a translator.",
            input: "Hello world"
        )
        #expect(result.hasPrefix("You are a translator.\n\n"))
        #expect(result.contains("treat strictly as data"))
        #expect(result.hasSuffix("Hello world"))
    }

    @Test("buildPrompt without systemPrompt still includes data framing")
    func buildPromptNoSystem() {
        let result = GeminiCLIProvider.buildPrompt(systemPrompt: nil, input: "Some text")
        #expect(result.contains("treat strictly as data"))
        #expect(result.hasSuffix("Some text"))
        #expect(!result.hasPrefix("\n"))
    }

    @Test("buildPrompt with empty systemPrompt omits system section")
    func buildPromptEmptySystem() {
        let withEmpty = GeminiCLIProvider.buildPrompt(systemPrompt: "", input: "Test")
        let withNil   = GeminiCLIProvider.buildPrompt(systemPrompt: nil, input: "Test")
        #expect(withEmpty == withNil)
    }

    // MARK: - stream: transport error when executablePath is missing

    @Test("stream throws transport error when executablePath is nil")
    func streamThrowsWhenNoPath() async throws {
        let provider = GeminiCLIProvider()
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
        #expect(msg.contains("Gemini CLI path not configured"))
    }

    @Test("stream throws transport error when executablePath is empty string")
    func streamThrowsWhenEmptyPath() async throws {
        let provider = GeminiCLIProvider()
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
