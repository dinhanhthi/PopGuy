using PopGuy.Core.Actions;
using PopGuy.Core.Providers;

namespace PopGuy.Tests.Core;

// Contract: the Providers page's feedback (SettingsView.swift maskedKeyPreview / mapVerifyOutcome /
// mapModelCheckOutcome / validationMessage, spec-3 §1.12 and §5.2), the CLI path rejection, and the TTS key check's
// request per provider. Pure: no request is sent.
public sealed class ProviderFeedbackTests
{
    private const string Key = "pg-test-7f3a9c1e5b2d";

    // MARK: - Masked preview

    [Theory]
    [InlineData(null, null)]
    [InlineData("", null)]
    [InlineData("ab", "ab…")]
    [InlineData("abcdefgh", "abcd…")]
    [InlineData("0123456789012345678901", "0123…")] // 22 characters: still the short form
    [InlineData("sk-proj-sDvgXXXXXXXXXXXXXaoW2WRL8sA", "sk-proj-sDvg…aoW2WRL8sA")]
    public void MaskedPreviewShowsHeadAndTailOnlyForLongKeys(string? key, string? expected) =>
        Assert.Equal(expected, ProviderFeedback.MaskedPreview(key));

    // MARK: - Verify outcome

    public static TheoryData<Exception?, bool, bool, VerifyOutcome> VerifyCases => new()
    {
        { null, false, false, VerifyOutcome.NoKey },
        { null, false, true, VerifyOutcome.NoKey },
        { null, true, true, VerifyOutcome.NoEndpoint },
        { null, true, false, VerifyOutcome.Valid },
        { ProviderError.Http(400, null), true, false, VerifyOutcome.Invalid },
        { ProviderError.Http(401, null), true, false, VerifyOutcome.Invalid },
        { ProviderError.Http(403, null), true, false, VerifyOutcome.Invalid },
        { ProviderError.Http(404, null), true, false, VerifyOutcome.Unreachable },
        { ProviderError.Http(500, null), true, false, VerifyOutcome.Unreachable },
        { ProviderError.Transport("offline"), true, false, VerifyOutcome.Unreachable },
        { new InvalidOperationException(), true, false, VerifyOutcome.Unreachable },
    };

    [Theory]
    [MemberData(nameof(VerifyCases))]
    public void VerifyOutcomeMapping(Exception? error, bool hasKey, bool endpointMissing, VerifyOutcome expected) =>
        Assert.Equal(expected, ProviderFeedback.MapVerifyOutcome(error, hasKey, endpointMissing));

    [Theory]
    [InlineData(400, VerifyOutcome.Invalid)]
    [InlineData(401, VerifyOutcome.Invalid)]
    [InlineData(403, VerifyOutcome.Invalid)]
    [InlineData(404, VerifyOutcome.Invalid)]
    [InlineData(429, VerifyOutcome.Unreachable)]
    public void ModelCheckTreatsAnUnknownModelAsInvalid(int status, VerifyOutcome expected) =>
        Assert.Equal(expected, ProviderFeedback.MapModelCheckOutcome(ProviderError.Http(status, null), customEndpointMissing: false));

    [Fact]
    public void ModelCheckOutcomeWithoutError()
    {
        Assert.Equal(VerifyOutcome.Valid, ProviderFeedback.MapModelCheckOutcome(null, customEndpointMissing: false));
        Assert.Equal(VerifyOutcome.NoEndpoint, ProviderFeedback.MapModelCheckOutcome(null, customEndpointMissing: true));
    }

    [Theory]
    [InlineData(VerifyOutcome.Valid, "Key is valid")]
    [InlineData(VerifyOutcome.Invalid, "Key invalid")]
    [InlineData(VerifyOutcome.Unreachable, "Couldn't reach provider")]
    [InlineData(VerifyOutcome.NoEndpoint, "Set the base URL first")]
    [InlineData(VerifyOutcome.NoKey, "No key saved")]
    public void VerifyText(VerifyOutcome outcome, string expected) =>
        Assert.Equal(expected, ProviderFeedback.VerifyText(outcome));

    // MARK: - Save failure message

    public static TheoryData<Exception, string> MessageCases => new()
    {
        { ProviderError.Http(400, null), "Invalid API key. Please check and try again." },
        { ProviderError.Http(401, null), "Invalid API key. Please check and try again." },
        { ProviderError.Http(403, null), "Invalid API key. Please check and try again." },
        { ProviderError.Http(500, null), "Could not verify your API key (HTTP 500)." },
        { ProviderError.Transport("offline"), "Could not connect to the server. Check your network connection and try again." },
        { new HttpRequestException(), "Could not connect to the server. Check your network connection and try again." },
        { ProviderError.MissingOption("Azure region"), "Could not verify your API key. Please try again." },
        { new InvalidOperationException(), "Could not verify your API key. Please try again." },
    };

    [Theory]
    [MemberData(nameof(MessageCases))]
    public void ValidationMessage(Exception error, string expected) =>
        Assert.Equal(expected, ProviderFeedback.ValidationMessage(error));

    // MARK: - CLI path

    [Theory]
    [InlineData(@"\\server\share\claude.exe", true)]
    [InlineData(@"  \\server\share\claude.exe", true)]
    [InlineData("//server/share/claude.exe", true)]
    [InlineData(@"\\?\C:\tools\claude.exe", true)]
    [InlineData(@"\\.\C:\tools\claude.exe", true)]
    [InlineData(@"C:\Users\me\AppData\Roaming\npm\claude.cmd", false)]
    [InlineData(@"~\AppData\Roaming\npm\claude.cmd", false)]
    [InlineData("", false)]
    public void CliPathRejectsNetworkAndDevicePaths(string path, bool rejected) =>
        Assert.Equal(rejected, ProviderFeedback.CliPathRejection(path) is not null);

    // MARK: - TTS key check

    [Fact]
    public void OpenAiTtsKeyCheckIsGetModelsWithBearer()
    {
        using var request = TtsKeyValidator.ValidationRequest(TtsProviderKind.OpenAiTts, Key, region: "ignored");

        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("https://api.openai.com/v1/models", request.RequestUri!.AbsoluteUri);
        Assert.Equal($"Bearer {Key}", request.Headers.GetValues("Authorization").Single());
    }

    [Fact]
    public void GoogleTtsKeyCheckListsVoicesWithTheKeyInTheQuery()
    {
        using var request = TtsKeyValidator.ValidationRequest(TtsProviderKind.GoogleCloudTts, "a b&c", region: null);

        Assert.Equal("https://texttospeech.googleapis.com/v1/voices?key=a%20b%26c", request.RequestUri!.AbsoluteUri);
    }

    [Fact]
    public void AzureKeyCheckListsVoicesInTheRegion()
    {
        using var request = TtsKeyValidator.ValidationRequest(TtsProviderKind.AzureTts, Key, "eastus");

        Assert.Equal("https://eastus.tts.speech.microsoft.com/cognitiveservices/voices/list", request.RequestUri!.AbsoluteUri);
        Assert.Equal(Key, request.Headers.GetValues("Ocp-Apim-Subscription-Key").Single());
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("evil.example.com/")]
    [InlineData("east us")]
    [InlineData("eastus@evil.example.com")]
    public void AzureKeyCheckRefusesARegionThatIsNotAHostLabel(string? region)
    {
        var error = Assert.Throws<ProviderError>(() => TtsKeyValidator.ValidationRequest(TtsProviderKind.AzureTts, Key, region));
        Assert.Equal(ProviderErrorKind.MissingOption, error.Kind);
    }
}
