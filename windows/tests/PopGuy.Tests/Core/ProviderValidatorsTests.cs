using System.Net;
using System.Runtime.CompilerServices;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Providers.Cli;
using PopGuy.Tests.Support;

namespace PopGuy.Tests.Core;

// Contract: the Settings Verify checks (ProviderKeyValidatorTests.swift, ProviderModelValidatorTests.swift,
// CLIProviderValidatorTests.swift). The key check's request per provider (host, path, auth header), the model check's
// 1-token call and early returns, the CLI check's outcomes. Offline: a fake HTTP handler or stub adapters; no CLI is run.
public sealed class ProviderValidatorsTests : IDisposable
{
    private const string Key = "pg-test-7f3a9c1e5b2d";

    private readonly string _folder = Path.Combine(Path.GetTempPath(), "PopGuyTests-validators-" + Guid.NewGuid().ToString("N"));

    public ProviderValidatorsTests() => Directory.CreateDirectory(_folder);

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    private sealed record Call(string? SystemPrompt, string Input, string Model, ProviderOptions Options);

    /// <summary>Records every call, then yields <c>tokens</c> or throws <c>error</c> (before or inside the stream).</summary>
    private sealed class StubProvider(string[]? tokens = null, Exception? error = null, bool errorInStream = false) : IProvider
    {
        public List<Call> Calls { get; } = [];

        public IAsyncEnumerable<string> StreamAsync(
            string? systemPrompt, string input, string model, ProviderOptions options, CancellationToken ct = default)
        {
            Calls.Add(new Call(systemPrompt, input, model, options));
            if (error is not null && !errorInStream)
                throw error;
            return Tokens(ct);
        }

        private async IAsyncEnumerable<string> Tokens([EnumeratorCancellation] CancellationToken ct)
        {
            await Task.CompletedTask;
            if (error is not null)
                throw error;
            foreach (var token in tokens ?? ["Hi"])
                yield return token;
        }
    }

    private static ProviderFactory Factory(ProviderKind kind, IProvider provider)
    {
        var factory = new ProviderFactory();
        factory.Register(kind, _ => provider);
        return factory;
    }

    private static ShellEnvironment Shell(string path) => new(() => path, _ => null);

    // MARK: - ProviderKeyValidator: the request per provider

    [Theory]
    [InlineData(ProviderKind.OpenAi, null, "https://api.openai.com/v1/models")]
    [InlineData(ProviderKind.Glm, null, "https://api.z.ai/api/paas/v4/models")]
    [InlineData(ProviderKind.OpenRouter, null, "https://openrouter.ai/api/v1/models")]
    [InlineData(ProviderKind.Glm, "https://custom.glm.host/v4", "https://custom.glm.host/v4/models")]
    [InlineData(ProviderKind.Custom, "https://my-llm.example.com/v1", "https://my-llm.example.com/v1/models")]
    [InlineData(ProviderKind.Custom, "https://my-llm.example.com/v1/", "https://my-llm.example.com/v1/models")]
    public void OpenAiWireKeyCheckIsGetModelsWithBearer(ProviderKind kind, string? baseUrl, string expected)
    {
        using var request = ProviderKeyValidator.ValidationRequest(kind, Key, baseUrl is null ? null : new Uri(baseUrl))!;

        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal(expected, request.RequestUri!.AbsoluteUri);
        Assert.Equal($"Bearer {Key}", request.Headers.GetValues("Authorization").Single());
    }

    [Fact]
    public void GeminiKeyCheckUsesGoogApiKeyOnTheNativeHost()
    {
        // A caller URL is ignored: Gemini always uses its native API.
        using var request = ProviderKeyValidator.ValidationRequest(ProviderKind.Gemini, Key, new Uri("https://some.other.host/v1"))!;

        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("https://generativelanguage.googleapis.com/v1beta/models", request.RequestUri!.AbsoluteUri);
        Assert.Equal(Key, request.Headers.GetValues("x-goog-api-key").Single());
        Assert.False(request.Headers.Contains("Authorization"));
    }

    [Fact]
    public void AnthropicKeyCheckIsGetModelsWithApiKeyAndVersion()
    {
        using var request = ProviderKeyValidator.ValidationRequest(ProviderKind.Anthropic, Key, null)!;

        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("https://api.anthropic.com/v1/models", request.RequestUri!.AbsoluteUri);
        Assert.Equal(Key, request.Headers.GetValues("x-api-key").Single());
        Assert.Equal("2023-06-01", request.Headers.GetValues("anthropic-version").Single());
        Assert.False(request.Headers.Contains("Authorization"));
    }

