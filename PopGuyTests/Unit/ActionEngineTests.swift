// ActionEngineTests.swift
// PopGuyTests
//
// TDD: ActionEngine dispatch tests using a MockProvider.
// Verifies that:
//   (a) Improve routes to the configured provider with the improve system prompt.
//   (b) Translate routes with targetLanguage in ProviderOptions.
//   (c) Streamed deltas are forwarded correctly.
//
// No real network calls are made — MockProvider records the calls it receives.

import Foundation
import Testing
@testable import PopGuy

// MARK: - MockProvider

/// Records the last call to stream() so tests can assert routing and options.
final class MockProvider: Provider, @unchecked Sendable {
    // @unchecked Sendable: MockProvider is used from test code only, never crosses
    // a real actor boundary; the mutable captured state is only read after
    // async completion within one test.

    private(set) var capturedSystemPrompt: String?
    private(set) var capturedInput: String = ""
    private(set) var capturedModel: String = ""
    private(set) var capturedOptions: ProviderOptions = ProviderOptions()

    /// Tokens this mock will emit when stream() is called.
    var tokensToEmit: [String] = []

    nonisolated func stream(
        systemPrompt: String?,
        input: String,
        model: String,
        options: ProviderOptions
    ) async throws -> AsyncThrowingStream<String, Error> {
        capturedSystemPrompt = systemPrompt
        capturedInput        = input
        capturedModel        = model
        capturedOptions      = options

        let tokens = tokensToEmit
        return AsyncThrowingStream { continuation in
            for token in tokens { continuation.yield(token) }
            continuation.finish()
        }
    }
}

// MARK: - ActionEngineTests

@Suite("ActionEngine")
struct ActionEngineTests {

    // MARK: - Helpers

    /// Build an ActionEngine whose factory always returns the same mock provider.
    private func makeEngine(mock: MockProvider) -> ActionEngine {
        ActionEngine { _, _ in mock }
    }

    private let improveConfig   = ActionConfig(id: .improve,   providerKind: .anthropic, model: "claude-sonnet-4-6")
    private let translateConfig = ActionConfig(id: .translate, providerKind: .deepL,     model: "default")

    // MARK: - Improve routing

