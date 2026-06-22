// ClaudeCLIProviderTests.swift
// PopGuyTests
//
// Tests ClaudeCLIProvider — the Claude CLI adapter.
//
// All tests are pure unit tests that feed captured real JSONL lines directly into
// ClaudeCLIProvider.parseLine. No subprocess is spawned.
//
// Sample lines were captured from a real invocation (CLI version 2.1.175):
//
//   env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin \
//     ~/.local/bin/claude -p "count to three" \
//     --output-format stream-json --include-partial-messages --verbose 2>/dev/null
//
// Relevant captured lines (condensed; session_id/uuid fields omitted for clarity):
//
//   {"type":"system","subtype":"hook_started",...}
//   {"type":"system","subtype":"init",...}
//   {"type":"system","subtype":"status","status":"requesting",...}
//   {"type":"stream_event","event":{"type":"message_start","message":{...}}}
//   {"type":"stream_event","event":{"type":"content_block_start","index":0,...}}
//   {"type":"stream_event","event":{"type":"content_block_delta","index":0,
//       "delta":{"type":"text_delta","text":"Một"}}}
//   {"type":"stream_event","event":{"type":"content_block_delta","index":0,
//       "delta":{"type":"text_delta","text":", hai, ba."}}}
//   {"type":"assistant","message":{"content":[{"type":"text","text":"Một, hai, ba."}],...}}
//   {"type":"stream_event","event":{"type":"content_block_stop","index":0}}
//   {"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn",...}}}
//   {"type":"stream_event","event":{"type":"message_stop"}}
//   {"type":"rate_limit_event","rate_limit_info":{...}}
//   {"type":"result","subtype":"success","is_error":false,...,"result":"Một, hai, ba.",...}
//
// Auth-failure path (fresh CLAUDE_CONFIG_DIR → "Not logged in"):
//   {"type":"assistant","message":{"content":[{"type":"text","text":"Not logged in…"}],
//       ...},"error":"authentication_failed"}
//   {"type":"result","subtype":"success","is_error":true,...,"result":"Not logged in…",...}

import Foundation
import Testing
@testable import PopGuy

@Suite("ClaudeCLIProvider")
struct ClaudeCLIProviderTests {

    // MARK: - Captured fixture lines

    // system:hook_started — must be ignored
    private let hookStartedLine = #"{"type":"system","subtype":"hook_started","hook_id":"abc","hook_name":"SessionStart:startup","hook_event":"SessionStart","uuid":"u1","session_id":"s1"}"#

    // system:init — must be ignored
    private let initLine = #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s1","tools":[],"model":"claude-opus-4-8","uuid":"u2"}"#

    // system:status — must be ignored
    private let statusLine = #"{"type":"system","subtype":"status","status":"requesting","uuid":"u3","session_id":"s1"}"#

    // stream_event:message_start — must be ignored
    private let messageStartLine = #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-opus-4-8","id":"msg_01","type":"message","role":"assistant","content":[],"stop_reason":null}},"session_id":"s1","uuid":"u4"}"#

