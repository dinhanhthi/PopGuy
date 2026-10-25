using System.Net;
using System.Text.Json;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Settings;
using PopGuy.Tests.Support;

namespace PopGuy.Tests.Core;

// Contract: the shared HTTP plumbing and SSE decoder of every streaming adapter (spec-2 §2.9, §3.0), and each
// adapter's wire format: request URL, headers and body, the streamed text, HTTP and in-stream errors (spec-2 §3.2-3.7).
public sealed class ProviderStreamTests
{
    private static async Task<List<string>> Payloads(FakeHttpHandler handler, string? apiKey = null)
    {
        var http = new ProviderHttp(handler);
        var request = new HttpRequestMessage(HttpMethod.Post, "https://api.example.test/v1/chat/completions");
        var payloads = new List<string>();
        await foreach (var payload in http.StreamSseAsync(request, apiKey, TestContext.Current.CancellationToken))
            payloads.Add(payload);
        return payloads;
    }

    [Fact]
    public async Task SseYieldsDataLinesAndStopsAtDone()
    {
        const string body =
            ": keep-alive\r\nevent: delta\r\nid: 7\r\nretry: 3000\r\ndata: {\"a\":1}\r\n\r\ndata:no-space\n\n" +
            "data:  two spaces\n\ndata: [DONE]\n\ndata: after done\n\n";

        var payloads = await Payloads(new FakeHttpHandler(HttpStatusCode.OK, body));

        Assert.Equal(["{\"a\":1}", "no-space", " two spaces"], payloads);
    }

    [Fact]
    public async Task SseSurvivesChunksSplitAtEveryByte()
    {
        // One byte per read splits CR from LF and every multi-byte UTF-8 sequence (é is 2 bytes, the emoji 4).
        const string body = "data: héllo 😀 wörld\r\n\r\ndata: 日本語\n\ndata: [DONE]\n\n";

        var payloads = await Payloads(new FakeHttpHandler(HttpStatusCode.OK, body, chunkSize: 1));

        Assert.Equal(["héllo 😀 wörld", "日本語"], payloads);
    }

    [Fact]
    public async Task ErrorBodyEchoingTheApiKeyIsRedacted()
    {
        // The key matches none of the generic patterns, so only the exact-key rule can remove it.
        const string apiKey = "pg-test-7f3a9c1e5b2d";
        var body = $$$"""{"error":{"message":"Incorrect API key provided: {{{apiKey}}}","header":"Bearer other-secret-token"}}""";
        var handler = new FakeHttpHandler(HttpStatusCode.Unauthorized, body);

        var error = await Assert.ThrowsAsync<ProviderError>(() => Payloads(handler, apiKey));

        Assert.Equal(ProviderErrorKind.Http, error.Kind);
        Assert.Equal(401, error.StatusCode);
        Assert.StartsWith("HTTP 401: {\"error\":{\"message\":\"Incorrect API key provided: ", error.Message);
        Assert.DoesNotContain(apiKey, error.ToString());
        Assert.DoesNotContain("other-secret-token", error.ToString());
    }

    private const string Key = "pg-test-key";

    private static async Task<(List<string> Texts, RecordedRequest Request)> Run(
        Func<ProviderHttp, IProvider> create, string responseBody, string? systemPrompt, string model, ProviderOptions options)
    {
        var handler = new FakeHttpHandler(HttpStatusCode.OK, responseBody);
        var texts = new List<string>();
        await foreach (var text in create(new ProviderHttp(handler))
            .StreamAsync(systemPrompt, "hello", model, options, TestContext.Current.CancellationToken))
            texts.Add(text);
        return (texts, Assert.Single(handler.Requests));
    }

    private static JsonElement Body(RecordedRequest request) => JsonDocument.Parse(request.Body!).RootElement;

    private const string ChatCompletionsSse =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\ndata: not-json\n\n" +
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" +
        "data: [DONE]\n\n";

