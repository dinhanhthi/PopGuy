using System.Text.RegularExpressions;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers.Cli;

namespace PopGuy.Core.Providers;

// The Verify checks of the Settings Providers page (Phase 13): ports of ProviderKeyValidator.swift,
// ProviderModelValidator.swift and CLIProviderValidator.swift. Every check takes the key as text (the Settings page reads
// the saved one from Credential Manager, onboarding passes the typed one before saving it); keys are never logged, and
// every surfaced error comes from ProviderHttp, which redacts them.

/// <summary>
/// Checks that an API key authenticates with its provider before it is saved. Each request hits an auth-only endpoint
/// (model list, usage, language list): no generation or translation tokens are spent.
/// <para>
/// Outcome: returns when the key authenticates (2xx); throws <see cref="ProviderError"/> Http 400/401/403 for an invalid
/// key, Http with another status when the provider is reachable but the key cannot be verified, Transport on
/// a network failure (not "invalid").
/// </para>
/// </summary>
public static class ProviderKeyValidator
{
    // Keep in sync with the adapters' endpoints and AnthropicProvider's API version.
    private const string OpenAiBase = "https://api.openai.com/v1";
    private const string AnthropicModels = "https://api.anthropic.com/v1/models";
    private const string AnthropicVersion = "2023-06-01";
    private const string DeepLFreeUsage = "https://api-free.deepl.com/v2/usage";
    private const string DeepLProUsage = "https://api.deepl.com/v2/usage";
    private const string GoogleTranslateLanguages = "https://translation.googleapis.com/language/translate/v2/languages";
    private const string GeminiModels = "https://generativelanguage.googleapis.com/v1beta/models";

    /// <summary>
    /// Verifies that <paramref name="apiKey"/> authenticates with <paramref name="kind"/>'s API. The keyless kinds
    /// (Ollama, the local model, the subscription CLIs) and Custom without an endpoint return at once.
    /// </summary>
    /// <param name="baseUrl">The endpoint for Custom (no fixed host), and an override for GLM and OpenRouter (else
    /// their fixed endpoint). Ignored for every other kind: Gemini always uses its native API.</param>
    /// <param name="http">Tests inject a fake handler; the app uses <see cref="ProviderHttp.Shared"/>.</param>
    public static async Task ValidateAsync(
        ProviderKind kind, string apiKey, Uri? baseUrl = null, ProviderHttp? http = null, CancellationToken ct = default)
    {
        if (ValidationRequest(kind, apiKey, baseUrl) is not { } request)
            return;
        // SendAsync throws on a non-2xx response or a network failure; a return means the key authenticated.
        await (http ?? ProviderHttp.Shared).SendAsync(request, apiKey, ct);
    }

    /// <summary>The request that verifies the key, or null when <paramref name="kind"/> has nothing to verify.</summary>
    internal static HttpRequestMessage? ValidationRequest(ProviderKind kind, string apiKey, Uri? baseUrl)
    {
        HttpRequestMessage request;
        switch (kind)
        {
            case ProviderKind.OpenAi:
                return ModelsRequest(OpenAiBase, apiKey);
            case ProviderKind.Glm or ProviderKind.OpenRouter:
                // The OpenAI wire format: GET /models with Bearer auth, at the caller's URL or the fixed endpoint.
                return ModelsRequest(
                    baseUrl?.AbsoluteUri ?? (kind == ProviderKind.Glm ? ProviderFactory.GlmBaseUrl : ProviderFactory.OpenRouterBaseUrl),
                    apiKey);
            case ProviderKind.Custom:
                // No fixed URL: only the user-configured endpoint can be verified.
                return baseUrl is null ? null : ModelsRequest(baseUrl.AbsoluteUri, apiKey);
            case ProviderKind.Anthropic:
                request = new HttpRequestMessage(HttpMethod.Get, AnthropicModels);
                request.Headers.TryAddWithoutValidation("x-api-key", apiKey);
                request.Headers.TryAddWithoutValidation("anthropic-version", AnthropicVersion);
                return request;
            case ProviderKind.DeepL:
                // The free/pro host from the ":fx" suffix, as for translation.
                request = new HttpRequestMessage(
                    HttpMethod.Get, apiKey.EndsWith(":fx", StringComparison.Ordinal) ? DeepLFreeUsage : DeepLProUsage);
                request.Headers.TryAddWithoutValidation("Authorization", $"DeepL-Auth-Key {apiKey}");
                return request;
            case ProviderKind.GoogleTranslate:
                // The URL carries the key: it is never logged, and ProviderHttp redacts it from errors.
                return new HttpRequestMessage(HttpMethod.Get, $"{GoogleTranslateLanguages}?key={Uri.EscapeDataString(apiKey)}");
            case ProviderKind.Gemini:
                // x-goog-api-key, not Bearer, on the native API whatever the caller's URL.
                request = new HttpRequestMessage(HttpMethod.Get, GeminiModels);
                request.Headers.TryAddWithoutValidation("x-goog-api-key", apiKey);
                return request;
            default:
                // Ollama and the local model need no key; the CLIs use their own subscription login.
                return null;
        }
    }

