using System.Globalization;
using System.Runtime.CompilerServices;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Actions;

// A port of ActionEngine.swift (spec-2 §1.1, §2.1-2.5, §2.8).
// UNTRUSTED DATA: the selected text and the streamed output are plain text; the engine never interprets them.

/// <summary>What the engine runs (macOS <c>Action</c>). The built-in Prompt action and custom AI actions are <see cref="Custom"/>.</summary>
public abstract record EngineAction
{
    private EngineAction() { }

    /// <summary>A non-blank custom prompt replaces the built-in one; the tone is appended.</summary>
    public sealed record Improve(string? CustomPrompt = null, TranslateTone Tone = TranslateTone.Neutral) : EngineAction;

    /// <summary>Same custom-prompt and tone rules as <see cref="Improve"/>.</summary>
    public sealed record Shorten(string? CustomPrompt = null, TranslateTone Tone = TranslateTone.Neutral) : EngineAction;

    /// <summary>A non-blank custom prompt replaces the built-in one; no tone (the author's tone is kept).</summary>
    public sealed record Proofread(string? CustomPrompt = null) : EngineAction;

    /// <summary>The custom prompt is added to the built-in translate prompt as subordinate guidance.</summary>
    public sealed record Translate(
        string TargetLanguage, string? CustomPrompt = null, TranslateTone Tone = TranslateTone.Neutral) : EngineAction;

    /// <summary>The prompt is the system prompt as-is (not trimmed).</summary>
    public sealed record Custom(string Prompt) : EngineAction;
}

/// <summary>A refine request: revise <paramref name="PreviousResult"/> per <paramref name="Instruction"/>. Never token-expanded.</summary>
public sealed record FollowUp(string PreviousResult, string Instruction);

/// <summary>One run of an action: the provider and model it maps to, and the settings snapshot taken at dispatch.</summary>
public sealed record ActionRequest(EngineAction Action, string Input, ProviderKind ProviderKind, string Model)
{
    /// <summary>The unparsed base URL from <see cref="ProviderFactory.ResolveBaseUrl"/>; required for GLM, OpenRouter, Custom.</summary>
    public string? BaseUrl { get; init; }

    /// <summary>The CLI binary path for the CLI providers (Phase 11); null otherwise.</summary>
    public string? ExecutablePath { get; init; }

    /// <summary>The "Preserve & render formatting" setting.</summary>
    public bool PreserveFormatting { get; init; }

    /// <summary>The user's global prompt; context tokens expand, <c>{{text}}</c> stays literal. Blank: none.</summary>
    public string GlobalPrompt { get; init; } = "";

    /// <summary>Values of the <c>{{app}}</c>, <c>{{domain}}</c>, <c>{{date}}</c> and <c>{{language}}</c> tokens.</summary>
    public PromptContext Context { get; init; } = PromptContext.Empty;

    /// <summary>Turns the run into a refine of a previous result.</summary>
    public FollowUp? FollowUp { get; init; }
}

/// <summary>
/// Builds the prompt of an action and streams it through the configured provider. There is no automatic retry
/// (spec-2 §2.8) and no fallback to another provider: a retry is a new <see cref="StreamAsync"/> call (each
/// enumeration builds a fresh provider and request).
/// </summary>
/// <param name="apiKey">The stored key of a provider kind, or null; a missing key is sent as "" (the provider's 401 surfaces).</param>
public sealed class ActionEngine(ProviderFactory factory, Func<ProviderKind, string?> apiKey)
{
    /// <summary>The system-role directive of a follow-up run; the instruction follows on its own "Instruction:" line.</summary>
    public const string RefineDirective =
        "You previously produced a result for the text below. Revise that previous result according to the user's " +
        "instruction. Return only the revised result, with no preamble or explanation.";