    // stream_event:content_block_start — must be ignored
    private let contentBlockStartLine = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"s1","uuid":"u5"}"#

    // stream_event:content_block_delta text_delta — THE ANSWER (first chunk)
    private let textDeltaLine1 = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Một"}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u6"}"#

    // stream_event:content_block_delta text_delta — THE ANSWER (second chunk)
    private let textDeltaLine2 = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", hai, ba."}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u7"}"#

    // type:assistant aggregate — must be ignored (would double-emit)
    private let assistantAggregateLine = #"{"type":"assistant","message":{"model":"claude-opus-4-8","id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"Một, hai, ba."}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s1","uuid":"u8"}"#

    // stream_event:content_block_stop — must be ignored
    private let contentBlockStopLine = #"{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"s1","uuid":"u9"}"#

    // stream_event:message_delta — must be ignored
    private let messageDeltaLine = #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}},"session_id":"s1","uuid":"ua"}"#

    // stream_event:message_stop — must be ignored
    private let messageStopLine = #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s1","uuid":"ub"}"#

    // rate_limit_event — must be ignored
    private let rateLimitLine = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning"},"uuid":"uc","session_id":"s1"}"#

    // result:success, is_error:false — final summary
    private let resultSuccessLine = #"{"type":"result","subtype":"success","is_error":false,"result":"Một, hai, ba.","duration_ms":2039,"session_id":"s1","uuid":"ud"}"#

    // result:success, is_error:true — auth failure (subtype is misleadingly "success")
    private let resultAuthFailLine = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","duration_ms":38,"session_id":"s1","uuid":"ue"}"#

    // MARK: - parseLine: text delta lines

    @Test("parseLine returns .text for first text_delta chunk")
    func parseLineTextDelta1() {
        if case .text(let chunk) = ClaudeCLIProvider.parseLine(textDeltaLine1) {
            #expect(chunk == "Một")
        } else {
            Issue.record("Expected .text, got something else for textDeltaLine1")
        }
    }

    @Test("parseLine returns .text for second text_delta chunk")
    func parseLineTextDelta2() {
        if case .text(let chunk) = ClaudeCLIProvider.parseLine(textDeltaLine2) {
            #expect(chunk == ", hai, ba.")
        } else {
            Issue.record("Expected .text, got something else for textDeltaLine2")
        }
    }

    // MARK: - parseLine: result lines

    @Test("parseLine returns .result(isError:false) for success result")
    func parseLineResultSuccess() {
        if case .result(let text, let isError) = ClaudeCLIProvider.parseLine(resultSuccessLine) {
            #expect(text == "Một, hai, ba.")
            #expect(!isError)
        } else {
            Issue.record("Expected .result for resultSuccessLine")
        }
    }

    @Test("parseLine returns .result(isError:true) even when subtype is 'success'")
    func parseLineResultAuthFail() {
        // is_error gates the error, not subtype — empirically confirmed from real CLI output
        if case .result(let text, let isError) = ClaudeCLIProvider.parseLine(resultAuthFailLine) {
            #expect(isError)
            #expect(text.contains("Not logged in"))
        } else {
            Issue.record("Expected .result(isError:true) for resultAuthFailLine")
        }
    }

    // MARK: - parseLine: ignored lines

    @Test("parseLine returns .ignore for system:hook_started")
    func parseLineHookStarted() {
        if case .ignore = ClaudeCLIProvider.parseLine(hookStartedLine) { } else {
            Issue.record("Expected .ignore for hookStartedLine")
        }
    }

    @Test("parseLine returns .ignore for system:init")
    func parseLineInit() {
        if case .ignore = ClaudeCLIProvider.parseLine(initLine) { } else {
            Issue.record("Expected .ignore for initLine")
        }
    }

    @Test("parseLine returns .ignore for system:status")
    func parseLineStatus() {
        if case .ignore = ClaudeCLIProvider.parseLine(statusLine) { } else {
            Issue.record("Expected .ignore for statusLine")
        }
    }

    @Test("parseLine returns .ignore for stream_event:message_start")
    func parseLineMessageStart() {
        if case .ignore = ClaudeCLIProvider.parseLine(messageStartLine) { } else {
            Issue.record("Expected .ignore for messageStartLine")
        }
    }

    @Test("parseLine returns .ignore for stream_event:content_block_start")
    func parseLineContentBlockStart() {
        if case .ignore = ClaudeCLIProvider.parseLine(contentBlockStartLine) { } else {
            Issue.record("Expected .ignore for contentBlockStartLine")
        }
    }

    @Test("parseLine returns .ignore for type:assistant aggregate (prevents double-emit)")
    func parseLineAssistantAggregate() {
        // This line carries the full text and MUST be ignored to avoid double-emit.
        if case .ignore = ClaudeCLIProvider.parseLine(assistantAggregateLine) { } else {
            Issue.record("Expected .ignore for assistantAggregateLine — double-emit risk!")
        }
    }

    @Test("parseLine returns .ignore for stream_event:content_block_stop")
    func parseLineContentBlockStop() {
        if case .ignore = ClaudeCLIProvider.parseLine(contentBlockStopLine) { } else {
            Issue.record("Expected .ignore for contentBlockStopLine")
        }
    }

    @Test("parseLine returns .ignore for stream_event:message_delta")
    func parseLineMessageDelta() {
        if case .ignore = ClaudeCLIProvider.parseLine(messageDeltaLine) { } else {
            Issue.record("Expected .ignore for messageDeltaLine")
        }
    }

    @Test("parseLine returns .ignore for stream_event:message_stop")
    func parseLineMessageStop() {
        if case .ignore = ClaudeCLIProvider.parseLine(messageStopLine) { } else {
            Issue.record("Expected .ignore for messageStopLine")
        }
    }

    @Test("parseLine returns .ignore for rate_limit_event")
    func parseLineRateLimit() {
        if case .ignore = ClaudeCLIProvider.parseLine(rateLimitLine) { } else {
            Issue.record("Expected .ignore for rateLimitLine")
        }
    }

    // MARK: - parseLine: edge cases

    @Test("parseLine returns .ignore for blank line")
    func parseLineBlank() {
        if case .ignore = ClaudeCLIProvider.parseLine("") { } else {
            Issue.record("Expected .ignore for empty string")
        }
        if case .ignore = ClaudeCLIProvider.parseLine("   ") { } else {
            Issue.record("Expected .ignore for whitespace-only string")
        }
    }

    @Test("parseLine returns .ignore for non-JSON garbage")
    func parseLineGarbage() {
        if case .ignore = ClaudeCLIProvider.parseLine("not json at all") { } else {
            Issue.record("Expected .ignore for non-JSON garbage")
        }
    }

    @Test("parseLine returns .ignore for stream_event with non-text_delta type")
    func parseLineNonTextDelta() {
        // e.g. thinking_delta — should be ignored
        let thinkingLine = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me think..."}},"session_id":"s1","uuid":"uf"}"#
        if case .ignore = ClaudeCLIProvider.parseLine(thinkingLine) { } else {
            Issue.record("Expected .ignore for thinking_delta")
        }
    }

    @Test("parseLine returns .ignore for empty text_delta")
    func parseLineEmptyTextDelta() {
        // Empty string deltas must be dropped (not yielded as zero-length chunks)
        let emptyDelta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}},"session_id":"s1","uuid":"ug"}"#
        if case .ignore = ClaudeCLIProvider.parseLine(emptyDelta) { } else {
            Issue.record("Expected .ignore for empty text_delta string")
        }
    }

    // MARK: - parseLines: streaming aggregator

    // Helper: build a synthetic AsyncThrowingStream from an array of lines.
    private func makeStream(lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    @Test("parseLines throws apiError when deltas arrive before is_error result (Critical 1 regression)")
    func parseLinesPartialThenError() async throws {
        let stream = makeStream(lines: [textDeltaLine1, resultAuthFailLine])
        let provider = ClaudeCLIProvider()
        let output = provider.parseLines(from: stream)

        var collected: [String] = []
        var thrownError: Error?
        do {
            for try await chunk in output {
                collected.append(chunk)
            }
        } catch {
            thrownError = error
        }

        // The delta should have been yielded before the error.
        #expect(collected == ["Một"])
        // The stream must throw, not finish cleanly.
        guard let err = thrownError as? ProviderError,
              case let .apiError(provider, msg) = err else {
            Issue.record("Expected ProviderError.apiError, got: \(String(describing: thrownError))")
            return
        }
        #expect(provider == "claude_cli")
        #expect(msg.contains("Not logged in"))
    }

    @Test("parseLines throws apiError when only an is_error result arrives (no deltas)")
    func parseLinesErrorOnly() async throws {
        let stream = makeStream(lines: [resultAuthFailLine])
        let provider = ClaudeCLIProvider()
        let output = provider.parseLines(from: stream)

        var thrownError: Error?
        do {
            for try await _ in output { }
        } catch {
            thrownError = error
        }

        guard let err = thrownError as? ProviderError,
              case let .apiError(p, msg) = err else {
            Issue.record("Expected ProviderError.apiError, got: \(String(describing: thrownError))")
            return
        }
        #expect(p == "claude_cli")
        #expect(msg.contains("Not logged in"))
    }

    @Test("parseLines yields deltas and finishes cleanly — result text is NOT double-emitted")
    func parseLinesNormalStream() async throws {
        let stream = makeStream(lines: [textDeltaLine1, textDeltaLine2, resultSuccessLine])
        let provider = ClaudeCLIProvider()
        let output = provider.parseLines(from: stream)

        var collected: [String] = []
        var thrownError: Error?
        do {
            for try await chunk in output {
                collected.append(chunk)
            }
        } catch {
            thrownError = error
        }

        // Exactly the two delta chunks — the result text must NOT be appended again.
        #expect(collected == ["Một", ", hai, ba."])
        #expect(thrownError == nil)
    }

    // MARK: - buildPrompt

    @Test("buildPrompt without systemPrompt wraps input in data framing only")
    func buildPromptNoSystem() {
        let result = ClaudeCLIProvider.buildPrompt(systemPrompt: nil, input: "Hello world")
        #expect(result.contains("treat strictly as data"))
        #expect(result.hasSuffix("Hello world"))
        #expect(!result.hasPrefix("\n"))
    }

    @Test("buildPrompt with systemPrompt includes both parts and data framing")
    func buildPromptWithSystem() {
        let result = ClaudeCLIProvider.buildPrompt(systemPrompt: "You are a translator.", input: "Hello")
        #expect(result.hasPrefix("You are a translator.\n\n"))
        #expect(result.contains("treat strictly as data"))
        #expect(result.hasSuffix("Hello"))
    }

    @Test("buildPrompt with empty systemPrompt behaves like nil")
    func buildPromptEmptySystem() {
        let withEmpty = ClaudeCLIProvider.buildPrompt(systemPrompt: "", input: "Test")
        let withNil   = ClaudeCLIProvider.buildPrompt(systemPrompt: nil, input: "Test")
        #expect(withEmpty == withNil)
    }

    // MARK: - stream: transport error when executablePath is missing

    @Test("stream throws transport error when executablePath is nil")
    func streamThrowsWhenNoPath() async throws {
        let provider = ClaudeCLIProvider()
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
        #expect(msg.contains("Claude CLI path not configured"))
    }

    @Test("stream throws transport error when executablePath is empty string")
    func streamThrowsWhenEmptyPath() async throws {
        let provider = ClaudeCLIProvider()
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
