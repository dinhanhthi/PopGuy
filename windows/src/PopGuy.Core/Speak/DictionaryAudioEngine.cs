using System.Text.Json;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Speak;

/// <summary>
/// Pronunciation audio for the dictionary Listen button (macOS DictionaryAudioEngine.swift, spec-4 §1.7): the audio URL
/// of an entry, or a word's recording from the Free Dictionary pronunciation API (api.dictionaryapi.dev). macOS streams
/// the URL; the Windows player takes bytes, so the audio is downloaded (capped) and <see cref="SpeakCoordinator"/>
/// plays it as mp3 (both sources serve mp3).
/// <para>
/// UNTRUSTED DATA: an audio URL from a dictionary response is fetched only when its scheme is exactly https (never
/// http, file, data...); redirects are not followed. Every failure returns null, so the caller falls back to speech.
/// </para>
/// </summary>
public sealed class DictionaryAudioEngine(ProviderHttp? http = null)
{
    /// <summary>Per request: the JSON lookup and each download (macOS parity for the lookup).</summary>
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(4);

    /// <summary>A pronunciation is a few kilobytes; anything past this is refused.</summary>
    public const int MaxAudioBytes = 2 * 1024 * 1024;

    // Always English: the accent only picks the recording.
    private const string WordApi = "https://api.dictionaryapi.dev/api/v2/entries/en/";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    /// <summary>The audio at <paramref name="url"/>; null when it is not https, fails, is empty or over the cap.</summary>
    public async Task<byte[]?> FetchUrlAsync(string url, CancellationToken ct)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            return null;
        try
        {
            var audio = await WithTimeoutAsync(
                t => _http.SendBytesAsync(new HttpRequestMessage(HttpMethod.Get, uri), null, t, MaxAudioBytes), ct);
            return audio.Length > 0 ? audio : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>
    /// The recording of <paramref name="word"/> (trimmed, lowercased) for <paramref name="variant"/> ("us", "uk"), else
    /// its first recording; null when there is none, or on any failure.
    /// </summary>
    public async Task<byte[]?> FetchWordAsync(string word, string variant, CancellationToken ct)
    {
        var trimmed = word.Trim().ToLowerInvariant();
        if (trimmed.Length == 0)
            return null;
        string json;
        try
        {
            var url = new Uri(WordApi + Uri.EscapeDataString(trimmed));
            json = await WithTimeoutAsync(t => _http.SendAsync(new HttpRequestMessage(HttpMethod.Get, url), null, t), ct);
        }
        catch (Exception)
        {
            return null;
        }
        return PickAudio(ProviderJson.Parse(json), variant) is { } audio ? await FetchUrlAsync(audio, ct) : null;
    }

    /// <summary>
    /// Across every phonetic of every entry (<c>[{phonetics: [{audio}]}]</c>; other fields, the IPA included, are not
    /// read): the first audio containing "-&lt;variant&gt;.mp3", else the first non-empty one.
    /// </summary>
    private static string? PickAudio(JsonElement? root, string variant)
    {
        var audios = root.Items()
            .SelectMany(entry => ((JsonElement?)entry).Get("phonetics").Items())
            .Select(phonetic => ((JsonElement?)phonetic).Get("audio").String())
            .OfType<string>().Where(audio => audio.Length > 0)
            .ToList();
        return audios.FirstOrDefault(audio => audio.Contains($"-{variant}.mp3", StringComparison.Ordinal))
            ?? audios.FirstOrDefault();
    }

    private static async Task<T> WithTimeoutAsync<T>(Func<CancellationToken, Task<T>> send, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(RequestTimeout);
        return await send(timeout.Token);
    }
}
