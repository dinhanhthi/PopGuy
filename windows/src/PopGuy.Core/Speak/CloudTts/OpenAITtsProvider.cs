using System.Text.Json.Nodes;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Speak.CloudTts;

/// <summary>
/// OpenAI speech (macOS OpenAITTSProvider.swift, spec-4 §2.2).
/// <list type="bullet">
/// <item><c>POST https://api.openai.com/v1/audio/speech</c> with <c>Authorization: Bearer &lt;key&gt;</c> and a JSON body
/// <c>{model, input, voice, response_format: "mp3", speed?}</c>; the response is raw MP3.</item>
/// <item>Voices are multilingual: one default voice, the language is unused. No pitch parameter.</item>
/// </list>
/// </summary>
public sealed class OpenAITtsProvider(ProviderHttp? http = null) : ITtsProvider
{
    public const string DefaultModel = "gpt-4o-mini-tts";

    private static readonly Uri Endpoint = new("https://api.openai.com/v1/audio/speech");

    private readonly ProviderHttp _http = http ?? ProviderHttp.Shared;

    public string DefaultVoice(string languageCode) => "alloy";

    public async Task<byte[]> SynthesizeAsync(TtsSynthesisRequest request, string apiKey, CancellationToken ct)
    {
        var body = new JsonObject
        {
            ["model"] = request.Config.Model ?? DefaultModel,
            ["input"] = request.Text,
            ["voice"] = request.Voice,
            ["response_format"] = "mp3",
        };
        // Rounded to 3 places so the JSON number stays short: gpt-4o-mini-tts rejects more than 16 decimals.
        if (request.Speed is { } speed)
            body["speed"] = Math.Round(Math.Clamp(speed, 0.25, 4.0), 3, MidpointRounding.AwayFromZero);

        var message = new HttpRequestMessage(HttpMethod.Post, Endpoint) { Content = ProviderJson.Content(body) };
        message.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiKey}");
        return CloudTtsAudio.NonEmpty(await _http.SendBytesAsync(message, apiKey, ct));
    }
}
