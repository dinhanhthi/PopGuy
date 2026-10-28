using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Speak.CloudTts;
using PopGuy.Tests.Support;

namespace PopGuy.Tests.Core;

// Public contract and secrets: the cloud TTS request shapes (macOS OpenAITTSProvider / GoogleCloudTTSProvider /
// AzureTTSProvider, spec-4 §2.2-2.4), Google's base64 audio, SSML escaping of the untrusted selection, the Azure region
// check before any request (the key never goes to a host the region names) and the empty/malformed audio errors.
public sealed class CloudTtsTests
{
    private const string Key = "sk-test-key-123456";
    private static readonly byte[] Audio = Encoding.UTF8.GetBytes("ID3-mp3-bytes");

    private static ITtsProvider Make(string provider, HttpMessageHandler handler)
    {
        var http = new ProviderHttp(handler);
        return provider switch
        {
            "openai" => new OpenAITtsProvider(http),
            "google" => new GoogleCloudTtsProvider(http),
            _ => new AzureTtsProvider(http),
        };
    }

    private static Task<byte[]> SynthesizeAsync(
        ITtsProvider provider, string text, string voice, string? region = null, double? speed = 0.572,
        double? pitch = 1.5) =>
        provider.SynthesizeAsync(
            new TtsSynthesisRequest(text, voice, "fr-FR", speed, pitch, new TtsProviderConfig { Region = region }),
            Key, TestContext.Current.CancellationToken);

    [Theory]
    [InlineData("openai", "alloy",
        "https://api.openai.com/v1/audio/speech",
        "Authorization=Bearer " + Key + "|Content-Type=application/json",
        """{"model":"gpt-4o-mini-tts","input":"Bonjour","voice":"alloy","response_format":"mp3","speed":0.572}""")]
    [InlineData("google", "fr-FR-Neural2-F",
        "https://texttospeech.googleapis.com/v1/text:synthesize?key=" + Key,
        "Content-Type=application/json",
        """{"input":{"text":"Bonjour"},"voice":{"languageCode":"fr-FR","name":"fr-FR-Neural2-F"},"audioConfig":{"audioEncoding":"MP3","speakingRate":0.572,"pitch":7}}""")]
    [InlineData("google", "fr-FR-Chirp3-HD-Kore",
        "https://texttospeech.googleapis.com/v1/text:synthesize?key=" + Key,
        "Content-Type=application/json",
        """{"input":{"text":"Bonjour"},"voice":{"languageCode":"fr-FR","name":"fr-FR-Chirp3-HD-Kore"},"audioConfig":{"audioEncoding":"MP3","speakingRate":0.572}}""")]
    [InlineData("azure", "fr-FR-DeniseNeural",
        "https://westeurope.tts.speech.microsoft.com/cognitiveservices/v1",
        "Ocp-Apim-Subscription-Key=" + Key + "|Content-Type=application/ssml+xml"
            + "|X-Microsoft-OutputFormat=audio-24khz-48kbitrate-mono-mp3|User-Agent=PopGuy",
        "<speak version='1.0' xml:lang='fr-FR'><voice name='fr-FR-DeniseNeural'>"
            + "<prosody rate='-42.8%' pitch='+7.0st'>Bonjour</prosody></voice></speak>")]
    public async Task SynthesisSendsTheProviderRequestAndReturnsTheAudio(
        string provider, string voice, string url, string headers, string body)
    {
        var response = provider == "google"
            ? $$"""{"audioContent":"{{Convert.ToBase64String(Audio)}}"}"""
            : Encoding.UTF8.GetString(Audio);
        var handler = new FakeHttpHandler(HttpStatusCode.OK, response);

        var audio = await SynthesizeAsync(Make(provider, handler), "Bonjour", voice, region: "westeurope");

        Assert.Equal(Audio, audio);
        var request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal(url, request.Uri!.AbsoluteUri);
        foreach (var header in headers.Split('|'))
        {
            var (name, value) = (header[..header.IndexOf('=')], header[(header.IndexOf('=') + 1)..]);
            Assert.Equal(value, request.Headers[name]);
        }
        if (provider == "azure")
            Assert.Equal(body, request.Body);
        else
            Assert.True(JsonNode.DeepEquals(JsonNode.Parse(body), JsonNode.Parse(request.Body!)), request.Body);
        if (provider == "openai")
            Assert.Contains("\"speed\":0.572}", request.Body); // short decimal: gpt-4o-mini-tts rejects > 16 places
    }

    [Fact]
    public async Task AzureEscapesTheTextSoTheSelectionCannotInjectSsml()
    {
        var handler = new FakeHttpHandler(HttpStatusCode.OK, "mp3");

        await SynthesizeAsync(
            Make("azure", handler), """&amp;<break time='9s'/>"x">""", "en-US-JennyNeural", "eastus",
            speed: null, pitch: null);

        Assert.Equal(
            "<speak version='1.0' xml:lang='fr-FR'><voice name='en-US-JennyNeural'>"
                + "&amp;amp;&lt;break time=&apos;9s&apos;/&gt;&quot;x&quot;&gt;</voice></speak>",
            Assert.Single(handler.Requests).Body);
    }

    [Theory]
    [InlineData("azure", null, HttpStatusCode.OK, "mp3", ProviderErrorKind.MissingOption)]
    [InlineData("azure", "", HttpStatusCode.OK, "mp3", ProviderErrorKind.MissingOption)]
    [InlineData("azure", "East US", HttpStatusCode.OK, "mp3", ProviderErrorKind.MissingOption)]
    [InlineData("azure", "evil.example/x?", HttpStatusCode.OK, "mp3", ProviderErrorKind.MissingOption)]
    [InlineData("azure", "eastus", HttpStatusCode.OK, "", ProviderErrorKind.DecodingFailed)]
    [InlineData("openai", null, HttpStatusCode.OK, "", ProviderErrorKind.DecodingFailed)]
    [InlineData("google", null, HttpStatusCode.OK, "{}", ProviderErrorKind.DecodingFailed)]
    [InlineData("google", null, HttpStatusCode.OK, """{"audioContent":"not base64!"}""", ProviderErrorKind.DecodingFailed)]
    [InlineData("google", null, HttpStatusCode.BadRequest, "{\"error\":\"bad key=" + Key + "\"}", ProviderErrorKind.Http)]
    public async Task FailuresThrowTheProviderErrorWithoutTheKey(
        string provider, string? region, HttpStatusCode status, string response, ProviderErrorKind kind)
    {
        var handler = new FakeHttpHandler(status, response);

        var error = await Assert.ThrowsAsync<ProviderError>(
            () => SynthesizeAsync(Make(provider, handler), "Hello", "voice", region));

        Assert.Equal(kind, error.Kind);
        Assert.DoesNotContain(Key, error.Message);
        if (kind == ProviderErrorKind.MissingOption)
        {
            Assert.Equal("Missing option: Azure region", error.Message);
            Assert.Empty(handler.Requests);
        }
    }
}
