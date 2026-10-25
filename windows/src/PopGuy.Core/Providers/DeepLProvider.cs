using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;

namespace PopGuy.Core.Providers;

/// <summary>
/// DeepL translation, not streamed: the result is yielded once (spec-2 §3.6, a port of DeepLProvider.swift).
/// <list type="bullet">
/// <item>A key ending in <c>:fx</c> is Free (<c>api-free.deepl.com</c>); any other key is Pro (<c>api.deepl.com</c>).</item>
/// <item><c>POST /v2/translate</c> with <c>Authorization: DeepL-Auth-Key &lt;key&gt;</c> and a JSON body
/// <c>{text: [input], target_lang, source_lang?, formality?}</c>; language codes uppercased.</item>
/// <item>The system prompt and model are ignored. Reads <c>translations[0].text</c>.</item>
/// </list>
/// </summary>
public sealed class DeepLProvider(string apiKey, ProviderHttp? http = null) : IProvider
{
    private static readonly Uri FreeEndpoint = new("https://api-free.deepl.com/v2/translate");
    private static readonly Uri ProEndpoint = new("https://api.deepl.com/v2/translate");

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public async IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(options.TargetLanguage))
            throw ProviderError.MissingOption("targetLanguage is required for DeepL translation");

        var body = new JsonObject
        {
            ["text"] = new JsonArray(input),
            ["target_lang"] = options.TargetLanguage.ToUpperInvariant(),
        };
        if (options.SourceLanguage is { } source)
            body["source_lang"] = source.ToUpperInvariant();
        // DeepL ignores prefer_* for target languages without formality support, so no per-language gate.
        if (!string.IsNullOrEmpty(options.Formality))
            body["formality"] = options.Formality;

        var endpoint = apiKey.EndsWith(":fx", StringComparison.Ordinal) ? FreeEndpoint : ProEndpoint;
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = ProviderJson.Content(body) };
        request.Headers.TryAddWithoutValidation("Authorization", $"DeepL-Auth-Key {apiKey}");

        var response = await _http.SendAsync(request, apiKey, ct);
        yield return ProviderJson.Parse(response).Get("translations").First().Get("text").String()
            ?? throw ProviderError.DecodingFailed("Could not parse translations[0].text from DeepL response");
    }
}
