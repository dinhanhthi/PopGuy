using PopGuy.Core.Actions;
using PopGuy.Core.Json;
using PopGuy.Core.Settings;

namespace PopGuy.Core.Providers;

/// <summary>
/// Per-provider maps of deprecated, retired or never-valid model ids to their recommended replacement, and the
/// migration of saved settings that still point at one (a port of ModelDeprecations.swift and the TTS map of
/// TTSProviderKind.swift; applied by <see cref="SettingsStore"/> on load, as SettingsStore.swift does).
/// <para>
/// Sources (checked 2026-10-14): the Anthropic "Model deprecations" page; the OpenAI "Deprecations" page and the Codex
/// "Models" page (ChatGPT sign-in retirements); the Gemini API "Deprecations" page and the Gemini CLI model registry;
/// the OpenRouter models catalog.
/// </para>
/// Rules: only ids the docs mark deprecated, retired or shut down, plus ids PopGuy once shipped that were never valid
/// (legacy-but-active ids are not touched); a replacement is never itself a key of the same map (no chains); matching
/// is exact after trimming whitespace.
/// </summary>
public static class ModelDeprecations
{
    /// <summary>
    /// Deprecated model id → replacement for <paramref name="kind"/>. Keyed per provider because the same id can be live
    /// on one provider and retired on another (gpt-5.5 on the OpenAI API vs. Codex sign-in). Every kind is listed: a
    /// new one must be added here.
    /// </summary>
    public static IReadOnlyDictionary<string, string> DeprecatedModelReplacements(this ProviderKind kind) => kind switch
    {
        ProviderKind.OpenAi => OpenAiReplacements,
        ProviderKind.CodexCli => CodexReplacements,
        ProviderKind.Anthropic or ProviderKind.ClaudeCli => AnthropicReplacements,
        ProviderKind.Gemini => GeminiReplacements,
        ProviderKind.GeminiCli => GeminiCliReplacements,
        ProviderKind.OpenRouter => OpenRouterReplacements,
        // No documented deprecations, or the model list is user-defined.
        ProviderKind.Glm or ProviderKind.Ollama or ProviderKind.Custom or ProviderKind.DeepL
            or ProviderKind.GoogleTranslate or ProviderKind.MlxLocal => Empty,
        _ => Empty,
    };

    /// <summary>
    /// The replacement of <paramref name="model"/> when it is a deprecated id of <paramref name="kind"/> (matched after
    /// trimming whitespace and newlines), else <paramref name="model"/> unchanged. An empty string stays empty.
    /// </summary>
    public static string MigratedModel(this ProviderKind kind, string model) =>
        kind.DeprecatedModelReplacements().GetValueOrDefault(model.Trim(), model);

    /// <summary>
    /// Deprecated speech model id → replacement. OpenAI names gpt-realtime-2.1-mini as the successor of tts-1, but that
    /// Realtime model does not work on the speech endpoint; gpt-4o-mini-tts does, and its voices are a superset of
    /// tts-1's, so no voice reset is needed.
    /// </summary>
    public static IReadOnlyDictionary<string, string> DeprecatedModelReplacements(this TtsProviderKind kind) => kind switch
    {
        TtsProviderKind.OpenAiTts => OpenAiTtsReplacements,
        TtsProviderKind.GoogleCloudTts or TtsProviderKind.AzureTts => Empty,
        _ => Empty,
    };

    /// <summary>As the <see cref="ProviderKind"/> overload; null (the provider default) stays null.</summary>
    public static string? MigratedModel(this TtsProviderKind kind, string? model) =>
        model is null ? null : kind.DeprecatedModelReplacements().GetValueOrDefault(model.Trim(), model);

