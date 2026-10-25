using PopGuy.Core.Actions;
using PopGuy.Core.Settings;

namespace PopGuy.Core.Providers;

/// <summary>
/// Maps a <see cref="ProviderKind"/> and its API key to an adapter (the routing of macOS
/// <c>ActionEngine.makeDefaultFactory</c>) through a registry. The HTTP kinds are registered here; the CLI kinds
/// (Phase 11) and the local engine (Phase 21) call <see cref="Register"/> at startup. Register before the first
/// <see cref="Create"/>: the registry is not synchronized for writes during use.
/// </summary>
public sealed class ProviderFactory
{
    /// <summary>The OpenAI-compatible base URLs of the kinds served by <see cref="OpenAIProvider"/> with a fixed endpoint.</summary>
    public const string GlmBaseUrl = "https://api.z.ai/api/paas/v4/";
    public const string OpenRouterBaseUrl = "https://openrouter.ai/api/v1";

    private readonly Dictionary<ProviderKind, Func<string, IProvider>> _registry = [];

    public ProviderFactory(ProviderHttp? http = null)
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
    }

    /// <summary>Adds or replaces the adapter of <paramref name="kind"/>; the function receives the API key.</summary>
    public void Register(ProviderKind kind, Func<string, IProvider> create) => _registry[kind] = create;

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
}