    [Theory]
    [InlineData(ProviderKind.OpenAi, null, "https://api.openai.com/v1/chat/completions", null)]
    [InlineData(ProviderKind.Glm, "https://api.z.ai/api/paas/v4/", "https://api.z.ai/api/paas/v4/chat/completions",
        """{"thinking":{"type":"disabled"}}""")]
    [InlineData(ProviderKind.OpenRouter, "https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1/chat/completions",
        """{"reasoning":{"enabled":false}}""")]
    [InlineData(ProviderKind.Custom, "http://localhost:8080/v1//", "http://localhost:8080/v1/chat/completions", null)]
    public async Task OpenAiWireFormat(ProviderKind kind, string? baseUrl, string expectedUrl, string? extraField)
    {
        var options = new ProviderOptions { BaseUrl = baseUrl is null ? null : new Uri(baseUrl) };

        var (texts, request) = await Run(
            http => new ProviderFactory(http).Create(kind, Key), ChatCompletionsSse, "sys", "gpt-x", options);

        Assert.Equal(["Hel", "lo"], texts);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal(expectedUrl, request.Uri!.AbsoluteUri);
        Assert.Equal($"Bearer {Key}", request.Headers["Authorization"]);
        Assert.Equal("application/json", request.Headers["Content-Type"]);
        var body = Body(request);
        Assert.Equal("gpt-x", body.GetProperty("model").GetString());
        Assert.True(body.GetProperty("stream").GetBoolean());
        Assert.Equal("""[{"role":"system","content":"sys"},{"role":"user","content":"hello"}]""",
            body.GetProperty("messages").GetRawText());
        Assert.False(body.TryGetProperty("max_tokens", out _));
        var expectedKeys = new List<string> { "model", "messages", "stream" };
        if (extraField is not null)
        {
            var extra = JsonDocument.Parse(extraField).RootElement.EnumerateObject().Single();
            Assert.Equal(extra.Value.GetRawText(), body.GetProperty(extra.Name).GetRawText());
            expectedKeys.Add(extra.Name);
        }
        Assert.Equal(expectedKeys.Order(), body.EnumerateObject().Select(p => p.Name).Order());
    }

    [Fact]
    public async Task OllamaWireFormat()
    {
        var (texts, request) = await Run(
            http => new OllamaProvider(http), ChatCompletionsSse, null, "llama3.1", new ProviderOptions());

        Assert.Equal(["Hel", "lo"], texts);
        Assert.Equal("http://localhost:11434/v1/chat/completions", request.Uri!.AbsoluteUri);
        Assert.False(request.Headers.ContainsKey("Authorization"));
        var body = Body(request);
        Assert.Equal("llama3.1", body.GetProperty("model").GetString());
        Assert.Equal("""[{"role":"user","content":"hello"}]""", body.GetProperty("messages").GetRawText());
        Assert.True(body.GetProperty("stream").GetBoolean());
        Assert.Equal("none", body.GetProperty("reasoning_effort").GetString());
    }

