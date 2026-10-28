using PopGuy.Core.Actions;
using PopGuy.Core.Providers.Cli;
using PopGuy.Core.Settings;

namespace PopGuy.Core.Providers;

/// <summary>
/// Maps a <see cref="ProviderKind"/> and its API key to an adapter (the routing of macOS
/// <c>ActionEngine.makeDefaultFactory</c>) through a registry. The HTTP and CLI kinds are registered here; the local
/// engine (Phase 21) calls <see cref="Register"/> at startup. Register before the first
/// <see cref="Create"/>: the registry is not synchronized for writes during use.
/// </summary>
public sealed class ProviderFactory
{
    /// <summary>The OpenAI-compatible base URLs of the kinds served by <see cref="OpenAIProvider"/> with a fixed endpoint.</summary>
    public const string GlmBaseUrl = "https://api.z.ai/api/paas/v4/";
    public const string OpenRouterBaseUrl = "https://openrouter.ai/api/v1";

    private readonly Dictionary<ProviderKind, Func<string, IProvider>> _registry = [];

    /// <param name="cli">Runs the subscription CLIs; the App passes one that puts them in its job object.</param>
    public ProviderFactory(ProviderHttp? http = null, CliRunner? cli = null)
    {
        Register(ProviderKind.OpenAi, key => new OpenAIProvider(key, ProviderKind.OpenAi, http));
        Register(ProviderKind.Anthropic, key => new AnthropicProvider(key, http));
        // Ollama needs no key; its base URL comes from the options (ResolveBaseUrl).
        Register(ProviderKind.Ollama, _ => new OllamaProvider(http));
        Register(ProviderKind.DeepL, key => new DeepLProvider(key, http));
        Register(ProviderKind.GoogleTranslate, key => new GoogleTranslateProvider(key, http));
        Register(ProviderKind.Gemini, key => new GeminiProvider(key, http));
        // These speak the OpenAI wire format; the kind selects the "disable thinking" field.
        foreach (var kind in (ProviderKind[])[ProviderKind.Glm, ProviderKind.OpenRouter, ProviderKind.Custom])
            Register(kind, key => new OpenAIProvider(key, kind, http));
        // The CLIs use their own subscription login: no key. Nothing here may throw (ActionEngine reports only
        // ProviderError); a missing CLI fails the stream instead.
        cli ??= new CliRunner();
        Register(ProviderKind.ClaudeCli, _ => new ClaudeCliProvider(cli));
        Register(ProviderKind.CodexCli, _ => new CodexCliProvider(cli));
        Register(ProviderKind.GeminiCli, _ => new GeminiCliProvider(cli));
    }

    /// <summary>Adds or replaces the adapter of <paramref name="kind"/>; the function receives the API key.</summary>
    public void Register(ProviderKind kind, Func<string, IProvider> create) => _registry[kind] = create;

    /// <summary>Whether an adapter is registered for <paramref name="kind"/>.</summary>
    public bool IsRegistered(ProviderKind kind) => _registry.ContainsKey(kind);

    /// <summary>The adapter for <paramref name="kind"/>; throws when no adapter is registered for it.</summary>
    public IProvider Create(ProviderKind kind, string apiKey) =>
        _registry.TryGetValue(kind, out var create)
            ? create(apiKey)
            : throw new InvalidOperationException($"No provider is registered for {kind}.");

    /// <summary>
    /// The base URL to pass in <see cref="ProviderOptions.BaseUrl"/> (macOS <c>ActionEngineHandler.resolveBaseURL</c>):
    /// Ollama and Custom from settings (an empty Custom URL is null), GLM and OpenRouter their fixed endpoints, null
    /// for every other kind (the adapter's own endpoint; Gemini must never be redirected). Unparsed: the caller guards
    /// GLM, OpenRouter and Custom against a missing or invalid URL so a key never reaches api.openai.com.
    /// </summary>
    public static string? ResolveBaseUrl(ProviderKind kind, AppSettings settings) => kind switch
    {
        ProviderKind.Ollama => settings.OllamaBaseUrl,
        ProviderKind.Glm => GlmBaseUrl,
        ProviderKind.OpenRouter => OpenRouterBaseUrl,
        ProviderKind.Custom => settings.CustomBaseUrl.Length == 0 ? null : settings.CustomBaseUrl,
        _ => null,
    };

    /// <summary>
    /// The CLI path to pass in <see cref="ProviderOptions.ExecutablePath"/> (macOS
    /// <c>ActionEngineHandler.resolveExecutablePath</c>): the path set in settings for a CLI kind, null when it is empty
    /// (the CLI is then looked up on PATH) and for every other kind.
    /// </summary>
    public static string? ResolveExecutablePath(ProviderKind kind, AppSettings settings)
    {
        var path = kind switch
        {
            ProviderKind.ClaudeCli => settings.ClaudeCliPath,
            ProviderKind.CodexCli => settings.CodexCliPath,
            ProviderKind.GeminiCli => settings.GeminiCliPath,
            _ => "",
        };
        return path.Length == 0 ? null : path;
    }
}