    /// <summary>
    /// <paramref name="settings"/> with every deprecated model replaced: the five built-in action configs, each cloud
    /// TTS config (keyed by <see cref="TtsProviderKind"/> raw value; unknown keys untouched) and each custom action.
    /// Returns the same instance when nothing changed, so the caller saves only a real migration.
    /// </summary>
    public static AppSettings Migrated(AppSettings settings)
    {
        var changed = false;
        ActionConfig Config(ActionConfig config)
        {
            var model = config.ProviderKind.MigratedModel(config.Model);
            if (model == config.Model)
                return config;
            changed = true;
            return config with { Model = model };
        }

        var improve = Config(settings.ImproveConfig);
        var shorten = Config(settings.ShortenConfig);
        var proofread = Config(settings.ProofreadConfig);
        var translate = Config(settings.TranslateConfig);
        var prompt = Config(settings.PromptConfig);

        var ttsConfigs = new Dictionary<string, TtsProviderConfig>(settings.TtsProviderConfigs);
        foreach (var (key, config) in settings.TtsProviderConfigs)
        {
            if (!RawValueEnumConverter<TtsProviderKind>.TryParse(key, out var kind))
                continue;
            var model = kind.MigratedModel(config.Model);
            if (model == config.Model)
                continue;
            ttsConfigs[key] = config with { Model = model };
            changed = true;
        }

        var customActions = settings.CustomActions.Select(action =>
        {
            var migrated = Migrated(action);
            changed |= !ReferenceEquals(migrated, action);
            return migrated;
        }).ToList();

        return changed
            ? settings with
            {
                ImproveConfig = improve,
                ShortenConfig = shorten,
                ProofreadConfig = proofread,
                TranslateConfig = translate,
                PromptConfig = prompt,
                TtsProviderConfigs = ttsConfigs,
                CustomActions = customActions,
            }
            : settings;
    }

    /// <summary>
    /// <paramref name="action"/> with deprecated AI and speech models replaced (the same instance when none is). The
    /// speech model goes through the OpenAI TTS map: only OpenAI TTS has deprecated ids, and they never match another
    /// engine's model.
    /// </summary>
    public static CustomAction Migrated(CustomAction action)
    {
        var model = action.ProviderKind.MigratedModel(action.Model);
        var ttsModel = TtsProviderKind.OpenAiTts.MigratedModel(action.TtsConfig.Model);
        if (model == action.Model && ttsModel == action.TtsConfig.Model)
            return action;
        return action with { Model = model, TtsConfig = action.TtsConfig with { Model = ttsModel } };
    }

    // MARK: - Maps

    private static readonly IReadOnlyDictionary<string, string> Empty = new Dictionary<string, string>();

