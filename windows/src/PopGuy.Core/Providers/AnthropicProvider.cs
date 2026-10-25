using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;

namespace PopGuy.Core.Providers;

/// <summary>
/// The Anthropic Messages API, streamed (spec-2 §3.3, a port of AnthropicProvider.swift).
/// <list type="bullet">
/// <item><c>POST https://api.anthropic.com/v1/messages</c> (not configurable) with <c>x-api-key</c> and
/// <c>anthropic-version: 2023-06-01</c>; no beta header.</item>
/// <item>Body <c>{model, max_tokens, messages: [user], stream: true}</c> plus <c>system</c> when the prompt is not null.
/// Never temperature, top_p or top_k: recent models reject them with a 400.</item>
/// <item>Yields <c>delta.text</c> of <c>content_block_delta</c> events whose delta is a <c>text_delta</c>; an
/// <c>error</c> event (sent after a 200, e.g. overloaded_error) throws <see cref="ProviderError.Api"/>.</item>
/// </list>
/// </summary>
public sealed class AnthropicProvider(string apiKey, ProviderHttp? http = null) : IProvider
{
    private static readonly Uri Endpoint = new("https://api.anthropic.com/v1/messages");
    private const string ApiVersion = "2023-06-01";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public async IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = options.MaxTokens,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = input }),
            ["stream"] = true,
        };
        if (systemPrompt is not null)
            body["system"] = systemPrompt;

        var request = new HttpRequestMessage(HttpMethod.Post, Endpoint) { Content = ProviderJson.Content(body) };
        request.Headers.TryAddWithoutValidation("x-api-key", apiKey);
        request.Headers.TryAddWithoutValidation("anthropic-version", ApiVersion);

        await foreach (var payload in _http.StreamSseAsync(request, apiKey, ct))
        {
            if (ParseText(payload, apiKey) is { } text)
                yield return text;
        }
    }

    private static string? ParseText(string payload, string apiKey)
    {
        var json = ProviderJson.Parse(payload);
        var type = json.Get("type").String();
        if (type == "error")
        {
            var error = json.Get("error");
            throw ProviderError.Api(
                error.Get("type").String() ?? "unknown_error",
                ProviderHttp.Redact(error.Get("message").String() ?? "Anthropic error event received", apiKey));
        }
        var delta = json.Get("delta");
        return type == "content_block_delta" && delta.Get("type").String() == "text_delta"
            && delta.Get("text").String() is { Length: > 0 } text
            ? text
            : null;
    }
}
