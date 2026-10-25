using System.Runtime.CompilerServices;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;

namespace PopGuy.Tests.Core;

// Contract: what ActionEngine sends to a provider (spec-2 §2.1-2.4, ActionEngine.swift, PromptContext.swift): the
// verbatim built-in prompts, tones, the global prompt, the preserve-formatting directive, {{text}} consumption and the
// follow-up; the wrapping-quote strip (§2.5); the endpoint guard that keeps a key from reaching api.openai.com.
// Security: prompt tokens are expanded in one pass, so selected text or a context value containing a token stays literal.
public sealed class ActionEngineTests
{
    private sealed record Call(string? SystemPrompt, string Input, string Model, ProviderOptions Options);

    private sealed class RecordingProvider : IProvider
    {
        public List<Call> Calls { get; } = [];

        public async IAsyncEnumerable<string> StreamAsync(
            string? systemPrompt, string input, string model, ProviderOptions options,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            Calls.Add(new Call(systemPrompt, input, model, options));
            await Task.CompletedTask;
            yield return "ok";
        }
    }

    private static ActionEngine Engine(ProviderKind kind, IProvider provider)
    {
        var factory = new ProviderFactory();
        factory.Register(kind, _ => provider);
        return new ActionEngine(factory, _ => "pg-test-key");
    }

    private static async Task<(RecordingProvider Provider, List<string> Output)> Run(ActionRequest request)
    {
        var provider = new RecordingProvider();
        var output = new List<string>();
        await foreach (var token in Engine(request.ProviderKind, provider).StreamAsync(request, TestContext.Current.CancellationToken))
            output.Add(token);
        return (provider, output);
    }

    private static ActionRequest Request(EngineAction action, ProviderKind kind = ProviderKind.OpenAi) =>
        new(action, "hello", kind, "gpt-test");

    private const string Improve =
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

    private const string Shorten =
        "You are a writing assistant. Shorten the following text: make it more concise and simpler without losing any " +
        "of the main ideas, and preserve the original meaning. Return only the shortened text — no commentary, no preamble.";

    private const string Proofread =
        "Make any necessary edits to fix spelling, grammar, punctuation, and formatting mistakes ONLY to what the user has selected.\n\n" +
        "If no issues are found, respond concisely to let the user know nothing needed to be changed.\n\n" +
        "Guidelines:\n\n" +
        "- Correct typos, grammatical errors, and punctuation issues.\n" +
        "- Reword sentences only when required to achieve grammatical correctness or to accurately convey the intended meaning.\n" +
        "- Maintain the author's tone and level of formality.\n" +
        "- Minimize changes to formatting or wording that are not required for correctness.\n" +
        "- Do NOT worry about replacing quotes with smart quotes, or other typographic nits.\n\n" +
        "Return only the corrected text — no commentary, no preamble";

    private const string Preserve =
        "Preserve the Markdown formatting of the input in your output (keep bold, italic, strikethrough, inline code, and lists).";

    private const string Refine =
        "You previously produced a result for the text below. Revise that previous result according to the user's " +
        "instruction. Return only the revised result, with no preamble or explanation.";

    private static readonly ProviderOptions NoOptions = new();

    public static TheoryData<string, ActionRequest, string?, string, ProviderOptions> AssemblyCases => new()
    {
        { "improve", Request(new EngineAction.Improve()), Improve, "hello", NoOptions },
        {
            "shorten, casual tone",
            Request(new EngineAction.Shorten(Tone: TranslateTone.Casual)),
            Shorten + "\n\nUse a casual, conversational tone.", "hello", NoOptions
        },
        // Proofread has no tone; its prompt has no final period.
        { "proofread", Request(new EngineAction.Proofread()), Proofread, "hello", NoOptions },
        {
            "improve, custom prompt trimmed, formal tone",
            Request(new EngineAction.Improve("  Fix it.\t", TranslateTone.Formal)),
            "Fix it.\n\nUse a formal tone.", "hello", NoOptions
        },
        {
            "translate, custom prompt first, French friendly suffix, formality",
            Request(new EngineAction.Translate("fr", " Keep emoji. \n", TranslateTone.Friendly)),
            "Apply these additional instructions where they do not conflict with the translation task: Keep emoji. " +
            "Translate the following text to fr. Use a friendly, warm, conversational tone. When writing in French, " +
            "address the reader informally using \"tu\"/\"toi\" rather than \"vous\". " +
            "Return only the translated text — no commentary, no preamble.",
            "hello", new ProviderOptions { TargetLanguage = "fr", Formality = "prefer_less" }
        },
        // macOS parity: the engine never branches on the provider, so a translate custom prompt with {{text}} sends
        // the substituted prompt to DeepL as the text to translate.
        {
            "translate {{text}} to DeepL: the substituted prompt is the input",
            Request(new EngineAction.Translate("de", "Say {{text}}", TranslateTone.Formal), ProviderKind.DeepL),
            null,
            "Apply these additional instructions where they do not conflict with the translation task: Say hello " +
            "Translate the following text to de. Use a formal tone. Return only the translated text — no commentary, no preamble.",
            new ProviderOptions { TargetLanguage = "de", Formality = "prefer_more" }
        },
        {
            "global prompt first, preserve formatting last",
            Request(new EngineAction.Improve()) with { GlobalPrompt = " Write in British English.\n", PreserveFormatting = true },
            "Write in British English.\n\n" + Improve + "\n\n" + Preserve, "hello", NoOptions
        },
        // {{text}} consumed the system role: the global prompt (context tokens only, {{text}} literal) becomes it.
        {
            "{{text}} consumed, global prompt becomes the system prompt",
            Request(new EngineAction.Custom("Summarize: {{text}}")) with
            {
                GlobalPrompt = "Answer in {{language}}. {{text}}",
                PreserveFormatting = true,
                Context = new PromptContext("Notepad", "", "", "fr"),
            },
            "Answer in fr. {{text}}\n\n" + Preserve, "Summarize: hello", NoOptions
        },
        // No system prompt at all: the preserve-formatting directive goes to the input.
        {
            "{{text}} consumed, preserve formatting goes to the input",
            Request(new EngineAction.Custom("Summarize: {{text}}")) with { PreserveFormatting = true },
            null, "Summarize: hello\n\n" + Preserve, NoOptions
        },
        {
            "follow-up before the global prompt",
            Request(new EngineAction.Custom("Rewrite.")) with
            {
                GlobalPrompt = "Be kind.",
                FollowUp = new FollowUp("Hi there.", "Shorter"),
            },
            "Be kind.\n\nRewrite.\n\n" + Refine + "\n\nInstruction: Shorter",
            "Original text:\nhello\n\nPrevious result:\nHi there.", NoOptions
        },
        {
            "custom endpoint trimmed into the options",
            Request(new EngineAction.Custom("Do it."), ProviderKind.Custom) with { BaseUrl = " http://localhost:1234/v1 " },
            "Do it.", "hello", new ProviderOptions { BaseUrl = new Uri("http://localhost:1234/v1") }
        },
    };

