using PopGuy.Core.Actions;

namespace PopGuy.Core.Settings;

/// <summary>
/// Where the wizard points the built-in actions (macOS pointAIActionsAtLocalModel and pointActionsAtCloudProvider):
/// each config keeps its custom prompt and tone; a change is saved only when it differs. Unlike macOS, an AI provider
/// also takes Translate, unless a translation service (DeepL, Google Translate) already has it: every built-in then runs
/// on the provider the user just set up.
/// </summary>
public static class OnboardingActions
{
    /// <summary>
    /// Improve, Shorten, Proofread, Prompt and Translate on <paramref name="kind"/>'s <paramref name="model"/>; Translate
    /// stays on DeepL or Google Translate.
    /// </summary>
    public static AppSettings WithAiActionsOn(AppSettings s, ProviderKind kind, string model) => s with
    {
        ImproveConfig = s.ImproveConfig with { ProviderKind = kind, Model = model },
        ShortenConfig = s.ShortenConfig with { ProviderKind = kind, Model = model },
        ProofreadConfig = s.ProofreadConfig with { ProviderKind = kind, Model = model },
        PromptConfig = s.PromptConfig with { ProviderKind = kind, Model = model },
        TranslateConfig = s.TranslateConfig.ProviderKind.UsesModel()
            ? s.TranslateConfig with { ProviderKind = kind, Model = model }
            : s.TranslateConfig,
    };

    /// <summary>
    /// A verified cloud key: the AI providers take the built-ins (<see cref="WithAiActionsOn"/>) with their first curated
    /// model; DeepL and Google Translate take Translate (keeping its model, they use none).
    /// </summary>
    public static AppSettings WithCloudProvider(AppSettings s, ProviderKind kind) => kind switch
    {
        ProviderKind.DeepL or ProviderKind.GoogleTranslate => s with
        {
            TranslateConfig = s.TranslateConfig with
            {
                ProviderKind = kind,
                Model = kind.CuratedModels().FirstOrDefault() ?? s.TranslateConfig.Model,
            },
        },
        _ => WithAiActionsOn(s, kind, kind.CuratedModels().FirstOrDefault() ?? ""),
    };

    /// <summary>Saves <paramref name="change"/> when it changes anything; a failed write is logged.</summary>
    public static void Save(SettingsStore settings, Action<string> log, Func<AppSettings, AppSettings> change)
    {
        var current = settings.Current;
        if (change(current) == current) return;
        try
        {
            settings.Update(change);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            log($"settings: onboarding actions not saved, {e.GetType().Name}");
        }
    }
}
