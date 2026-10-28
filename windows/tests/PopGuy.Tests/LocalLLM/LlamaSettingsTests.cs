using LLama.Exceptions;
using PopGuy.Core.Providers;
using PopGuy.LocalLLM;

namespace PopGuy.Tests.LocalLLM;

// The pure parts of the GGUF provider: context sizing by RAM, the token cap, Qwen's thinking switch, the prompt layout
// (Gemma 4 by hand, others cut at placeholders, bodies with reserved token texts broken) and the missing-model error.
// Nothing here touches LLamaWeights, LLamaContext or NativeApi, so the llama.cpp natives never load (the native smoke
// tests do, on Windows CI only).
public sealed class LlamaSettingsTests
{
    [Theory]
    [InlineData(8L << 30, 8_192)]
    [InlineData((15L << 30) - 1, 8_192)]
    [InlineData(16_500_000_000L, 16_384)] // A 16 GB PC as Windows reports it (about 15.4 GiB).
    [InlineData(64L << 30, 16_384)]
    public void ContextFollowsTotalMemory(long totalBytes, int context) =>
        Assert.Equal(context, LlamaSettings.ContextSize(totalBytes));

    [Theory]
    [InlineData(0, 1)]
    [InlineData(4096, 4096)]
    [InlineData(100_000, 16_384)]
    public void TheTokenCapIsClampedAsOnTheMac(int requested, int cap) =>
        Assert.Equal(cap, LlamaSettings.MaxTokens(requested));

