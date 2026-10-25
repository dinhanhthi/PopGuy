using System.Runtime.CompilerServices;

namespace PopGuy.Core.Providers;

/// <summary>
/// Ollama and LM Studio through their OpenAI-compatible endpoint (spec-2 §3.5, a port of OllamaProvider.swift).
/// <c>POST {base}/chat/completions</c> with base = <see cref="ProviderOptions.BaseUrl"/> or
/// <see cref="DefaultBaseUrl"/>; no Authorization header (local servers need no key). The body is the OpenAI one plus
/// <c>reasoning_effort: "none"</c>, which turns thinking off on thinking-capable local models.
/// </summary>
public sealed class OllamaProvider(ProviderHttp? http = null) : IProvider
{
    public const string DefaultBaseUrl = "http://localhost:11434/v1";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public async IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var body = OpenAIProvider.ChatBody(model, systemPrompt, input);
        body["reasoning_effort"] = "none";
        var url = OpenAIProvider.ChatCompletionsUrl(options.BaseUrl, DefaultBaseUrl, "Invalid Ollama base URL");
        var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = ProviderJson.Content(body) };

        await foreach (var payload in _http.StreamSseAsync(request, apiKey: null, ct))
        {
            if (OpenAIProvider.ParseDelta(payload) is { } delta)
                yield return delta;
        }
    }
}