    // GET {base}/models, base trailing slashes stripped (OpenAIProvider.makeValidationRequest).
    private static HttpRequestMessage ModelsRequest(string baseUrl, string apiKey)
    {
        var root = baseUrl.TrimEnd('/');
        var request = new HttpRequestMessage(HttpMethod.Get, ProviderValidation.HttpUrl($"{root}/models", root));
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiKey}");
        return request;
    }
}

/// <summary>
/// Checks that a cloud TTS key authenticates before it is saved (macOS TTSProviderValidator.swift): each request lists
/// models or voices, so no audio is synthesized. Same outcome as <see cref="ProviderKeyValidator"/>. The Settings page
/// checks for an empty key and a missing or malformed Azure region (<see cref="IsAzureRegion"/>) before calling (their
/// messages are its own).
/// </summary>
public static partial class TtsKeyValidator
{
    // Keep in sync with the TTS adapters (Phase 17).
    private const string OpenAiModels = "https://api.openai.com/v1/models";
    private const string GoogleVoices = "https://texttospeech.googleapis.com/v1/voices";

    /// <summary>Verifies that <paramref name="apiKey"/> authenticates with <paramref name="kind"/>'s TTS API.</summary>
    /// <param name="region">The Azure region (e.g. <c>eastus</c>); ignored for the other kinds.</param>
    /// <param name="http">Tests inject a fake handler; the app uses <see cref="ProviderHttp.Shared"/>.</param>
    public static async Task ValidateAsync(
        TtsProviderKind kind, string apiKey, string? region, ProviderHttp? http = null, CancellationToken ct = default) =>
        await (http ?? ProviderHttp.Shared).SendAsync(ValidationRequest(kind, apiKey, region), apiKey, ct);

    /// <summary>
    /// The request that verifies the key. An Azure region that is not a plain host label (letters, digits, hyphens) is
    /// refused (MissingOption), so the key never goes to a host the region names.
    /// </summary>
    internal static HttpRequestMessage ValidationRequest(TtsProviderKind kind, string apiKey, string? region)
    {
        HttpRequestMessage request;
        switch (kind)
        {
            case TtsProviderKind.GoogleCloudTts:
                // The URL carries the key: it is never logged, and ProviderHttp redacts it from errors.
                return new HttpRequestMessage(HttpMethod.Get, $"{GoogleVoices}?key={Uri.EscapeDataString(apiKey)}");
            case TtsProviderKind.AzureTts:
                if (region is null || !IsAzureRegion(region))
                    throw ProviderError.MissingOption("Azure region");
                request = new HttpRequestMessage(
                    HttpMethod.Get, $"https://{region}.tts.speech.microsoft.com/cognitiveservices/voices/list");
                request.Headers.TryAddWithoutValidation("Ocp-Apim-Subscription-Key", apiKey);
                return request;
            default:
                request = new HttpRequestMessage(HttpMethod.Get, OpenAiModels);
                request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiKey}");
                return request;
        }
    }

    /// <summary>Whether <paramref name="region"/> is a plain host label (e.g. <c>eastus</c>), not a display name like "East US".</summary>
    public static bool IsAzureRegion(string region) => AzureRegion().IsMatch(region);

    [GeneratedRegex(@"^[A-Za-z0-9-]{1,63}\z")]
    private static partial Regex AzureRegion();
}

