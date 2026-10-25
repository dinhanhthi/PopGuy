using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace PopGuy.Core.Providers;

/// <summary>
/// Google Cloud Translation v2 (Basic), not streamed: the result is yielded once (spec-2 §3.7, a port of
/// GoogleTranslateProvider.swift). v3 needs OAuth, which the API-key model cannot provide.
/// <list type="bullet">
/// <item><c>POST https://translation.googleapis.com/language/translate/v2?key=&lt;key&gt;</c>, no Authorization header.
/// The URL carries the key: it is never logged, and error texts are redacted by <see cref="ProviderHttp"/>.</item>
/// <item>Body <c>{q, target, format: "text", source?}</c>, language codes as given. The system prompt, model and
/// formality are ignored.</item>
/// <item>Reads <c>data.translations[0].translatedText</c>, which Google HTML-escapes even for plain text, and decodes
/// the entities as macOS does (not a full HTML decode).</item>
/// </list>
/// </summary>
public sealed partial class GoogleTranslateProvider(string apiKey, ProviderHttp? http = null) : IProvider
{
    private const string Endpoint = "https://translation.googleapis.com/language/translate/v2";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public async IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(options.TargetLanguage))
            throw ProviderError.MissingOption("targetLanguage is required for Google Translate");

        var body = new JsonObject { ["q"] = input, ["target"] = options.TargetLanguage, ["format"] = "text" };
        if (options.SourceLanguage is { } source)
            body["source"] = source;

        var url = new Uri($"{Endpoint}?key={Uri.EscapeDataString(apiKey)}");
        var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = ProviderJson.Content(body) };

        var response = await _http.SendAsync(request, apiKey, ct);
        var text = ProviderJson.Parse(response).Get("data").Get("translations").First().Get("translatedText").String()
            ?? throw ProviderError.DecodingFailed(
                "Could not parse data.translations[0].translatedText from Google Translate response");
        yield return DecodeHtmlEntities(text);
    }

    private static readonly (string Entity, string Text)[] NamedEntities =
        [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'")];

    // "&#" up to the first ";". A reference that does not parse is kept verbatim.
    [GeneratedRegex("&#([^;]*);")]
    private static partial Regex NumericReference();

    /// <summary>
    /// The named entities above, then decimal and hex numeric references, then <c>&amp;amp;</c> last so that
    /// <c>&amp;amp;lt;</c> decodes once to <c>&amp;lt;</c>. Code points that are not Unicode scalars stay literal.
    /// </summary>
    private static string DecodeHtmlEntities(string text)
    {
        if (!text.Contains('&'))
            return text;
        foreach (var (entity, replacement) in NamedEntities)
            text = text.Replace(entity, replacement, StringComparison.Ordinal);
        text = NumericReference().Replace(text, match =>
        {
            var digits = match.Groups[1].Value;
            var hex = digits.StartsWith('x') || digits.StartsWith('X');
            return uint.TryParse(hex ? digits[1..] : digits, hex ? NumberStyles.AllowHexSpecifier : NumberStyles.None,
                    CultureInfo.InvariantCulture, out var codePoint) && Rune.TryCreate(codePoint, out var rune)
                ? rune.ToString()
                : match.Value;
        });
        return text.Replace("&amp;", "&", StringComparison.Ordinal);
    }
}
