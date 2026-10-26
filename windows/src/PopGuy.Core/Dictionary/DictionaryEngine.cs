using System.Collections.Concurrent;
using System.Text.Json;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Settings;

namespace PopGuy.Core.Dictionaries;

/// <summary>
/// Dictionary lookups through one provider or all of them (macOS DictionaryEngine.swift, spec-4 §3.4).
/// <para>
/// A provider takes part when the factory returns one for its kind. Windows has no macOS Dictionary (Dictionary
/// Services), so <see cref="DictionaryProviderKind.MacOSBuiltin"/> never does; Babylon does while a .bgl file is enabled.
/// </para>
/// UNTRUSTED DATA: the looked-up term is never logged, nor put in an error.
/// </summary>
public sealed class DictionaryEngine
{
    private readonly Func<DictionaryProviderKind, IDictionaryProvider?> _providers;

    /// <param name="providers">The provider for a kind; null when Windows has none. Default: the online providers.</param>
    public DictionaryEngine(Func<DictionaryProviderKind, IDictionaryProvider?>? providers = null) =>
        _providers = providers ?? DefaultProviders(() => []);

    /// <summary>
    /// minhqnd and Free Dictionary API, plus Babylon over <paramref name="babylonDictionaries"/> (read at each lookup, e.g.
    /// from the settings), which takes part only while one of them is enabled (spec-4 §3.2).
    /// </summary>
    public static Func<DictionaryProviderKind, IDictionaryProvider?> DefaultProviders(
        Func<IReadOnlyList<BabylonDictionary>> babylonDictionaries, ProviderHttp? http = null,
        BabylonIndexCache? babylonIndex = null)
    {
        http ??= ProviderHttp.Shared;
        IDictionaryProvider minhqnd = new MinhqndProvider(http), free = new FreeDictionaryProvider(http);
        return kind => kind switch
        {
            DictionaryProviderKind.Minhqnd => minhqnd,
            DictionaryProviderKind.FreeDictionaryApi => free,
            DictionaryProviderKind.BabylonBgl when babylonDictionaries() is var files && files.Any(f => f.IsEnabled) =>
                new BabylonProvider(files, babylonIndex ?? BabylonIndexCache.Shared),
            _ => null,
        };
    }

    /// <summary>A custom Dictionary action: only <c>config.Provider</c>. A provider Windows lacks finds nothing.</summary>
    public Task<DictionaryEntry> LookupAsync(string term, DictionaryConfig config, CancellationToken ct = default) =>
        _providers(config.Provider) is { } provider
            ? provider.LookupAsync(term, null, config.DefinitionLanguage, ct)
            : Task.FromException<DictionaryEntry>(DictionaryLookupException.NotFound());

    /// <summary>
    /// The built-in Look up: every provider at once. Returns the successes in provider order (not completion order),
    /// hiding the others' errors; with none, throws the first error to arrive, else NotFound. A blank term finds nothing.
    /// </summary>
    public async Task<IReadOnlyList<DictionaryProviderResult>> LookupAllAsync(
        string term, DictionaryConfig config, CancellationToken ct = default)
    {
        var trimmed = term.Trim();
        if (trimmed.Length == 0)
            throw DictionaryLookupException.NotFound();

        var failures = new ConcurrentQueue<DictionaryLookupException>();
        var lookups = Enum.GetValues<DictionaryProviderKind>()
            .Select(kind => (Kind: kind, Provider: _providers(kind)))
            .Where(p => p.Provider is not null)
            .Select(async p =>
            {
                try
                {
                    var entry = await p.Provider!.LookupAsync(trimmed, null, config.DefinitionLanguage, ct);
                    return new DictionaryProviderResult(p.Kind, entry);
                }
                catch (DictionaryLookupException error)
                {
                    if (error.Kind != DictionaryLookupErrorKind.NotFound)
                        failures.Enqueue(error);
                }
                catch (Exception error) when (!ct.IsCancellationRequested)
                {
                    failures.Enqueue(DictionaryLookupException.Network(error.Message));
                }
                return null;
            })
            .ToList();

        var results = (await Task.WhenAll(lookups)).OfType<DictionaryProviderResult>().ToList();
        if (results.Count > 0)
            return results;
        throw failures.TryPeek(out var first) ? first : DictionaryLookupException.NotFound();
    }
}

/// <summary>The GET both online providers make: 8 s, no cookies, HTTP and JSON failures mapped to typed errors.</summary>
internal static class DictionaryHttp
{
    /// <summary>The toolbar waits on the lookup, so far shorter than the AI providers' timeouts (macOS parity).</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(8);

    /// <summary>
    /// The response's root object. 404 is NotFound, 429 RateLimited when the source has a rate limit, any other
    /// failure Network; a body that is not a JSON object is a Decoding error. The body is never quoted in an error.
    /// </summary>
    public static async Task<JsonElement> GetObjectAsync(ProviderHttp http, Uri url, bool rateLimited, CancellationToken ct)
    {
        string body;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(Timeout);
        try
        {
            body = await http.SendAsync(new HttpRequestMessage(HttpMethod.Get, url), apiKey: null, timeout.Token);
        }
        catch (ProviderError error) when (error.Kind == ProviderErrorKind.Http)
        {
            throw error.StatusCode switch
            {
                404 => DictionaryLookupException.NotFound(),
                429 when rateLimited => DictionaryLookupException.RateLimited(),
                var status => DictionaryLookupException.Network($"HTTP {status}"),
            };
        }
        catch (ProviderError error)
        {
            throw DictionaryLookupException.Network(error.Message);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw DictionaryLookupException.Network(ProviderError.Transport("The request timed out.").Message);
        }
        return ProviderJson.Parse(body) is { ValueKind: JsonValueKind.Object } root
            ? root
            : throw DictionaryLookupException.Decoding("invalid JSON");
    }

    /// <summary>The non-empty strings of a JSON array; anything else reads as none.</summary>
    public static List<string> Strings(this JsonElement? array) =>
        array.Items().Select(item => ((JsonElement?)item).String()).OfType<string>().Where(s => s.Length > 0).ToList();
}