    [Fact]
    public async Task AnthropicWireFormat()
    {
        const string sse =
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{}}\n\n" +
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"x\"}}\n\n" +
            "data: not-json\n\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}\n\n" +
            "event: ping\ndata: {\"type\":\"ping\"}\n\n" +
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}\n\n" +
            "data: {\"type\":\"message_stop\"}\n\n";

        var (texts, request) = await Run(
            http => new AnthropicProvider(Key, http), sse, "sys", "claude-x", new ProviderOptions { MaxTokens = 1234 });

        Assert.Equal(["Hel", "lo"], texts);
        Assert.Equal("https://api.anthropic.com/v1/messages", request.Uri!.AbsoluteUri);
        Assert.Equal(Key, request.Headers["x-api-key"]);
        Assert.Equal("2023-06-01", request.Headers["anthropic-version"]);
        Assert.False(request.Headers.ContainsKey("Authorization"));
        var body = Body(request);
        Assert.Equal("claude-x", body.GetProperty("model").GetString());
        Assert.Equal(1234, body.GetProperty("max_tokens").GetInt32());
        Assert.Equal("sys", body.GetProperty("system").GetString());
        Assert.Equal("""[{"role":"user","content":"hello"}]""", body.GetProperty("messages").GetRawText());
        Assert.True(body.GetProperty("stream").GetBoolean());
        // No sampling parameters: Anthropic rejects temperature, top_p and top_k on recent models.
        Assert.Equal(["max_tokens", "messages", "model", "stream", "system"], body.EnumerateObject().Select(p => p.Name).Order());
    }

    [Fact]
    public async Task GeminiWireFormat()
    {
        const string sse =
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hel\"},{\"text\":\"lo\"}]}}]}\r\n\r\n" +
            "data: not-json\r\n\r\ndata: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\" there\"}]}}]}\r\n\r\n" +
            "data: {\"usageMetadata\":{\"totalTokenCount\":5}}\r\n\r\n";

        // A model id with URL-structural characters must stay inside its path segment.
        var (texts, request) = await Run(
            http => new GeminiProvider(Key, http), sse, "sys", "Gemini/3.5?Flash#x", new ProviderOptions());

        Assert.Equal(["Hello", " there"], texts);
        Assert.Equal(
            "https://generativelanguage.googleapis.com/v1beta/models/Gemini%2F3.5%3FFlash%23x:streamGenerateContent?alt=sse",
            request.Uri!.AbsoluteUri);
        Assert.Equal(Key, request.Headers["x-goog-api-key"]);
        Assert.DoesNotContain(Key, request.Uri.AbsoluteUri);
        var body = Body(request);
        Assert.Equal("""[{"role":"user","parts":[{"text":"hello"}]}]""", body.GetProperty("contents").GetRawText());
        Assert.Equal("""{"parts":[{"text":"sys"}]}""", body.GetProperty("systemInstruction").GetRawText());
        Assert.Equal("""{"maxOutputTokens":4096,"thinkingConfig":{"thinkingBudget":0}}""",
            body.GetProperty("generationConfig").GetRawText());
    }

    [Theory]
    [InlineData("anthropic", """{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}""",
        "API error (overloaded_error): Overloaded")]
    [InlineData("gemini", """{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}""",
        "API error (RESOURCE_EXHAUSTED): Quota exceeded")]
    public async Task InStreamErrorEventThrowsApiError(string adapter, string errorPayload, string expectedMessage)
    {
        Func<ProviderHttp, IProvider> create = adapter == "anthropic"
            ? http => new AnthropicProvider(Key, http)
            : http => new GeminiProvider(Key, http);

        var error = await Assert.ThrowsAsync<ProviderError>(
            () => Run(create, $"data: {errorPayload}\n\n", null, "m", new ProviderOptions()));

        Assert.Equal(ProviderErrorKind.Api, error.Kind);
        Assert.Equal(expectedMessage, error.Message);
    }

    [Theory]
    [InlineData("free-key:fx", "https://api-free.deepl.com/v2/translate", "en", "prefer_more")]
    [InlineData("pro-key", "https://api.deepl.com/v2/translate", null, null)]
    public async Task DeepLWireFormat(string apiKey, string expectedUrl, string? sourceLanguage, string? formality)
    {
        const string response = """{"translations":[{"detected_source_language":"EN","text":"Bonjour"}]}""";
        var options = new ProviderOptions { TargetLanguage = "fr", SourceLanguage = sourceLanguage, Formality = formality };

        var (texts, request) = await Run(http => new DeepLProvider(apiKey, http), response, "ignored", "", options);

        Assert.Equal(["Bonjour"], texts);
        Assert.Equal(expectedUrl, request.Uri!.AbsoluteUri);
        Assert.Equal($"DeepL-Auth-Key {apiKey}", request.Headers["Authorization"]);
        Assert.Equal("application/json", request.Headers["Content-Type"]);
        var body = Body(request);
        Assert.Equal("""["hello"]""", body.GetProperty("text").GetRawText());
        Assert.Equal("FR", body.GetProperty("target_lang").GetString());
        Assert.Equal(sourceLanguage?.ToUpperInvariant(), body.TryGetProperty("source_lang", out var src) ? src.GetString() : null);
        Assert.Equal(formality, body.TryGetProperty("formality", out var f) ? f.GetString() : null);
    }

    [Fact]
    public async Task GoogleTranslateWireFormat()
    {
        // translatedText is HTML-escaped even for format:text; &amp; decodes last, so "&amp;lt;" becomes "&lt;".
        const string response =
            """{"data":{"translations":[{"translatedText":"Tom &amp; Jerry &lt;b&gt; &#39;hi&#39; &#x1F600; &#xD800; &amp;lt;"}]}}""";

        var (texts, request) = await Run(
            http => new GoogleTranslateProvider(Key, http), response, "ignored", "", new ProviderOptions { TargetLanguage = "vi" });

        Assert.Equal(["Tom & Jerry <b> 'hi' 😀 &#xD800; &lt;"], texts);
        Assert.Equal($"https://translation.googleapis.com/language/translate/v2?key={Key}", request.Uri!.AbsoluteUri);
        Assert.False(request.Headers.ContainsKey("Authorization"));
        var body = Body(request);
        Assert.Equal("hello", body.GetProperty("q").GetString());
        Assert.Equal("vi", body.GetProperty("target").GetString());
        Assert.Equal("text", body.GetProperty("format").GetString());
        Assert.False(body.TryGetProperty("source", out _));
    }

    // The factory routes every HTTP kind to its adapter and endpoint (base URLs resolved from settings as on macOS);
    // a 401 surfaces as an HTTP error for each of them.
    [Theory]
    [InlineData(ProviderKind.OpenAi, "https://api.openai.com/v1/chat/completions")]
    [InlineData(ProviderKind.Glm, "https://api.z.ai/api/paas/v4/chat/completions")]
    [InlineData(ProviderKind.OpenRouter, "https://openrouter.ai/api/v1/chat/completions")]
    [InlineData(ProviderKind.Custom, "http://localhost:8080/v1/chat/completions")]
    [InlineData(ProviderKind.Ollama, "http://localhost:1234/v1/chat/completions")]
    [InlineData(ProviderKind.Anthropic, "https://api.anthropic.com/v1/messages")]
    [InlineData(ProviderKind.Gemini, "https://generativelanguage.googleapis.com/v1beta/models/m:streamGenerateContent?alt=sse")]
    [InlineData(ProviderKind.DeepL, "https://api.deepl.com/v2/translate")]
    [InlineData(ProviderKind.GoogleTranslate, "https://translation.googleapis.com/language/translate/v2?key=pg-test-key")]
    public async Task FactoryRoutesEachKindAndSurfacesHttp401(ProviderKind kind, string expectedUrl)
    {
        var settings = new AppSettings { OllamaBaseUrl = "http://localhost:1234/v1", CustomBaseUrl = "http://localhost:8080/v1/" };
        var baseUrl = ProviderFactory.ResolveBaseUrl(kind, settings);
        var options = new ProviderOptions { BaseUrl = baseUrl is null ? null : new Uri(baseUrl), TargetLanguage = "fr" };
        var handler = new FakeHttpHandler(HttpStatusCode.Unauthorized, """{"error":"invalid key"}""");
        var provider = new ProviderFactory(new ProviderHttp(handler)).Create(kind, Key);

        var error = await Assert.ThrowsAsync<ProviderError>(async () =>
        {
            await foreach (var _ in provider.StreamAsync(null, "hello", "m", options, TestContext.Current.CancellationToken)) { }
        });

        Assert.Equal(ProviderErrorKind.Http, error.Kind);
        Assert.Equal(401, error.StatusCode);
        Assert.Equal(expectedUrl, Assert.Single(handler.Requests).Uri!.AbsoluteUri);
    }
}