    // Multi-line prompts use explicit "\n": a raw literal would take the checkout's line endings (CRLF on Windows CI).
    private const string ImproveSystemPrompt =
        "Revise the provided content to improve its overall writing quality.\n\n" +
        "If no issues are found, respond concisely to let the user know nothing needed to be changed.\n\n" +
        "Additional guidelines:\n\n" +
        "- Do NOT add new information or alter the meaning of the original content.\n" +
        "- Improve clarity, conciseness, and flow without changing the author's intent.\n" +
        "- Reorder or split sentences when it improves readability.\n" +
        "- Reduce repetition and remove filler or redundant phrases.\n" +
        "- Replace convoluted wording with simpler alternatives and avoid jargon unless the surrounding context requires it.\n" +
        "- Correct spelling, grammar, and punctuation.\n" +
        "- Preserve all existing formatting, links, code snippets, and inline structures exactly as they appear.\n\n" +
        "Return only the corrected text — no commentary, no preamble.";

    private const string ShortenSystemPrompt =
        "You are a writing assistant. Shorten the following text: make it more concise and simpler without losing any " +
        "of the main ideas, and preserve the original meaning. Return only the shortened text — no commentary, no preamble.";

    // No final period, as on macOS.
    private const string ProofreadSystemPrompt =
        "Make any necessary edits to fix spelling, grammar, punctuation, and formatting mistakes ONLY to what the user has selected.\n\n" +
        "If no issues are found, respond concisely to let the user know nothing needed to be changed.\n\n" +
        "Guidelines:\n\n" +
        "- Correct typos, grammatical errors, and punctuation issues.\n" +
        "- Reword sentences only when required to achieve grammatical correctness or to accurately convey the intended meaning.\n" +
        "- Maintain the author's tone and level of formality.\n" +
        "- Minimize changes to formatting or wording that are not required for correctness.\n" +
        "- Do NOT worry about replacing quotes with smart quotes, or other typographic nits.\n\n" +
        "Return only the corrected text — no commentary, no preamble";

    private const string PreserveFormattingInstruction =
        "Preserve the Markdown formatting of the input in your output (keep bold, italic, strikethrough, inline code, and lists).";

    /// <summary>
    /// Streams the token deltas of <paramref name="request"/>. Every failure, including the endpoint guard and an
    /// unavailable provider, is a <see cref="ProviderError"/> thrown on the first <c>MoveNextAsync</c>, like the
    /// adapters' own errors, so callers wrap only the enumeration.
    /// <para>The engine never branches on the provider for prompts: translation providers (DeepL, Google) read
    /// <see cref="ProviderOptions.TargetLanguage"/> and ignore the system prompt. macOS parity, kept on purpose: when a
    /// translate custom prompt contains <c>{{text}}</c>, the substituted prompt becomes the input, so DeepL and Google
    /// translate that prompt text rather than the bare selection.</para>
    /// </summary>
    public async IAsyncEnumerable<string> StreamAsync(
        ActionRequest request, [EnumeratorCancellation] CancellationToken ct = default)
    {
        var baseUrl = ParseBaseUrl(request.ProviderKind, request.BaseUrl);
        var provider = CreateProvider(request.ProviderKind);
        var (rawSystemPrompt, options) = BuildPromptAndOptions(request.Action, baseUrl, request.ExecutablePath);

        // {{text}} in the prompt makes the expanded prompt the user message and drops the system role: it is a
        // complete user request, and the untrusted selection stays in the lower-authority role.
        var (expanded, consumedText) = PromptTemplate.Expand(rawSystemPrompt, request.Input, request.Context);
        string? systemPrompt = consumedText ? null : expanded;
        var input = consumedText ? expanded : request.Input;

        // After expansion, so the instruction and the previous result are never expanded.
        if (request.FollowUp is { } followUp)
            (systemPrompt, input) = ApplyFollowUp(systemPrompt, input, followUp);

        // The global prompt goes first, as overarching context; it becomes the system prompt when {{text}} consumed it.
        var global = PromptTemplate.Expand(request.GlobalPrompt, text: null, request.Context).Output.Trim();
        if (global.Length > 0)
            systemPrompt = systemPrompt is null ? global : global + "\n\n" + systemPrompt;

        if (request.PreserveFormatting)
        {
            if (systemPrompt is null)
                input += "\n\n" + PreserveFormattingInstruction;
            else
                systemPrompt += "\n\n" + PreserveFormattingInstruction;
        }

        await foreach (var token in provider.StreamAsync(systemPrompt, input, request.Model, options, ct))
            yield return token;
    }

