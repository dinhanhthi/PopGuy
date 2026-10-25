using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PopGuy.Core.Providers;

/// <summary>
/// The native Gemini REST API, streamed as SSE (spec-2 §3.4, a port of GeminiProvider.swift); never the
/// OpenAI-compatible shim.
/// <list type="bullet">
/// <item><c>POST {base}/models/{model}:streamGenerateContent?alt=sse</c>, base = <see cref="ProviderOptions.BaseUrl"/>
/// or the v1beta root, trailing slashes stripped. The model is one escaped path segment, so <c>/ ? #</c> in an id
/// cannot rewrite the URL (escaping is stricter than macOS's set; identical for real model ids).</item>
/// <item>The key goes in the <c>x-goog-api-key</c> header, never the query.</item>
/// <item>Body <c>{contents: [user], systemInstruction?, generationConfig: {maxOutputTokens, thinkingConfig?}}</c>:
/// systemInstruction only for a non-empty prompt; <c>thinkingBudget: 0</c> only for "flash" models (the only family
/// that accepts turning thinking off).</item>
/// <item>Yields the joined <c>candidates[0].content.parts[*].text</c> of each chunk; an <c>error</c> object throws
/// <see cref="ProviderError.Api"/>. No [DONE]: the stream ends with the body.</item>
/// </list>
/// </summary>
public sealed class GeminiProvider(string apiKey, ProviderHttp? http = null) : IProvider
{
    private const string NativeBase = "https://generativelanguage.googleapis.com/v1beta";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public async IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var root = (options.BaseUrl?.AbsoluteUri ?? NativeBase).TrimEnd('/');
        var endpoint = $"{root}/models/{Uri.EscapeDataString(model)}:streamGenerateContent?alt=sse";
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var url))
            throw ProviderError.Transport($"Invalid Gemini endpoint URL: {endpoint}");

        var generationConfig = new JsonObject { ["maxOutputTokens"] = options.MaxTokens };
        if (model.ToLowerInvariant().Contains("flash", StringComparison.Ordinal))
            generationConfig["thinkingConfig"] = new JsonObject { ["thinkingBudget"] = 0 };
        var body = new JsonObject
        {
            ["contents"] = new JsonArray(new JsonObject { ["role"] = "user", ["parts"] = TextParts(input) }),
        };
        if (!string.IsNullOrEmpty(systemPrompt))
            body["systemInstruction"] = new JsonObject { ["parts"] = TextParts(systemPrompt) };
        body["generationConfig"] = generationConfig;

        var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = ProviderJson.Content(body) };
        request.Headers.TryAddWithoutValidation("x-goog-api-key", apiKey);

        await foreach (var payload in _http.StreamSseAsync(request, apiKey, ct))
        {
            if (ParseText(payload) is { } text)
                yield return text;
        }
    }

    private static JsonArray TextParts(string text) => new(new JsonObject { ["text"] = text });

    private static string? ParseText(string payload)
    {
        var json = ProviderJson.Parse(payload);
        var error = json.Get("error");
        if (error is { ValueKind: JsonValueKind.Object })
        {
            throw ProviderError.Api(
                error.Get("status").String() ?? "UNKNOWN",
                error.Get("message").String() ?? "Gemini error event received");
        }
        var parts = json.Get("candidates").First().Get("content").Get("parts").Items();
        var text = string.Concat(parts.Select(part => ((JsonElement?)part).Get("text").String()));
        return text.Length > 0 ? text : null;
    }
}