    [Theory]
    [MemberData(nameof(AssemblyCases))]
    public async Task AssemblesThePromptSentToTheProvider(
        string name, ActionRequest request, string? systemPrompt, string input, ProviderOptions options)
    {
        var (provider, output) = await Run(request);

        // The name rides along so a failing row is identified in the diff.
        Assert.Equal((name, new Call(systemPrompt, input, "gpt-test", options)), (name, Assert.Single(provider.Calls)));
        Assert.Equal(["ok"], output);
    }

    [Fact]
    public async Task SubstitutedValuesAreNeverRescanned()
    {
        // The selection and the app name contain tokens; only the template's own tokens expand.
        var request = new ActionRequest(
            new EngineAction.Custom("{{app}} / {{text}} / {{date}}"), "{{app}} {{text}}", ProviderKind.OpenAi, "m")
        {
            Context = new PromptContext("{{date}}", "", "2026-10-25", ""),
        };

        var (provider, _) = await Run(request);

        var call = Assert.Single(provider.Calls);
        Assert.Null(call.SystemPrompt);
        Assert.Equal("{{date}} / {{app}} {{text}} / 2026-10-25", call.Input);
    }

    public static TheoryData<ProviderKind, string?, string> RejectedCases => new()
    {
        { ProviderKind.OpenRouter, "  ", "Transport error: No endpoint configured for OpenRouter. Set the base URL in Settings." },
        {
            ProviderKind.Custom, " not a url ",
            "Transport error: Invalid endpoint URL for Custom (OpenAI-compatible): \"not a url\". Check the base URL in Settings."
        },
        // The echoed URL drops its user:password part.
        {
            ProviderKind.Custom, "http://user:secret@[bad/v1",
            "Transport error: Invalid endpoint URL for Custom (OpenAI-compatible): \"http://[bad/v1\". Check the base URL in Settings."
        },
    };

    [Theory]
    [MemberData(nameof(RejectedCases))]
    public async Task MissingOrInvalidEndpointFailsBeforeAnyRequest(ProviderKind kind, string? baseUrl, string message)
    {
        var request = Request(new EngineAction.Improve(), kind) with { BaseUrl = baseUrl };
        var provider = new RecordingProvider();
        var engine = Engine(kind, provider);

        var error = await Assert.ThrowsAsync<ProviderError>(async () =>
        {
            await foreach (var _ in engine.StreamAsync(request, TestContext.Current.CancellationToken)) { }
        });

        Assert.Equal(message, error.Message);
        Assert.Empty(provider.Calls);
    }

    public static TheoryData<string, string, string> QuoteCases => new()
    {
        { "\"Hello\"", "Hello", "Hello" },
        { " “Hello”\n", "Hello", "Hello" },
        { "„Hallo“", "Hallo", "Hallo" },
        // The model echoes the user's own quotes.
        { "\"Hello\"", " \"Hello\" ", "\"Hello\"" },
        // Not a wrapper: the quotes also appear inside.
        { "\"a\" and \"b\"", "a and b", "\"a\" and \"b\"" },
        // No strip: the output is returned untrimmed.
        { " Hello \n", "Hello", " Hello \n" },
    };

    [Theory]
    [MemberData(nameof(QuoteCases))]
    public void StripsOneWrappingQuotePair(string output, string input, string expected) =>
        Assert.Equal(expected, ActionEngine.StripWrappingQuotes(output, input));
}