    @Test("Improve routes to the configured provider")
    func improveRoutesToProvider() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "Hello world",
            config: improveConfig,
            apiKey: "sk-test"
        )
        // dispatch() returned a stream — the factory was called with the right kind.
        // We verify by confirming mock received the call.
        #expect(mock.capturedInput == "Hello world")
        #expect(mock.capturedModel == "claude-sonnet-4-6")
    }

    @Test("Improve passes a non-nil system prompt")
    func improveHasSystemPrompt() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "Some text",
            config: improveConfig,
            apiKey: "sk-test"
        )
        #expect(mock.capturedSystemPrompt != nil)
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt.contains("Improve") || prompt.contains("improve") || prompt.contains("writing"))
    }

    @Test("Improve does not set targetLanguage in options")
    func improveNoTargetLanguage() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "Some text",
            config: improveConfig,
            apiKey: "sk-test"
        )
        #expect(mock.capturedOptions.targetLanguage == nil)
    }

    // MARK: - Translate routing

    @Test("Translate sets targetLanguage in ProviderOptions")
    func translateSetsTargetLanguage() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "fr", customPrompt: nil, tone: .neutral),
            input:  "Hello world",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        #expect(mock.capturedOptions.targetLanguage == "fr")
    }

    @Test("Translate passes a non-nil system prompt (for AI providers)")
    func translateHasSystemPrompt() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "vi", customPrompt: nil, tone: .neutral),
            input:  "Some text",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt.contains("vi") || prompt.contains("translate") || prompt.contains("Translate"))
    }

    @Test("Translate passes the input text unchanged")
    func translateForwardsInput() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "es", customPrompt: nil, tone: .neutral),
            input:  "Good morning",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        #expect(mock.capturedInput == "Good morning")
    }

    // MARK: - Tone

    @Test("Improve with friendly tone appends a tone fragment to the prompt")
    func improveFriendlyToneAppended() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .friendly),
            input:  "test",
            config: improveConfig,
            apiKey: "sk-test"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        // The fragment is appended after a blank-line separator, not fused to
        // the preceding text.
        #expect(prompt.contains("\n\nUse a friendly"))
    }

    @Test("Shorten with friendly tone appends a tone fragment without a contradicting preserve-tone clause")
    func shortenFriendlyToneAppended() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .shorten, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .shorten(customPrompt: nil, tone: .friendly),
            input:  "A long piece of text",
            config: config,
            apiKey: "sk-test"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt.contains("\n\nUse a friendly"))
        // The base prompt must not also instruct the model to preserve the
        // original tone — that would contradict the selected tone.
        #expect(!prompt.lowercased().contains("preserve the original meaning and tone"))
    }

    @Test("Translate to French with friendly tone requests informal tu/toi")
    func translateFrenchFriendlyUsesTu() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "fr", customPrompt: nil, tone: .friendly),
            input:  "Hello",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt.contains("\"tu\""))
        #expect(prompt.contains("vous"))
    }

    @Test("Translate to a regional French variant (fr-CA) with friendly tone still requests tu/toi")
    func translateRegionalFrenchFriendlyUsesTu() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "fr-CA", customPrompt: nil, tone: .friendly),
            input:  "Hello",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt.contains("\"tu\""))
        #expect(prompt.contains("vous"))
    }

    @Test("Translate to a non-French language with friendly tone omits the tu/toi instruction")
    func translateEnglishFriendlyOmitsTu() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "en", customPrompt: nil, tone: .friendly),
            input:  "Bonjour",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(!prompt.contains("vous"))
        #expect(!prompt.contains("toi"))
    }

    @Test("Translate friendly tone maps to DeepL formality prefer_less")
    func translateFriendlyMapsToFormality() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "fr", customPrompt: nil, tone: .friendly),
            input:  "Hello",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        #expect(mock.capturedOptions.formality == "prefer_less")
    }

    @Test("Translate formal tone maps to DeepL formality prefer_more")
    func translateFormalMapsToFormality() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "fr", customPrompt: nil, tone: .formal),
            input:  "Hello",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        #expect(mock.capturedOptions.formality == "prefer_more")
    }

    @Test("Translate professional tone maps to DeepL formality prefer_more")
    func translateProfessionalMapsToFormality() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "fr", customPrompt: nil, tone: .professional),
            input:  "Hello",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        #expect(mock.capturedOptions.formality == "prefer_more")
    }

    @Test("Translate casual tone maps to DeepL formality prefer_less")
    func translateCasualMapsToFormality() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "fr", customPrompt: nil, tone: .casual),
            input:  "Hello",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        #expect(mock.capturedOptions.formality == "prefer_less")
    }

    @Test("Translate neutral tone sends no DeepL formality")
    func translateNeutralOmitsFormality() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "fr", customPrompt: nil, tone: .neutral),
            input:  "Hello",
            config: translateConfig,
            apiKey: "key-deepl"
        )
        #expect(mock.capturedOptions.formality == nil)
    }

    // MARK: - Streamed deltas

    @Test("Streamed deltas from provider are forwarded")
    func streamedDeltasForwarded() async throws {
        let mock = MockProvider()
        mock.tokensToEmit = ["Hello", " ", "world"]
        let engine = makeEngine(mock: mock)

        let stream = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "test",
            config: improveConfig,
            apiKey: "sk-test"
        )

        var collected: [String] = []
        for try await token in stream { collected.append(token) }
        #expect(collected == ["Hello", " ", "world"])
    }

    @Test("Empty stream emits no tokens")
    func emptyStreamEmitsNothing() async throws {
        let mock = MockProvider()
        mock.tokensToEmit = []
        let engine = makeEngine(mock: mock)

        let stream = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "test",
            config: improveConfig,
            apiKey: "sk-test"
        )

        var collected: [String] = []
        for try await token in stream { collected.append(token) }
        #expect(collected.isEmpty)
    }

    // MARK: - Custom action (Phase 5 stub)

    @Test("Custom action uses the provided prompt as system prompt")
    func customActionUsesProvidedPrompt() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let customPrompt = "Summarize the following text in one sentence."
        let customConfig = ActionConfig(id: .improve, providerKind: .openAI, model: "gpt-4o")

        _ = try await engine.dispatch(
            action: .custom(prompt: customPrompt),
            input:  "Long text here...",
            config: customConfig,
            apiKey: "sk-test"
        )
        #expect(mock.capturedSystemPrompt == customPrompt)
    }

    // MARK: - {{text}} placeholder substitution

    @Test("{{text}} token: substituted string becomes user message, systemPrompt is nil")
    func textPlaceholderBecomesUserMessage() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let customPrompt = "Summarize this: {{text}}"
        let customConfig = ActionConfig(id: .improve, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .custom(prompt: customPrompt),
            input:  "Hello world",
            config: customConfig,
            apiKey: "sk-test"
        )
        // The substituted string must land in input (user turn), never empty.
        #expect(mock.capturedInput == "Summarize this: Hello world")
        // systemPrompt must be nil — the custom prompt was the full user request.
        #expect(mock.capturedSystemPrompt == nil)
    }

    @Test("{{text}} token: provider receives non-empty input (no HTTP 400 risk)")
    func textPlaceholderInputIsNeverEmpty() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let customConfig = ActionConfig(id: .improve, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .improve(customPrompt: "Fix grammar: {{text}}", tone: .neutral),
            input:  "He go to store.",
            config: customConfig,
            apiKey: "sk-test"
        )
        #expect(!mock.capturedInput.isEmpty, "Provider must never receive empty input when {{text}} is used")
        #expect(mock.capturedInput.contains("He go to store."))
    }

    @Test("No {{text}} token: prompt stays as systemPrompt, input is unchanged")
    func noTextPlaceholderIsIdentityTransform() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let plainPrompt = "Summarize in one sentence."
        let customConfig = ActionConfig(id: .improve, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .custom(prompt: plainPrompt),
            input:  "Original input text",
            config: customConfig,
            apiKey: "sk-test"
        )
        #expect(mock.capturedSystemPrompt == plainPrompt)
        #expect(mock.capturedInput == "Original input text")
    }

    // MARK: - CLI executable path injection

    @Test("claudeCLI executablePathOverride is forwarded into ProviderOptions.executablePath")
    func claudeCLIExecutablePathThreadedThroughOptions() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let cliConfig = ActionConfig(id: .improve, providerKind: .claudeCLI, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "Hello",
            config: cliConfig,
            apiKey: "",
            executablePathOverride: "/some/path/claude"
        )
        #expect(mock.capturedOptions.executablePath == "/some/path/claude")
    }

    // MARK: - makeDefaultFactory: CLI kind mapping

    @Test("makeDefaultFactory returns ClaudeCLIProvider for .claudeCLI")
    func makeDefaultFactoryClaudeCLI() {
        let factory = ActionEngine.makeDefaultFactory()
        let provider = factory(.claudeCLI, "")
        #expect(provider is ClaudeCLIProvider)
    }

    @Test("makeDefaultFactory returns CodexCLIProvider for .codexCLI")
    func makeDefaultFactoryCodexCLI() {
        let factory = ActionEngine.makeDefaultFactory()
        let provider = factory(.codexCLI, "")
        #expect(provider is CodexCLIProvider)
    }

    @Test("makeDefaultFactory returns GeminiCLIProvider for .geminiCLI")
    func makeDefaultFactoryGeminiCLI() {
        let factory = ActionEngine.makeDefaultFactory()
        let provider = factory(.geminiCLI, "")
        #expect(provider is GeminiCLIProvider)
    }

    // MARK: - Ollama base URL injection

    @Test("Ollama base URL is passed through ProviderOptions")
    func ollamaBaseURLPassedThroughOptions() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let ollamaConfig = ActionConfig(id: .improve, providerKind: .ollama, model: "llama3")

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "test",
            config: ollamaConfig,
            apiKey: "",
            baseURLOverride: "http://192.168.1.10:11434/v1"
        )
        #expect(mock.capturedOptions.baseURL?.host == "192.168.1.10")
    }

    // MARK: - Shorten routing

    @Test("Shorten passes a shortening system prompt")
    func shortenHasSystemPrompt() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .shorten, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .shorten(customPrompt: nil, tone: .neutral),
            input:  "A long piece of text",
            config: config,
            apiKey: "sk-test"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt.localizedCaseInsensitiveContains("shorten") || prompt.localizedCaseInsensitiveContains("concise"))
        #expect(mock.capturedInput == "A long piece of text")
    }

    @Test("Shorten does not set targetLanguage in options")
    func shortenNoTargetLanguage() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .shorten, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .shorten(customPrompt: nil, tone: .neutral),
            input:  "Some text",
            config: config,
            apiKey: "sk-test"
        )
        #expect(mock.capturedOptions.targetLanguage == nil)
    }

    @Test("Shorten custom prompt overrides the predefined prompt")
    func shortenCustomPromptOverrides() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .shorten, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .shorten(customPrompt: "Make this a one-liner.", tone: .neutral),
            input:  "Some text",
            config: config,
            apiKey: "sk-test"
        )
        #expect(mock.capturedSystemPrompt == "Make this a one-liner.")
    }

    // MARK: - Proofread routing

    @Test("Proofread passes a proofreading system prompt")
    func proofreadHasSystemPrompt() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .proofread, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .proofread(customPrompt: nil),
            input:  "He go to store.",
            config: config,
            apiKey: "sk-test"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt.localizedCaseInsensitiveContains("proofread") || prompt.localizedCaseInsensitiveContains("grammar"))
        #expect(mock.capturedInput == "He go to store.")
    }

    @Test("Proofread custom prompt overrides the predefined prompt")
    func proofreadCustomPromptOverrides() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let config = ActionConfig(id: .proofread, providerKind: .anthropic, model: "claude-sonnet-4-6")

        _ = try await engine.dispatch(
            action: .proofread(customPrompt: "Fix typos only: {{text}}"),
            input:  "He go to store.",
            config: config,
            apiKey: "sk-test"
        )
        // {{text}} prompt becomes the user message; systemPrompt is nil.
        #expect(mock.capturedSystemPrompt == nil)
        #expect(mock.capturedInput == "Fix typos only: He go to store.")
    }

    // MARK: - preserveFormatting

    // The production constants are private; hardcode the exact literals here once.
    private let preserveFormattingInstruction = "Preserve the Markdown formatting of the input in your output (keep bold, italic, strikethrough, inline code, and lists)."

    // Mirror of ActionEngine.improveSystemPrompt — kept in sync intentionally.
    // If the production prompt changes, update both.
    private let improveSystemPromptBase = """
        Revise the provided content to improve its overall writing quality.

        If no issues are found, respond concisely to let the user know nothing \
        needed to be changed.

        Additional guidelines:

        - Do NOT add new information or alter the meaning of the original \
        content.
        - Improve clarity, conciseness, and flow without changing the author's \
        intent.
        - Reorder or split sentences when it improves readability.
        - Reduce repetition and remove filler or redundant phrases.
        - Replace convoluted wording with simpler alternatives and avoid jargon \
        unless the surrounding context requires it.
        - Correct spelling, grammar, and punctuation.
        - Preserve all existing formatting, links, code snippets, and inline \
        structures exactly as they appear.

        Return only the corrected text — no commentary, no preamble.
        """

    @Test("preserveFormatting: system prompt receives the instruction when a system prompt exists")
    func preserveFormattingAppendsToSystemPrompt() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let input = "Some text"

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  input,
            config: improveConfig,
            apiKey: "sk-test",
            preserveFormatting: true
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        // Full equality: base improve prompt + blank-line separator + instruction.
        // tone: .neutral adds no fragment, so the base is the only prefix.
        #expect(prompt == improveSystemPromptBase + "\n\n" + preserveFormattingInstruction)
        #expect(prompt.hasSuffix("\n\n" + preserveFormattingInstruction))
        // Input must be passed through unchanged.
        #expect(mock.capturedInput == input)
    }

    @Test("preserveFormatting: input receives the instruction when {{text}} consumed the system role")
    func preserveFormattingAppendsToInputWhenSystemPromptIsNil() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .custom(prompt: "Summarize: {{text}}"),
            input:  "Some text",
            config: improveConfig,
            apiKey: "sk-test",
            preserveFormatting: true
        )
        // applyTextPlaceholder sets systemPrompt to nil when {{text}} is present.
        #expect(mock.capturedSystemPrompt == nil)
        // The substituted user text must lead the captured input.
        #expect(mock.capturedInput.hasPrefix("Summarize: Some text"))
        #expect(mock.capturedInput.hasSuffix("\n\n" + preserveFormattingInstruction))
    }

    @Test("preserveFormatting false: system prompt and input are not modified")
    func preserveFormattingFalseIsNoOp() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)
        let input = "Some text"

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  input,
            config: improveConfig,
            apiKey: "sk-test",
            preserveFormatting: false
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        // The instruction must not appear anywhere in the prompt or input.
        #expect(!prompt.contains(preserveFormattingInstruction))
        #expect(mock.capturedInput == input)
    }

    // MARK: - globalPrompt

    private let globalPromptText = "Always respond in a concise, professional tone."

    @Test("globalPrompt: prepended to the system prompt with a blank-line separator")
    func globalPromptPrependsToSystemPrompt() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "Some text",
            config: improveConfig,
            apiKey: "sk-test",
            globalPrompt: globalPromptText
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        // Full equality: global prompt + blank-line separator + base improve prompt.
        #expect(prompt == globalPromptText + "\n\n" + improveSystemPromptBase)
        #expect(prompt.hasPrefix(globalPromptText + "\n\n"))
    }

    @Test("globalPrompt: becomes the system prompt when {{text}} consumed the system role")
    func globalPromptBecomesSystemPromptWhenSystemPromptIsNil() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .custom(prompt: "Summarize: {{text}}"),
            input:  "Hello world",
            config: improveConfig,
            apiKey: "sk-test",
            globalPrompt: globalPromptText
        )
        // The global prompt fills the otherwise-nil system role...
        #expect(mock.capturedSystemPrompt == globalPromptText)
        // ...and the substituted user request is NOT polluted with the global prompt.
        #expect(mock.capturedInput == "Summarize: Hello world")
    }

    @Test("globalPrompt + preserveFormatting: global leads, preserve directive trails")
    func globalPromptAndPreserveFormattingOrdering() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "Some text",
            config: improveConfig,
            apiKey: "sk-test",
            preserveFormatting: true,
            globalPrompt: globalPromptText
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        // global (prepended) + base + preserve directive (appended).
        #expect(prompt == globalPromptText + "\n\n" + improveSystemPromptBase + "\n\n" + preserveFormattingInstruction)
        #expect(prompt.hasPrefix(globalPromptText + "\n\n"))
        #expect(prompt.hasSuffix("\n\n" + preserveFormattingInstruction))
    }

    @Test("globalPrompt: prepended before the Translate directives (target language stays after)")
    func globalPromptPrependedForTranslate() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .translate(targetLanguage: "French", customPrompt: nil, tone: .neutral),
            input:  "Hello",
            config: translateConfig,
            apiKey: "key-deepl",
            globalPrompt: globalPromptText
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt.hasPrefix(globalPromptText + "\n\n"))
        // The authoritative translate directive must still follow the global prompt,
        // so the configured target language keeps its higher-weight trailing position.
        let globalRange = try #require(prompt.range(of: globalPromptText))
        let translateRange = try #require(prompt.range(of: "Translate the following text to French."))
        #expect(globalRange.lowerBound < translateRange.lowerBound)
    }

    @Test("globalPrompt: whitespace-only value is a no-op")
    func globalPromptWhitespaceOnlyIsNoOp() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "Some text",
            config: improveConfig,
            apiKey: "sk-test",
            globalPrompt: "   \n  \t "
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt == improveSystemPromptBase)
    }

    @Test("globalPrompt: empty default does not modify the system prompt")
    func globalPromptEmptyDefaultIsNoOp() async throws {
        let mock = MockProvider()
        let engine = makeEngine(mock: mock)

        _ = try await engine.dispatch(
            action: .improve(customPrompt: nil, tone: .neutral),
            input:  "Some text",
            config: improveConfig,
            apiKey: "sk-test"
        )
        let prompt = try #require(mock.capturedSystemPrompt)
        #expect(prompt == improveSystemPromptBase)
    }
}