    /// <summary>OpenAI "Deprecations" page.</summary>
    private static readonly IReadOnlyDictionary<string, string> OpenAiReplacements = new Dictionary<string, string>
    {
        ["gpt-5.4-nano"] = "gpt-6-luna",

        ["gpt-5.1"] = "gpt-6-sol",
        ["gpt-5.3-codex"] = "gpt-6-sol",

        ["gpt-5"] = "gpt-5.6-sol",
        ["gpt-5-2025-08-07"] = "gpt-5.6-sol",
        ["o3"] = "gpt-5.6-sol",
        ["o3-2025-04-16"] = "gpt-5.6-sol",

        ["gpt-5-mini"] = "gpt-5.6-terra",
        ["gpt-5-mini-2025-08-07"] = "gpt-5.6-terra",

        ["gpt-5-nano"] = "gpt-5.6-luna",
        ["gpt-5-nano-2025-08-07"] = "gpt-5.6-luna",

        ["gpt-5.2-chat-latest"] = "gpt-5.6-sol",
        ["gpt-5.3-chat-latest"] = "gpt-5.6-sol",

        ["gpt-4o"] = "gpt-6-luna",
        ["gpt-4o-2024-08-06"] = "gpt-6-luna",
        ["gpt-4o-2024-11-20"] = "gpt-6-luna",
        ["gpt-4o-mini"] = "gpt-6-luna",
        ["gpt-4o-mini-2024-07-18"] = "gpt-6-luna",
        ["gpt-4.1"] = "gpt-6-luna",
        ["gpt-4.1-2025-04-14"] = "gpt-6-luna",
        ["gpt-4.1-mini"] = "gpt-6-luna",
        ["gpt-4.1-mini-2025-04-14"] = "gpt-6-luna",

        ["gpt-4.1-nano"] = "gpt-5.6-luna",
        ["gpt-4.1-nano-2025-04-14"] = "gpt-5.6-luna",

        ["o4-mini"] = "gpt-5.6-terra",
        ["o4-mini-2025-04-16"] = "gpt-5.6-terra",
        ["gpt-3.5-turbo"] = "gpt-5.6-terra",
        ["gpt-3.5-turbo-0125"] = "gpt-5.6-terra",

        ["gpt-4"] = "gpt-5.6-sol",
        ["gpt-4-0613"] = "gpt-5.6-sol",
        ["gpt-4-turbo"] = "gpt-5.6-sol",
        ["gpt-4-turbo-2024-04-09"] = "gpt-5.6-sol",
        ["gpt-4-turbo-preview"] = "gpt-5.6-sol",
        ["gpt-4-1106-preview"] = "gpt-5.6-sol",
        ["gpt-4o-2024-05-13"] = "gpt-5.6-sol",
        ["o1"] = "gpt-5.6-sol",
        ["o1-2024-12-17"] = "gpt-5.6-sol",
        ["o3-mini"] = "gpt-5.6-sol",
        ["o3-mini-2025-01-31"] = "gpt-5.6-sol",
    };

    /// <summary>Codex "Models" page: ids retired for ChatGPT sign-in, applied on top of the OpenAI map.</summary>
    private static readonly IReadOnlyDictionary<string, string> CodexOverrides = new Dictionary<string, string>
    {
        ["gpt-5.5"] = "gpt-6.1-sol",
        ["gpt-5.2"] = "gpt-6.1-sol",
        ["gpt-5.3-codex"] = "gpt-6.1-sol",
        ["gpt-5.3-codex-spark"] = "gpt-6.1-sol",
        ["gpt-5.4"] = "gpt-6-sol",
        ["gpt-5.4-mini"] = "gpt-6-luna",
    };

    /// <summary>The OpenAI map, where the Codex overrides win.</summary>
    private static readonly IReadOnlyDictionary<string, string> CodexReplacements =
        OpenAiReplacements.Concat(CodexOverrides).GroupBy(pair => pair.Key).ToDictionary(g => g.Key, g => g.Last().Value);

    /// <summary>Anthropic "Model deprecations" page (alias and dated forms), shared by the API and the Claude CLI.</summary>
    private static readonly IReadOnlyDictionary<string, string> AnthropicReplacements = new Dictionary<string, string>
    {
        ["claude-sonnet-4-5"] = "claude-sonnet-5-5",
        ["claude-sonnet-4-5-20250929"] = "claude-sonnet-5-5",

        ["claude-sonnet-4-0"] = "claude-sonnet-5-5",
        ["claude-sonnet-4-20250514"] = "claude-sonnet-5-5",
        ["claude-3-7-sonnet-latest"] = "claude-sonnet-5-5",
        ["claude-3-7-sonnet-20250219"] = "claude-sonnet-5-5",
        ["claude-3-5-sonnet-latest"] = "claude-sonnet-5-5",
        ["claude-3-5-sonnet-20240620"] = "claude-sonnet-5-5",
        ["claude-3-5-sonnet-20241022"] = "claude-sonnet-5-5",
        ["claude-3-sonnet-20240229"] = "claude-sonnet-5-5",

        ["claude-opus-4-1"] = "claude-opus-4-8",
        ["claude-opus-4-1-20250805"] = "claude-opus-4-8",
        ["claude-opus-4-0"] = "claude-opus-4-8",
        ["claude-opus-4-20250514"] = "claude-opus-4-8",
        ["claude-3-opus-latest"] = "claude-opus-4-8",
        ["claude-3-opus-20240229"] = "claude-opus-4-8",

        ["claude-3-5-haiku-latest"] = "claude-haiku-4-5-20251001",
        ["claude-3-5-haiku-20241022"] = "claude-haiku-4-5-20251001",
        ["claude-3-haiku-20240307"] = "claude-haiku-4-5-20251001",
    };

