using System.Text.Json;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Dictionaries;

/// <summary>
/// EN/FR/ES definitions from Wiktionary through freedictionaryapi.com (macOS FreeDictionaryAPIProvider.swift, spec-4
/// §3.5). Not the pronunciation API (api.dictionaryapi.dev, see DictionaryAudioEngine): this source has no audio.
/// <list type="bullet">
/// <item><c>GET https://freedictionaryapi.com/api/v1/entries/&lt;language&gt;/&lt;term&gt;</c>, each an escaped path
/// segment; the language is the source language, else the definition language, else "en".</item>
/// <item>Reads <c>{word, entries: [{language: {code, name}, partOfSpeech, pronunciations: [{text, tags}],
/// senses: [{definition, examples, synonyms}], synonyms}]}</c> leniently: a value of another shape reads as absent.
/// No entries is NotFound (the API answers 200 with none for an unknown word).</item>
/// </list>
/// </summary>
public sealed class FreeDictionaryProvider(ProviderHttp? http = null) : IDictionaryProvider
{
    private const string BaseUrl = "https://freedictionaryapi.com/api/v1/entries";
    private const string SourceName = "Free Dictionary API";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public async Task<DictionaryEntry> LookupAsync(
        string term, string? sourceLanguage, string? definitionLanguage, CancellationToken ct)
    {
        var trimmed = term.Trim();
        if (trimmed.Length == 0)
            throw DictionaryLookupException.NotFound();
        var language = new[] { sourceLanguage?.Trim(), definitionLanguage?.Trim() }
            .FirstOrDefault(l => !string.IsNullOrEmpty(l)) ?? "en";

        var url = new Uri($"{BaseUrl}/{Uri.EscapeDataString(language)}/{Uri.EscapeDataString(trimmed)}");
        JsonElement? root = await DictionaryHttp.GetObjectAsync(_http, url, rateLimited: true, ct);

        var entries = root.Get("entries").Items().Where(e => e.ValueKind == JsonValueKind.Object)
            .Select(e => MapEntry(e)).ToList();
        if (entries.Count == 0)
            throw DictionaryLookupException.NotFound();
        return new DictionaryEntry(root.Get("word").String() ?? trimmed, entries, SourceName);
    }

    private static LexicalEntry MapEntry(JsonElement? entry)
    {
        var pronunciations = entry.Get("pronunciations").Items()
            .Select(p => (Text: ((JsonElement?)p).Get("text").String(), Tags: ((JsonElement?)p).Get("tags").Strings()))
            .Where(p => !string.IsNullOrEmpty(p.Text))
            .Select(p => new Pronunciation(p.Text!, p.Tags))
            .ToList();

        var entrySynonyms = entry.Get("synonyms").Strings();
        var senses = entry.Get("senses").Items()
            .Select(s => (JsonElement?)s)
            .Where(s => !string.IsNullOrEmpty(s.Get("definition").String()))
            .Select(s => new Sense(
                s.Get("definition").String()!, s.Get("examples").Strings(),
                [.. s.Get("synonyms").Strings(), .. entrySynonyms]))
            .ToList();

        var language = entry.Get("language");
        return new LexicalEntry(
            language.Get("name").String() ?? language.Get("code").String(), entry.Get("partOfSpeech").String(),
            pronunciations, senses, AudioUrl: null);
    }
}