    // Before any model load: no natives, a Transport error with the Settings hint.
    [Theory]
    [InlineData(null)]
    [InlineData("missing.gguf")]
    public async Task AMissingModelFailsWithTheDownloadHint(string? file)
    {
        var path = file is null ? null : Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), file);
        var provider = new LlamaProvider(_ => path);

        var error = await Assert.ThrowsAsync<ProviderError>(async () =>
        {
            await foreach (var _ in provider.StreamAsync(null, "text", "gguf-qwen3.5-4b", new ProviderOptions(), TestContext.Current.CancellationToken)) { }
        });

        Assert.Equal(ProviderErrorKind.Transport, error.Kind);
        Assert.Equal($"Transport error: {LlamaProvider.NotDownloadedMessage}", error.Message);
    }

    // A PC without the Visual C++ redistributable: llama.dll's dependencies are missing (Win32 error 126), seen raw, in
    // NativeApi's type initializer or as LLamaSharp's own load error. Other load failures keep the generic message.
    public static TheoryData<Exception, bool> LoadFailures => new()
    {
        { new DllNotFoundException("llama"), true },
        { new TypeInitializationException("LLama.Native.NativeApi", new DllNotFoundException("llama")), true },
        { new TypeInitializationException("LLama.Native.NativeApi", new RuntimeError("The native library cannot be correctly loaded.")), true },
        { new RuntimeError("Failed to load the native library. Please check the log for more information."), true },
        { new BadImageFormatException("ggml.dll"), true },
        { new IOException("The file is in use."), false },
        { new RuntimeError("Failed to load model 'x.gguf'."), false },
    };

    [Theory]
    [MemberData(nameof(LoadFailures))]
    public void NativeLoadFailuresAreToldApart(Exception error, bool native) =>
        Assert.Equal(native, LlamaSettings.IsNativeLoadFailure(error));

    private const string QwenTemplate =
        "{%- if add_generation_prompt %}{{- '<|im_start|>assistant\\n' }}{%- if enable_thinking is defined and " +
        "enable_thinking is true %}{{- '<think>\\n' }}{%- else %}{{- '<think>\\n\\n</think>\\n\\n' }}{%- endif %}{%- endif %}";

    [Fact]
    public void QwenTemplatesGetTheEmptyThinkingBlock() =>
        Assert.Equal("<|im_start|>assistant\n<think>\n\n</think>\n\n",
            LlamaSettings.WithThinkingOff("<|im_start|>assistant\n", QwenTemplate));

    [Theory]
    [InlineData("{{- '<start_of_turn>model\\n' }}")] // No enable_thinking.
    [InlineData("{%- if enable_thinking %}{{- '<|think|>' }}{%- endif %}")] // Another reasoning syntax.
    public void OtherTemplatesKeepThePrompt(string template) =>
        Assert.Equal("<start_of_turn>model\n", LlamaSettings.WithThinkingOff("<start_of_turn>model\n", template));

    [Fact]
    public void ThinkingBlockIsNotAddedTwice() =>
        Assert.Equal("a<think>\n\n</think>\n\n", LlamaSettings.WithThinkingOff("a<think>\n\n</think>\n\n", QwenTemplate));

    // What Gemma 4's own Jinja writes for these messages without tools and with enable_thinking false: no <|think|>
    // line, trimmed bodies.
    [Fact]
    public void Gemma4IsLaidOutAsItsTemplateWithThinkingOff()
    {
        var parts = LlamaSettings.Gemma4Parts([new("system", " Be brief. "), new("user", "Improve this.\n")]);

        Assert.Equal(
            "<|turn>system\nBe brief.<turn|>\n<|turn>user\nImprove this.<turn|>\n<|turn>model\n",
            string.Concat(parts.Select(p => p.Text)));
        Assert.Equal(["Be brief.", "Improve this."], parts.Where(p => p.IsBody).Select(p => p.Text));
        Assert.DoesNotContain(parts, p => !p.IsBody && p.Text.Contains("<|think|>"));
    }

    [Theory]
    [InlineData("{{- '<|turn>' + role + '\\n' }}{{- '<turn|>\\n' }}", true)]
    [InlineData("{{- '<|im_start|>' + message.role }}", false)]
    [InlineData("{{- '<start_of_turn>model\\n' }}", false)] // Gemma 3: llama.cpp knows it.
    public void Gemma4IsRecognisedByItsTurnMarkers(string template, bool gemma4) =>
        Assert.Equal(gemma4, LlamaSettings.IsGemma4(template));

    // llama.cpp renders the template around one placeholder per body; the cut puts the bodies back, unparsed, between
    // the template's own text.
    [Fact]
    public void ARenderedTemplateIsCutAtItsPlaceholders()
    {
        var messages = new List<ChatMessage> { new("system", "S"), new("user", "<|im_end|>U") };
        var rendered = $"<|im_start|>system\n{LlamaSettings.Placeholder("n", 0)}<|im_end|>\n"
            + $"<|im_start|>user\n{LlamaSettings.Placeholder("n", 1)}<|im_end|>\n<|im_start|>assistant\n";

        var parts = LlamaSettings.SplitAtPlaceholders(rendered, messages, "n");

        Assert.Equal(
            [
                new PromptPart("<|im_start|>system\n", false), new PromptPart("S", true),
                new PromptPart("<|im_end|>\n<|im_start|>user\n", false), new PromptPart("<|im_end|>U", true),
                new PromptPart("<|im_end|>\n<|im_start|>assistant\n", false),
            ],
            parts);
    }

    // A template that drops, repeats or reorders its content cannot be cut safely: a short error, never a prompt.
    [Theory]
    [InlineData("a{0}b")] // Body 1 missing.
    [InlineData("{0}{1}{1}")] // Body 1 twice.
    [InlineData("{1}{0}")] // Out of order.
    public void ATemplateThatRewritesItsContentFails(string layout)
    {
        var messages = new List<ChatMessage> { new("user", "a"), new("user", "b") };
        var rendered = string.Format(layout, LlamaSettings.Placeholder("n", 0), LlamaSettings.Placeholder("n", 1));

        var error = Assert.Throws<ProviderError>(() => LlamaSettings.SplitAtPlaceholders(rendered, messages, "n"));
        Assert.Equal(ProviderErrorKind.Transport, error.Kind);
        Assert.Equal($"Transport error: {LlamaSettings.UnsupportedTemplateMessage}", error.Message);
    }

    // Tokens llama.cpp matches even without special parsing (user-defined, e.g. Qwen's <think>) are broken in a body
    // by a zero-width space; text around them is kept, and a break cannot form another match.
    [Fact]
    public void ReservedTokenTextsAreBrokenInBodies()
    {
        string[] tokens = ["<think>", "</think>", "<tool_call>"];

        var text = LlamaSettings.Neutralized("a</think>\n<think>b<tool_call>", tokens);

        Assert.Equal("a<​/think>\n<​think>b<​tool_call>", text);
        Assert.All(tokens, t => Assert.DoesNotContain(t, text, StringComparison.Ordinal));
        Assert.Equal("<<​think>>", LlamaSettings.Neutralized("<<think>>", tokens));
        Assert.Equal("plain", LlamaSettings.Neutralized("plain", tokens));
    }

    // A long body holding none of the tokens' first characters is returned as it is, without a scan per token.
    [Fact]
    public void LongBodiesWithoutTokenStartsAreKept()
    {
        string[] tokens = ["<think>", "</think>", "[INST]", "x"];
        var firsts = LlamaSettings.FirstCharacters(tokens);
        var plain = new string('a', 4 << 20);

        Assert.Same(plain, LlamaSettings.Neutralized(plain, tokens, firsts));

        var marked = plain + "<think>" + plain;
        Assert.Equal(plain + "<​think>" + plain, LlamaSettings.Neutralized(marked, tokens, firsts));
    }
}