    [Theory]
    [InlineData("deepl-key:fx", "https://api-free.deepl.com/v2/usage")]
    [InlineData("deepl-key", "https://api.deepl.com/v2/usage")]
    public void DeepLKeyCheckIsGetUsageOnTheKeysHost(string apiKey, string expected)
    {
        using var request = ProviderKeyValidator.ValidationRequest(ProviderKind.DeepL, apiKey, null)!;

        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal(expected, request.RequestUri!.AbsoluteUri);
        Assert.Equal($"DeepL-Auth-Key {apiKey}", request.Headers.GetValues("Authorization").Single());
    }

    [Fact]
    public void GoogleTranslateKeyCheckIsGetLanguagesWithTheEscapedKey()
    {
        using var request = ProviderKeyValidator.ValidationRequest(ProviderKind.GoogleTranslate, "a+b/c", null)!;

        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal(
            "https://translation.googleapis.com/language/translate/v2/languages?key=a%2Bb%2Fc", request.RequestUri!.AbsoluteUri);
        Assert.False(request.Headers.Contains("Authorization"));
    }

    [Theory]
    [InlineData(ProviderKind.Ollama)]
    [InlineData(ProviderKind.MlxLocal)]
    [InlineData(ProviderKind.ClaudeCli)]
    [InlineData(ProviderKind.CodexCli)]
    [InlineData(ProviderKind.GeminiCli)]
    [InlineData(ProviderKind.Custom)]
    public async Task KeylessKindsAndCustomWithoutEndpointSendNothing(ProviderKind kind)
    {
        var handler = new FakeHttpHandler(HttpStatusCode.Unauthorized, "");

        await ProviderKeyValidator.ValidateAsync(kind, Key, http: new ProviderHttp(handler), ct: TestContext.Current.CancellationToken);

        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task KeyCheckReturnsOnSuccess()
    {
        var handler = new FakeHttpHandler(HttpStatusCode.OK, """{"data":[]}""");

        await ProviderKeyValidator.ValidateAsync(
            ProviderKind.OpenAi, Key, http: new ProviderHttp(handler), ct: TestContext.Current.CancellationToken);

        Assert.Equal("https://api.openai.com/v1/models", Assert.Single(handler.Requests).Uri!.AbsoluteUri);
    }

    [Fact]
    public async Task InvalidKeyThrowsHttp401WithTheKeyRedacted()
    {
        var handler = new FakeHttpHandler(HttpStatusCode.Unauthorized, $$$"""{"error":{"message":"Incorrect API key provided: {{{Key}}}"}}""");

        var error = await Assert.ThrowsAsync<ProviderError>(() => ProviderKeyValidator.ValidateAsync(
            ProviderKind.OpenAi, Key, http: new ProviderHttp(handler), ct: TestContext.Current.CancellationToken));

        Assert.Equal(ProviderErrorKind.Http, error.Kind);
        Assert.Equal(401, error.StatusCode);
        Assert.DoesNotContain(Key, error.ToString());
    }

    [Fact]
    public async Task CustomEndpointOtherThanHttpIsATransportError()
    {
        var handler = new FakeHttpHandler(HttpStatusCode.OK, "");

        var error = await Assert.ThrowsAsync<ProviderError>(() => ProviderKeyValidator.ValidateAsync(
            ProviderKind.Custom, Key, new Uri("file:///etc/models"), new ProviderHttp(handler), TestContext.Current.CancellationToken));

        Assert.Equal(ProviderErrorKind.Transport, error.Kind);
        Assert.StartsWith("Transport error: Invalid base URL: ", error.Message);
        Assert.Empty(handler.Requests);
    }

    // MARK: - ProviderModelValidator

    [Fact]
    public async Task ModelCheckSendsOneTokenHiWithoutSystemPrompt()
    {
        var provider = new StubProvider();

        await ProviderModelValidator.ValidateAsync(
            ProviderKind.OpenAi, Key, "gpt-6-luna", Factory(ProviderKind.OpenAi, provider), ct: TestContext.Current.CancellationToken);

        var call = Assert.Single(provider.Calls);
        Assert.Equal(new Call(null, "Hi", "gpt-6-luna", new ProviderOptions { MaxTokens = 1 }), call);
    }

    [Fact]
    public async Task CleanFinishWithNoTokenIsASuccess()
    {
        var provider = new StubProvider(tokens: []);

        await ProviderModelValidator.ValidateAsync(
            ProviderKind.Anthropic, Key, "claude-sonnet-5-5", Factory(ProviderKind.Anthropic, provider),
            ct: TestContext.Current.CancellationToken);

        Assert.Equal("claude-sonnet-5-5", Assert.Single(provider.Calls).Model);
    }

    [Theory]
    [InlineData(404, false)]
    [InlineData(401, false)]
    [InlineData(404, true)]
    public async Task HttpErrorPropagates(int status, bool inStream)
    {
        var provider = new StubProvider(error: ProviderError.Http(status, "model not found"), errorInStream: inStream);

        var error = await Assert.ThrowsAsync<ProviderError>(() => ProviderModelValidator.ValidateAsync(
            ProviderKind.OpenAi, Key, "gpt-nonexistent", Factory(ProviderKind.OpenAi, provider),
            ct: TestContext.Current.CancellationToken));

        Assert.Equal(status, error.StatusCode);
    }

    [Fact]
    public async Task InStreamApiErrorPropagates()
    {
        var provider = new StubProvider(error: ProviderError.Api("model_not_found", "The model does not exist"), errorInStream: true);

        var error = await Assert.ThrowsAsync<ProviderError>(() => ProviderModelValidator.ValidateAsync(
            ProviderKind.OpenAi, Key, "gpt-bad", Factory(ProviderKind.OpenAi, provider), ct: TestContext.Current.CancellationToken));

        Assert.Equal(ProviderErrorKind.Api, error.Kind);
        Assert.Equal("API error (model_not_found): The model does not exist", error.Message);
    }

    // No model (translation), a 10-30 s CLI run, the local cache, no endpoint: the adapter is never created.
    [Theory]
    [InlineData(ProviderKind.DeepL)]
    [InlineData(ProviderKind.GoogleTranslate)]
    [InlineData(ProviderKind.ClaudeCli)]
    [InlineData(ProviderKind.CodexCli)]
    [InlineData(ProviderKind.GeminiCli)]
    [InlineData(ProviderKind.MlxLocal)]
    [InlineData(ProviderKind.Custom)]
    public async Task ModelCheckReturnsEarlyWithoutCreatingTheAdapter(ProviderKind kind)
    {
        var created = false;
        var factory = new ProviderFactory();
        factory.Register(kind, _ =>
        {
            created = true;
            return new StubProvider();
        });

        await ProviderModelValidator.ValidateAsync(kind, Key, "some-model", factory, ct: TestContext.Current.CancellationToken);

        Assert.False(created);
    }

    [Theory]
    [InlineData(ProviderKind.Gemini, "https://some.other.host/v1", null)]
    [InlineData(ProviderKind.OpenAi, null, null)]
    [InlineData(ProviderKind.Glm, null, ProviderFactory.GlmBaseUrl)]
    [InlineData(ProviderKind.Glm, "https://custom.glm.host/v4", "https://custom.glm.host/v4")]
    [InlineData(ProviderKind.OpenRouter, null, ProviderFactory.OpenRouterBaseUrl)]
    [InlineData(ProviderKind.Custom, "https://my-llm.example.com/v1", "https://my-llm.example.com/v1")]
    public async Task ModelCheckRoutesTheBaseUrl(ProviderKind kind, string? baseUrl, string? expected)
    {
        var provider = new StubProvider();

        await ProviderModelValidator.ValidateAsync(
            kind, Key, "m", Factory(kind, provider), baseUrl is null ? null : new Uri(baseUrl), TestContext.Current.CancellationToken);

        Assert.Equal(expected is null ? null : new Uri(expected), Assert.Single(provider.Calls).Options.BaseUrl);
    }

    [Fact]
    public async Task GeminiProductionAdapterSucceedsOnAStreamedToken()
    {
        var handler = new FakeHttpHandler(HttpStatusCode.OK, """data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}""" + "\n\n");

        await ProviderModelValidator.ValidateAsync(
            ProviderKind.Gemini, Key, "gemini-3.6-flash", new ProviderFactory(new ProviderHttp(handler)),
            ct: TestContext.Current.CancellationToken);

        var request = Assert.Single(handler.Requests);
        Assert.Equal("generativelanguage.googleapis.com", request.Uri!.Host);
        Assert.Contains("\"maxOutputTokens\":1", request.Body);
    }

    [Fact]
    public async Task GeminiProductionAdapter404ThrowsHttp404()
    {
        var handler = new FakeHttpHandler(HttpStatusCode.NotFound, """{"error":{"message":"model not found"}}""");

        var error = await Assert.ThrowsAsync<ProviderError>(() => ProviderModelValidator.ValidateAsync(
            ProviderKind.Gemini, Key, "gemini-nonexistent", new ProviderFactory(new ProviderHttp(handler)),
            ct: TestContext.Current.CancellationToken));

        Assert.Equal(ProviderErrorKind.Http, error.Kind);
        Assert.Equal(404, error.StatusCode);
    }

    // MARK: - CliProviderValidator

    [Fact]
    public async Task EmptyPathAndNoCliOnThePathIsNoPath()
    {
        var created = false;
        var factory = new ProviderFactory();
        factory.Register(ProviderKind.ClaudeCli, _ =>
        {
            created = true;
            return new StubProvider();
        });

        var outcome = await CliProviderValidator.ValidateAsync(
            ProviderKind.ClaudeCli, "   ", factory, Shell(_folder), TestContext.Current.CancellationToken);

        Assert.Equal(CliValidationOutcome.NoPath, outcome);
        Assert.False(created);
    }

    [Fact]
    public async Task EmptyPathWithTheCliOnThePathRunsIt()
    {
        File.WriteAllText(Path.Combine(_folder, "claude.exe"), "");
        var provider = new StubProvider(tokens: ["OK"]);

        var outcome = await CliProviderValidator.ValidateAsync(
            ProviderKind.ClaudeCli, "", Factory(ProviderKind.ClaudeCli, provider), Shell(_folder),
            TestContext.Current.CancellationToken);

        Assert.Equal(CliValidationOutcome.Working, outcome);
        Assert.Equal(new Call(null, CliProviderValidator.ProbeInput, "", new ProviderOptions()), Assert.Single(provider.Calls));
    }

    [Fact]
    public async Task OutputIsWorkingAndThePathIsPassedTrimmed()
    {
        var provider = new StubProvider(tokens: ["OK"]);

        var outcome = await CliProviderValidator.ValidateAsync(
            ProviderKind.ClaudeCli, @" C:\Tools\claude.exe ", Factory(ProviderKind.ClaudeCli, provider), Shell(""),
            TestContext.Current.CancellationToken);

        Assert.Equal(CliValidationOutcome.Working, outcome);
        Assert.Equal(@"C:\Tools\claude.exe", Assert.Single(provider.Calls).Options.ExecutablePath);
    }

    [Theory]
    [InlineData(ProviderKind.CodexCli, new[] { "   ", "\n" })]
    [InlineData(ProviderKind.GeminiCli, new string[0])]
    public async Task BlankOrNoOutputFails(ProviderKind kind, string[] tokens)
    {
        var outcome = await CliProviderValidator.ValidateAsync(
            kind, @"C:\Tools\cli.exe", Factory(kind, new StubProvider(tokens)), Shell(""), TestContext.Current.CancellationToken);

        Assert.Equal(CliValidationOutcome.Failed("The CLI ran but returned no output."), outcome);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AThrowingCliFailsWithTheErrorMessage(bool inStream)
    {
        var provider = new StubProvider(
            error: ProviderError.Transport(@"CLI not found at C:\x.exe. Set the path in Settings."), errorInStream: inStream);

        var outcome = await CliProviderValidator.ValidateAsync(
            ProviderKind.ClaudeCli, @"C:\x.exe", Factory(ProviderKind.ClaudeCli, provider), Shell(""),
            TestContext.Current.CancellationToken);

        Assert.Equal(CliValidationOutcomeKind.Failed, outcome.Kind);
        Assert.Contains("CLI not found", outcome.Message);
    }

    [Fact]
    public async Task NonCliKindFails()
    {
        var outcome = await CliProviderValidator.ValidateAsync(
            ProviderKind.OpenAi, @"C:\x.exe", new ProviderFactory(), Shell(""), TestContext.Current.CancellationToken);

        Assert.Equal(CliValidationOutcome.Failed("Not a CLI provider."), outcome);
    }
}
