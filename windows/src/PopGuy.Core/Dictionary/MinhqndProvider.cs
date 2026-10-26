using System.Text.Json;
using System.Text.RegularExpressions;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Dictionaries;

/// <summary>
/// Vietnamese-first lookups (VI / EN / ZH) through dict.minhqnd.com (macOS MinhqndDictionaryProvider.swift, spec-4 §3.5).
/// <list type="bullet">
/// <item><c>GET https://dict.minhqnd.com/api/v1/lookup?word=&lt;term&gt;[&amp;lang=&lt;source&gt;][&amp;def_lang=&lt;definition&gt;]</c>,
/// values escaped.</item>
/// <item>Reads <c>{exists, word, results: [{lang_code, lang_name, audio, meanings: [{definition, example, pos, links}],
/// pronunciations: [{ipa, region}], relations: [{related_word, relation_type}]}]}</c> leniently: a value of another
/// shape reads as absent. <c>exists</c> not true, or no results, is NotFound.</item>
/// <item>The only source with pronunciation audio: see <see cref="ResolveAudioUrl"/>.</item>
/// </list>
/// </summary>
public sealed partial class MinhqndProvider(ProviderHttp? http = null) : IDictionaryProvider
{
    private const string BaseUrl = "https://dict.minhqnd.com";
    private const string SourceName = "minhqnd";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public async Task<DictionaryEntry> LookupAsync(
        string term, string? sourceLanguage, string? definitionLanguage, CancellationToken ct)
    {
        var trimmed = term.Trim();
        if (trimmed.Length == 0)
            throw DictionaryLookupException.NotFound();
        var query = $"word={Uri.EscapeDataString(trimmed)}";
        if (!string.IsNullOrEmpty(sourceLanguage))
            query += $"&lang={Uri.EscapeDataString(sourceLanguage)}";
        if (!string.IsNullOrEmpty(definitionLanguage))
            query += $"&def_lang={Uri.EscapeDataString(definitionLanguage)}";

        JsonElement? root = await DictionaryHttp.GetObjectAsync(
            _http, new Uri($"{BaseUrl}/api/v1/lookup?{query}"), rateLimited: false, ct);

        var results = root.Get("results").Items().Where(r => r.ValueKind == JsonValueKind.Object).ToList();
        if (root.Get("exists") is not { ValueKind: JsonValueKind.True } || results.Count == 0)
            throw DictionaryLookupException.NotFound();
        var headword = root.Get("word").String() ?? trimmed;
        return new DictionaryEntry(headword, results.Select(r => MapResult(r, headword)).ToList(), SourceName);
    }

    private static LexicalEntry MapResult(JsonElement? result, string headword)
    {
        var relationSynonyms = result.Get("relations").Items()
            .Select(r => (JsonElement?)r)
            .Where(r => IsSynonymRelation(r.Get("relation_type").String()))
            .Select(r => r.Get("related_word").String())
            .OfType<string>().Where(w => w.Length > 0)
            .ToList();

        var meanings = result.Get("meanings").Items().Select(m => (JsonElement?)m).ToList();
        var senses = meanings
            .Where(m => !string.IsNullOrEmpty(m.Get("definition").String()))
            .Select(m => new Sense(
                m.Get("definition").String()!,
                m.Get("example").String() is { Length: > 0 } example ? [example] : [],
                [.. relationSynonyms, .. m.Get("links").Strings()]))
            .ToList();

        var pronunciations = result.Get("pronunciations").Items()
            .Select(p => (JsonElement?)p)
            .Where(p => !string.IsNullOrEmpty(p.Get("ipa").String()))
            .Select(p => new Pronunciation(
                p.Get("ipa").String()!, p.Get("region").String() is { Length: > 0 } region ? [region] : []))
            .ToList();

        var langCode = result.Get("lang_code").String();
        return new LexicalEntry(
            result.Get("lang_name").String() ?? langCode,
            meanings.Select(m => m.Get("pos").String()).FirstOrDefault(pos => !string.IsNullOrEmpty(pos)),
            pronunciations, senses,
            ResolveAudioUrl(result.Get("audio").String(), langCode, headword));
    }

    /// <summary>
    /// The pronunciation URL of a result, https only. <paramref name="audio"/> is untrusted: an absolute https URL is
    /// kept, a path is resolved against minhqnd, and any other scheme (http, file, data, javascript...) gives null.
    /// Without audio, minhqnd's TTS URL for the headword, its query values escaped so a crafted value cannot add
    /// parameters. The scheme is detected on the text, not by Uri: on macOS and Linux Uri reads "/path" as a file URL.
    /// </summary>
    internal static string? ResolveAudioUrl(string? audio, string? langCode, string headword)
    {
        if (audio?.Trim() is { Length: > 0 } trimmed)
        {
            string candidate;
            if (trimmed.StartsWith("https://", StringComparison.Ordinal))
                candidate = trimmed;
            else if (ExplicitScheme().IsMatch(trimmed))
                return null;
            else
                candidate = trimmed.StartsWith('/') ? BaseUrl + trimmed : $"{BaseUrl}/{trimmed}";
            return Uri.TryCreate(candidate, UriKind.Absolute, out var url) && url.Scheme == Uri.UriSchemeHttps
                ? candidate
                : null;
        }
        if (string.IsNullOrEmpty(langCode))
            return null;
        return $"{BaseUrl}/api/v1/tts?word={Uri.EscapeDataString(headword)}&lang={Uri.EscapeDataString(langCode)}";
    }

    /// <summary>"synonym", or a Vietnamese label containing "đồng nghĩa" (compared composed, as Swift strings are).</summary>
    private static bool IsSynonymRelation(string? type)
    {
        if (type is null)
            return false;
        var lowered = type.Normalize().ToLowerInvariant();
        return lowered == "synonym" || lowered.Contains("đồng nghĩa", StringComparison.Ordinal);
    }

    // RFC 3986 scheme followed by ":".
    [GeneratedRegex("^[A-Za-z][A-Za-z0-9+.-]*:")]
    private static partial Regex ExplicitScheme();
}