/// <summary>
/// Checks that a model id is accepted by a provider and key: a 1-token streamed call ("Hi", no system prompt) whose
/// first token (or a clean finish with none) is a success.
/// <para>
/// Outcome: returns when the model is accepted; throws <see cref="ProviderError"/> Http 404/400 for an unknown model or
/// a bad request, Http 401/403 for a key failure, Api for an in-stream error event, Transport on a network failure
/// (inconclusive).
/// </para>
/// </summary>
public static class ProviderModelValidator
{
    /// <summary>
    /// Verifies <paramref name="model"/> for <paramref name="kind"/>. Returns at once, without creating an adapter, for
    /// the translation providers (no model), the subscription CLIs (a 10-30 s run to check a freeform name is too slow),
    /// the local model (checked against its cache, not a request) and Custom without an endpoint.
    /// </summary>
    /// <param name="apiKey">The key; empty for Ollama.</param>
    /// <param name="baseUrl">The endpoint for Custom, and an override for GLM and OpenRouter (else their fixed
    /// endpoint). Ignored for every other kind: Gemini always uses its native API.</param>
    /// <param name="factory">The adapters: the app's <see cref="ProviderFactory"/>; tests register stubs or pass one
    /// built over a fake HTTP handler.</param>
    public static async Task ValidateAsync(
        ProviderKind kind, string apiKey, string model, ProviderFactory factory, Uri? baseUrl = null,
        CancellationToken ct = default)
    {
        Uri? resolvedBaseUrl;
        switch (kind)
        {
            case ProviderKind.DeepL or ProviderKind.GoogleTranslate:
            case ProviderKind.ClaudeCli or ProviderKind.CodexCli or ProviderKind.GeminiCli:
            case ProviderKind.MlxLocal:
                return;
            case ProviderKind.Glm or ProviderKind.OpenRouter:
                resolvedBaseUrl = baseUrl
                    ?? new Uri(kind == ProviderKind.Glm ? ProviderFactory.GlmBaseUrl : ProviderFactory.OpenRouterBaseUrl);
                break;
            case ProviderKind.Custom:
                if (baseUrl is null)
                    return;
                resolvedBaseUrl = baseUrl;
                break;
            default:
                // OpenAI, Anthropic, Ollama: the adapter's own endpoint. Gemini: never redirected.
                resolvedBaseUrl = null;
                break;
        }
        if (resolvedBaseUrl is not null)
            ProviderValidation.HttpUrl(resolvedBaseUrl.AbsoluteUri, resolvedBaseUrl.AbsoluteUri);

        var provider = factory.Create(kind, apiKey);
        var options = new ProviderOptions { BaseUrl = resolvedBaseUrl, MaxTokens = 1 };
        // The first token is enough; leaving the loop disposes the stream, which ends the request.
        await foreach (var _ in provider.StreamAsync(null, "Hi", model, options, ct))
            break;
    }
}

/// <summary>
/// The Verify check of the subscription CLIs (Claude, Codex, Gemini), which have no key: one tiny real prompt through
/// the user's own CLI login, and whether it answers.
/// </summary>
public static class CliProviderValidator
{
    /// <summary>A minimal, deterministic prompt, so the check is fast and cheap.</summary>
    internal const string ProbeInput = "Reply with the single word: OK";