    /// <summary>
    /// Composes a refine request: the refine directive and the instruction follow any existing system prompt; the input
    /// becomes labelled "Original text" and "Previous result" sections. Pure: nothing is token-expanded.
    /// </summary>
    public static (string SystemPrompt, string Input) ApplyFollowUp(string? systemPrompt, string input, FollowUp followUp)
    {
        var directive = RefineDirective + "\n\nInstruction: " + followUp.Instruction;
        var system = string.IsNullOrEmpty(systemPrompt) ? directive : systemPrompt + "\n\n" + directive;
        return (system, "Original text:\n" + input + "\n\nPrevious result:\n" + followUp.PreviousResult);
    }

    // Opening/closing double-quote pairs a model may wrap its whole reply in: "", “” and „“.
    private static readonly (string Open, string Close)[] WrappingQuotePairs =
        [("\"", "\""), ("“", "”"), ("„", "“")];

    /// <summary>
    /// Removes one pair of double quotes wrapping the whole output (spec-2 §2.5), run on the finished text. Kept when
    /// the selection itself was wrapped in quotes (the model echoes them) or when the quote characters also appear
    /// inside (<c>"a" and "b"</c>). Surrounding whitespace is trimmed only when a pair is stripped.
    /// </summary>
    public static string StripWrappingQuotes(string output, string input)
    {
        var trimmed = TextElements(output.Trim());
        if (WrappingQuotePair(trimmed) is not { } pair || WrappingQuotePair(TextElements(input.Trim())) is not null)
            return output;
        var inner = trimmed[1..^1];
        return inner.Contains(pair.Open) || inner.Contains(pair.Close) ? output : string.Concat(inner);
    }

    // Swift compares Characters (grapheme clusters): a quote followed by a combining mark is not a quote.
    private static string[] TextElements(string text)
    {
        var elements = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
            elements.Add(enumerator.GetTextElement());
        return [.. elements];
    }

    private static (string Open, string Close)? WrappingQuotePair(string[] text)
    {
        if (text.Length < 2)
            return null;
        foreach (var pair in WrappingQuotePairs)
        {
            if (pair.Open == text[0] && pair.Close == text[^1])
                return pair;
        }
        return null;
    }

    // GLM, OpenRouter and Custom speak the OpenAI wire format: without their own endpoint the adapter would fall back
    // to api.openai.com and send the key there. Other kinds: an unparseable URL means the adapter's default endpoint.
    // Unlike macOS (which parses the untrimmed string after a trimmed guard), the trimmed string is parsed, and only an
    // absolute http(s) URL counts as valid.
    private static Uri? ParseBaseUrl(ProviderKind kind, string? baseUrl)
    {
        var trimmed = PromptTemplate.TrimSpaces(baseUrl ?? "");
        var url = trimmed.Length > 0
            && Uri.TryCreate(trimmed, UriKind.Absolute, out var parsed)
            && (parsed.Scheme == Uri.UriSchemeHttp || parsed.Scheme == Uri.UriSchemeHttps)
                ? parsed
                : null;
        if (kind is ProviderKind.Glm or ProviderKind.OpenRouter or ProviderKind.Custom && url is null)
        {
            throw ProviderError.Transport(trimmed.Length == 0
                ? $"No endpoint configured for {DisplayName(kind)}. Set the base URL in Settings."
                : $"Invalid endpoint URL for {DisplayName(kind)}: \"{trimmed}\". Check the base URL in Settings.");
        }
        return url;
    }

    // Settings imported from macOS may select a kind whose adapter is not registered yet (the CLI kinds before
    // Phase 11, the local model before Phase 21).
    private IProvider CreateProvider(ProviderKind kind)
    {
        var key = apiKey(kind) ?? "";
        try
        {
            return factory.Create(kind, key);
        }
        catch (InvalidOperationException)
        {
            throw ProviderError.Transport(
                $"{DisplayName(kind)} is not available in PopGuy for Windows yet. Choose another provider in Settings.");
        }
    }

