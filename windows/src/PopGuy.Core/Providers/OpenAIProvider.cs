using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using PopGuy.Core.Actions;

namespace PopGuy.Core.Providers;

/// <summary>
/// OpenAI Chat Completions, streamed (spec-2 §3.2, a port of OpenAIProvider.swift). Also serves GLM, OpenRouter and
/// Custom, whose base URL arrives in <see cref="ProviderOptions.BaseUrl"/>.
/// <list type="bullet">
/// <item><c>POST {base}/chat/completions</c>, base trailing slashes stripped; <c>Authorization: Bearer &lt;key&gt;</c>
/// is sent for every kind, even with an empty key.</item>
/// <item>Body <c>{model, messages: [system?, user], stream: true}</c>; no max_tokens or temperature. GLM adds
/// <c>thinking: {type: "disabled"}</c>, OpenRouter <c>reasoning: {enabled: false}</c>; plain OpenAI and Custom add
/// nothing (OpenAI's non-reasoning models reject reasoning fields).</item>
/// <item>Yields each non-empty <c>choices[0].delta.content</c>.</item>
/// </list>
/// </summary>
public sealed class OpenAIProvider(string apiKey, ProviderKind? providerKind = null, ProviderHttp? http = null) : IProvider
{
    private const string DefaultBase = "https://api.openai.com/v1";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public async IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var body = ChatBody(model, systemPrompt, input);
        switch (providerKind)
        {
            case ProviderKind.Glm:
                body["thinking"] = new JsonObject { ["type"] = "disabled" };
                break;
            case ProviderKind.OpenRouter:
                body["reasoning"] = new JsonObject { ["enabled"] = false };
                break;
        }

        var request = new HttpRequestMessage(HttpMethod.Post, ChatCompletionsUrl(options.BaseUrl, DefaultBase, "Invalid base URL"))
        {
            Content = ProviderJson.Content(body),
        };
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiKey}");

        await foreach (var payload in _http.StreamSseAsync(request, apiKey, ct))
        {
            if (ParseDelta(payload) is { } delta)
                yield return delta;
        }
    }

    // The Chat Completions wire format, shared with OllamaProvider.

    internal static Uri ChatCompletionsUrl(Uri? baseUrl, string defaultBase, string invalidMessage)
    {
        var root = (baseUrl?.AbsoluteUri ?? defaultBase).TrimEnd('/');
        return Uri.TryCreate($"{root}/chat/completions", UriKind.Absolute, out var url)
            ? url
            : throw ProviderError.Transport($"{invalidMessage}: {root}");
    }

    internal static JsonObject ChatBody(string model, string? systemPrompt, string input)
    {
        var messages = new JsonArray();
        if (systemPrompt is not null)
            messages.Add(new JsonObject { ["role"] = "system", ["content"] = systemPrompt });
        messages.Add(new JsonObject { ["role"] = "user", ["content"] = input });
        return new JsonObject { ["model"] = model, ["messages"] = messages, ["stream"] = true };
    }

    internal static string? ParseDelta(string payload) =>
        ProviderJson.Parse(payload).Get("choices").First().Get("delta").Get("content").String() is { Length: > 0 } content
            ? content
            : null;
}