    /// <summary>
    /// Gemini API "Deprecations" page. Pro-class ids map to the stable flagship rather than a preview, because preview
    /// ids churn and get shut down.
    /// </summary>
    private static readonly IReadOnlyDictionary<string, string> GeminiReplacements = new Dictionary<string, string>
    {
        ["gemini-3.1-pro"] = "gemini-4-argon", // never valid
        ["gemini-3-pro"] = "gemini-4-argon", // never valid
        ["gemini-3-pro-preview"] = "gemini-4-argon",
        ["gemini-2.5-pro-preview-03-25"] = "gemini-4-argon",
        ["gemini-2.5-pro-preview-05-06"] = "gemini-4-argon",
        ["gemini-2.5-pro-preview-06-05"] = "gemini-4-argon",

        ["gemini-3-flash"] = "gemini-3.6-flash", // never valid
        ["gemini-3-flash-preview"] = "gemini-3.6-flash",
        ["gemini-3.5-flash"] = "gemini-3.6-flash",
        ["gemini-2.0-flash"] = "gemini-3.6-flash",
        ["gemini-2.0-flash-001"] = "gemini-3.6-flash",
        ["gemini-2.5-flash-preview-05-20"] = "gemini-3.6-flash",
        ["gemini-2.5-flash-preview-09-2025"] = "gemini-3.6-flash",

        ["gemini-3.7-flash"] = "gemini-3.8-flash",

        ["gemini-3.1-flash-lite"] = "gemini-3.5-flash-lite",
        ["gemini-3.1-flash-lite-preview"] = "gemini-3.5-flash-lite",
        ["gemini-2.0-flash-lite"] = "gemini-3.5-flash-lite",
        ["gemini-2.0-flash-lite-001"] = "gemini-3.5-flash-lite",
        ["gemini-2.5-flash-lite-preview-09-2025"] = "gemini-3.5-flash-lite",
    };

    /// <summary>Gemini CLI model registry ids.</summary>
    private static readonly IReadOnlyDictionary<string, string> GeminiCliReplacements = new Dictionary<string, string>
    {
        ["gemini-3-pro"] = "gemini-3.1-pro-preview", // never valid
        ["gemini-3-pro-preview"] = "gemini-3.1-pro-preview",

        ["gemini-3-flash"] = "gemini-3.8-flash", // never valid
        ["gemini-3-flash-preview"] = "gemini-3.8-flash",
        ["gemini-3.5-flash"] = "gemini-3.8-flash",

        ["gemini-3.1-flash-lite"] = "gemini-3.5-flash-lite",
    };

    /// <summary>OpenRouter live models catalog.</summary>
    private static readonly IReadOnlyDictionary<string, string> OpenRouterReplacements = new Dictionary<string, string>
    {
        ["anthropic/claude-opus-4-8"] = "anthropic/claude-opus-5.5", // never valid (OpenRouter uses dots)
        ["google/gemini-3.1-pro"] = "google/gemini-4-argon", // never valid
    };

    /// <summary>OpenAI "Deprecations" page, speech models.</summary>
    private static readonly IReadOnlyDictionary<string, string> OpenAiTtsReplacements = new Dictionary<string, string>
    {
        ["tts-1"] = "gpt-4o-mini-tts",
        ["tts-1-hd"] = "gpt-4o-mini-tts",
        ["gpt-4o-mini-tts-2025-03-20"] = "gpt-4o-mini-tts",
        ["gpt-4o-mini-tts-2025-12-15"] = "gpt-4o-mini-tts",
    };
}