    private static (string SystemPrompt, ProviderOptions Options) BuildPromptAndOptions(
        EngineAction action, Uri? baseUrl, string? executablePath)
    {
        var options = new ProviderOptions { BaseUrl = baseUrl, ExecutablePath = executablePath };
        switch (action)
        {
            case EngineAction.Improve improve:
                return (AppendingTone(CustomOr(improve.CustomPrompt, ImproveSystemPrompt), improve.Tone), options);
            case EngineAction.Shorten shorten:
                return (AppendingTone(CustomOr(shorten.CustomPrompt, ShortenSystemPrompt), shorten.Tone), options);
            case EngineAction.Proofread proofread:
                return (CustomOr(proofread.CustomPrompt, ProofreadSystemPrompt), options);
            case EngineAction.Translate translate:
                // The custom prompt is framed as subordinate and placed first, so the language and tone carry more
                // weight for AI providers. DeepL reads the tone only through formality; Google ignores it.
                var custom = translate.CustomPrompt?.Trim() ?? "";
                var parts = new List<string>();
                if (custom.Length > 0)
                    parts.Add($"Apply these additional instructions where they do not conflict with the translation task: {custom}");
                parts.Add($"Translate the following text to {translate.TargetLanguage}.");
                if (PromptFragment(translate.Tone, translate.TargetLanguage) is { } fragment)
                    parts.Add(fragment);
                parts.Add("Return only the translated text — no commentary, no preamble.");
                return (string.Join(' ', parts), options with
                {
                    TargetLanguage = translate.TargetLanguage,
                    Formality = DeepLFormality(translate.Tone),
                });
            case EngineAction.Custom customAction:
                return (customAction.Prompt, options);
            default:
                throw new ArgumentOutOfRangeException(nameof(action));
        }
    }

    // Improve, Shorten and Proofread trim spaces and tabs only (not newlines) before the blank check.
    private static string CustomOr(string? customPrompt, string builtIn)
    {
        var trimmed = PromptTemplate.TrimSpaces(customPrompt ?? "");
        return trimmed.Length == 0 ? builtIn : trimmed;
    }

    // Improve and Shorten have no target language, so the French suffix never fires there.
    private static string AppendingTone(string prompt, TranslateTone tone) =>
        PromptFragment(tone, targetLanguage: null) is { } fragment ? prompt + "\n\n" + fragment : prompt;

    // TranslateTone.promptFragment and deepLFormality (ActionConfig.swift).
    private static string? PromptFragment(TranslateTone tone, string? targetLanguage)
    {
        switch (tone)
        {
            case TranslateTone.Formal:
                return "Use a formal tone.";
            case TranslateTone.Casual:
                return "Use a casual, conversational tone.";
            case TranslateTone.Professional:
                return "Use a professional tone.";
            case TranslateTone.Friendly:
                var fragment = "Use a friendly, warm, conversational tone.";
                var language = targetLanguage?.ToLowerInvariant();
                if (language is not null && (language == "fr" || language.StartsWith("fr-", StringComparison.Ordinal)))
                    fragment += " When writing in French, address the reader informally using \"tu\"/\"toi\" rather than \"vous\".";
                return fragment;
            default:
                return null;
        }
    }

    // prefer_* (not more/less) so DeepL ignores them for languages without formality support instead of failing.
    private static string? DeepLFormality(TranslateTone tone) => tone switch
    {
        TranslateTone.Formal or TranslateTone.Professional => "prefer_more",
        TranslateTone.Casual or TranslateTone.Friendly => "prefer_less",
        _ => null,
    };

    // ProviderKind.displayName (ProviderTypes.swift).
    internal static string DisplayName(ProviderKind kind) => kind switch
    {
        ProviderKind.OpenAi => "OpenAI",
        ProviderKind.Anthropic => "Anthropic (Claude)",
        ProviderKind.Ollama => "Ollama / LM Studio",
        ProviderKind.DeepL => "DeepL",
        ProviderKind.GoogleTranslate => "Google Translate",
        ProviderKind.Gemini => "Google Gemini",
        ProviderKind.Glm => "GLM / z.ai",
        ProviderKind.OpenRouter => "OpenRouter",
        ProviderKind.Custom => "Custom (OpenAI-compatible)",
        ProviderKind.ClaudeCli => "Claude CLI (subscription)",
        ProviderKind.CodexCli => "Codex CLI (subscription)",
        ProviderKind.GeminiCli => "Gemini CLI (subscription)",
        ProviderKind.MlxLocal => "Local (MLX)",
        _ => kind.ToString(),
    };
}
