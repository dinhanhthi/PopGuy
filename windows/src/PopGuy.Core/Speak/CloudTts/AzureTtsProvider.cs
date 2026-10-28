using System.Globalization;
using System.Net.Http.Headers;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Speak.CloudTts;

/// <summary>
/// Azure Speech (macOS AzureTTSProvider.swift, spec-4 §2.4).
/// <list type="bullet">
/// <item><c>POST https://&lt;region&gt;.tts.speech.microsoft.com/cognitiveservices/v1</c> with
/// <c>Ocp-Apim-Subscription-Key</c>, <c>Content-Type: application/ssml+xml</c>,
/// <c>X-Microsoft-OutputFormat: audio-24khz-48kbitrate-mono-mp3</c> and <c>User-Agent: PopGuy</c>; the response is
/// raw MP3.</item>
/// <item>The body is SSML: <c>&lt;speak&gt;&lt;voice&gt;</c>, with <c>&lt;prosody rate pitch&gt;</c> when a speed or
/// pitch is given. The text (untrusted) and the attribute values are XML-escaped, so a selection cannot inject SSML.</item>
/// <item>A region that is not a plain host label (<see cref="TtsKeyValidator.IsAzureRegion"/>) throws MissingOption
/// before any request, so the key never goes to a host the region names.</item>
/// </list>
/// </summary>
public sealed class AzureTtsProvider(ProviderHttp? http = null) : ITtsProvider
{
    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public string DefaultVoice(string languageCode) => languageCode switch
    {
        "en-GB" => "en-GB-SoniaNeural",
        "fr-FR" => "fr-FR-DeniseNeural",
        "es-ES" => "es-ES-ElviraNeural",
        "de-DE" => "de-DE-KatjaNeural",
        _ => "en-US-JennyNeural",
    };

    public async Task<byte[]> SynthesizeAsync(TtsSynthesisRequest request, string apiKey, CancellationToken ct)
    {
        if (request.Config.Region is not { } region || !TtsKeyValidator.IsAzureRegion(region))
            throw ProviderError.MissingOption("Azure region");

        var message = new HttpRequestMessage(
            HttpMethod.Post, $"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1")
        {
            // No charset parameter, as on macOS.
            Content = new StringContent(Ssml(request), new MediaTypeHeaderValue("application/ssml+xml")),
        };
        message.Headers.TryAddWithoutValidation("Ocp-Apim-Subscription-Key", apiKey);
        message.Headers.TryAddWithoutValidation("X-Microsoft-OutputFormat", "audio-24khz-48kbitrate-mono-mp3");
        message.Headers.TryAddWithoutValidation("User-Agent", "PopGuy");
        return CloudTtsAudio.NonEmpty(await _http.SendBytesAsync(message, apiKey, ct));
    }

    private static string Ssml(TtsSynthesisRequest request)
    {
        var inner = XmlEscape(request.Text);
        if (request.Speed is not null || request.Pitch is not null)
        {
            var rate = request.Speed is { } speed ? $" rate='{Rate(speed)}'" : "";
            var pitch = request.Pitch is { } multiplier ? $" pitch='{Signed(CloudTtsAudio.Semitones(multiplier))}st'" : "";
            inner = $"<prosody{rate}{pitch}>{inner}</prosody>";
        }
        return $"<speak version='1.0' xml:lang='{XmlEscape(request.LanguageCode)}'>"
            + $"<voice name='{XmlEscape(request.Voice)}'>{inner}</voice></speak>";
    }

    /// <summary>The speed (clamped to 0.25-4.0) as a relative percentage, 1 place: 1.0 → +0.0%, 0.6 → -40.0%.</summary>
    private static string Rate(double speed) =>
        Signed(Math.Round((Math.Clamp(speed, 0.25, 4.0) - 1.0) * 100, 1, MidpointRounding.AwayFromZero) + 0.0) + "%";

    private static string Signed(double value) =>
        (value >= 0 ? "+" : "") + value.ToString("0.0", CultureInfo.InvariantCulture);

    /// <summary>The five XML special characters, <c>&amp;</c> first so no entity is escaped twice.</summary>
    private static string XmlEscape(string text) => text
        .Replace("&", "&amp;", StringComparison.Ordinal)
        .Replace("<", "&lt;", StringComparison.Ordinal)
        .Replace(">", "&gt;", StringComparison.Ordinal)
        .Replace("\"", "&quot;", StringComparison.Ordinal)
        .Replace("'", "&apos;", StringComparison.Ordinal);
}