    /// <summary>
    /// Runs <paramref name="kind"/>'s CLI once. <see cref="CliValidationOutcome.NoPath"/> when no path is set and the CLI
    /// is not on the PATH either (Windows looks an empty path up on the PATH; macOS needs a path);
    /// <see cref="CliValidationOutcome.Working"/> when it streamed any non-blank text; otherwise
    /// <see cref="CliValidationOutcome.Failed"/> with the error message (also for a non-CLI kind). Cancelling
    /// <paramref name="ct"/> stops the CLI and throws.
    /// </summary>
    /// <param name="executablePath">The path set in Settings; empty looks the CLI up on the PATH.</param>
    /// <param name="factory">The app's <see cref="ProviderFactory"/>, whose runner puts the CLI in PopGuy's job object.</param>
    public static Task<CliValidationOutcome> ValidateAsync(
        ProviderKind kind, string executablePath, ProviderFactory factory, CancellationToken ct = default) =>
        ValidateAsync(kind, executablePath, factory, ShellEnvironment.Shared, ct);

    /// <param name="shell">Where an empty path is looked up; tests pass a fake PATH.</param>
    internal static async Task<CliValidationOutcome> ValidateAsync(
        ProviderKind kind, string executablePath, ProviderFactory factory, ShellEnvironment shell, CancellationToken ct)
    {
        var name = kind switch
        {
            ProviderKind.ClaudeCli => "claude",
            ProviderKind.CodexCli => "codex",
            ProviderKind.GeminiCli => "gemini",
            _ => null,
        };
        if (name is null)
            return CliValidationOutcome.Failed("Not a CLI provider.");
        var path = executablePath.Trim();
        if (path.Length == 0 && shell.Executable(name) is null)
            return CliValidationOutcome.NoPath;

        try
        {
            var provider = factory.Create(kind, "");
            var options = new ProviderOptions { ExecutablePath = path.Length == 0 ? null : path };
            await foreach (var token in provider.StreamAsync(null, ProbeInput, "", options, ct))
            {
                if (!string.IsNullOrWhiteSpace(token))
                    return CliValidationOutcome.Working;
            }
            return CliValidationOutcome.Failed("The CLI ran but returned no output.");
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception error)
        {
            // ProviderError messages are already redacted and user-facing.
            return CliValidationOutcome.Failed(error.Message);
        }
    }
}

/// <summary>The result of a <see cref="CliProviderValidator"/> check.</summary>
public sealed record CliValidationOutcome
{
    private CliValidationOutcome(CliValidationOutcomeKind kind, string message = "")
    {
        Kind = kind;
        Message = message;
    }

    public CliValidationOutcomeKind Kind { get; }

    /// <summary>The user-facing reason of <see cref="CliValidationOutcomeKind.Failed"/>; empty otherwise.</summary>
    public string Message { get; }

    /// <summary>The CLI ran and answered: the subscription login works.</summary>
    public static CliValidationOutcome Working { get; } = new(CliValidationOutcomeKind.Working);

    /// <summary>No path is set and the CLI is not on the PATH.</summary>
    public static CliValidationOutcome NoPath { get; } = new(CliValidationOutcomeKind.NoPath);

    /// <summary>The CLI failed to run or returned an error or nothing.</summary>
    public static CliValidationOutcome Failed(string message) => new(CliValidationOutcomeKind.Failed, message);
}

public enum CliValidationOutcomeKind { Working, NoPath, Failed }

internal static class ProviderValidation
{
    /// <summary>
    /// <paramref name="url"/> parsed, when it is an absolute http(s) URL; else Transport "Invalid base URL" naming
    /// <paramref name="shown"/> without its user info (HttpClient would throw a non-ProviderError for another scheme).
    /// </summary>
    public static Uri HttpUrl(string url, string shown) =>
        Uri.TryCreate(url, UriKind.Absolute, out var parsed) && (parsed.Scheme == Uri.UriSchemeHttp || parsed.Scheme == Uri.UriSchemeHttps)
            ? parsed
            : throw ProviderError.Transport($"Invalid base URL: {ProviderHttp.StripUserInfo(shown)}");
}
