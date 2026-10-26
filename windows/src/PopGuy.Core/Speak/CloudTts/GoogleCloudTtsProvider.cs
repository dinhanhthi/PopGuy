using System.Text.Json.Nodes;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Speak.CloudTts;

/// <summary>
/// Google Cloud Text-to-Speech (macOS GoogleCloudTTSProvider.swift, spec-4 §2.3).
/// <list type="bullet">
/// <item><c>POST https://texttospeech.googleapis.com/v1/text:synthesize?key=&lt;key&gt;</c> with a JSON body
/// <c>{input{text}, voice{languageCode, name}, audioConfig{audioEncoding: "MP3", speakingRate?, pitch?}}</c>.</item>
/// <item>The response is <c>{audioContent: base64 MP3}</c>.</item>
/// <item>Voices are locale-bound. Chirp 3 HD voices reject <c>pitch</c> (HTTP 400), so it is omitted for them.</item>
/// </list>
/// The URL carries the key: it is never logged, and ProviderHttp redacts it from errors.
/// </summary>
public sealed class GoogleCloudTtsProvider(ProviderHttp? http = null) : ITtsProvider
{
    private const string Endpoint = "https://texttospeech.googleapis.com/v1/text:synthesize";

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public string DefaultVoice(string languageCode) => languageCode switch
    {
        "en-GB" => "en-GB-Neural2-A",
        "fr-FR" => "fr-FR-Neural2-F",
        "es-ES" => "es-ES-Neural2-A",
        "de-DE" => "de-DE-Neural2-G",
        _ => "en-US-Neural2-C",
    };

    public async Task<byte[]> SynthesizeAsync(TtsSynthesisRequest request, string apiKey, CancellationToken ct)
    {
        var audioConfig = new JsonObject { ["audioEncoding"] = "MP3" };
        if (request.Speed is { } speed)
            audioConfig["speakingRate"] = Math.Clamp(speed, 0.25, 4.0);
        // Semitones stay within Google's -20..+20 range: the multiplier is clamped to one octave each way.
        if (request.Pitch is { } pitch && !request.Voice.Contains("Chirp", StringComparison.Ordinal))
            audioConfig["pitch"] = CloudTtsAudio.Semitones(pitch);

        var body = new JsonObject
        {
            ["input"] = new JsonObject { ["text"] = request.Text },
            ["voice"] = new JsonObject { ["languageCode"] = request.LanguageCode, ["name"] = request.Voice },
            ["audioConfig"] = audioConfig,
        };
        var message = new HttpRequestMessage(HttpMethod.Post, $"{Endpoint}?key={Uri.EscapeDataString(apiKey)}")
        {
            Content = ProviderJson.Content(body),
        };

        var response = await _http.SendAsync(message, apiKey, ct);
        if (ProviderJson.Parse(response).Get("audioContent").String() is not { Length: > 0 } base64)
            throw ProviderError.DecodingFailed("missing audioContent");
        try
        {
            return Convert.FromBase64String(base64);
        }
        catch (FormatException)
        {
            throw ProviderError.DecodingFailed("invalid base64");
        }
    }
}
