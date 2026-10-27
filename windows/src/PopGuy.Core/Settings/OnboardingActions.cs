using PopGuy.Core.Actions;

namespace PopGuy.Core.Settings;

/// <summary>
/// Where the wizard points the built-in actions (macOS pointAIActionsAtLocalModel and pointActionsAtCloudProvider):
/// each config keeps its custom prompt and tone; a change is saved only when it differs.
/// </summary>
public static class OnboardingActions
{
    /// <summary>Improve, Shorten, Proofread and Prompt on <paramref name="kind"/>'s <paramref name="model"/>; Translate untouched.</summary>
    public static AppSettings WithAiActionsOn(AppSettings s, ProviderKind kind, string model) => s with
    {
        ImproveConfig = s.ImproveConfig with { ProviderKind = kind, Model = model },
        ShortenConfig = s.ShortenConfig with { ProviderKind = kind, Model = model },
        ProofreadConfig = s.ProofreadConfig with { ProviderKind = kind, Model = model },
        PromptConfig = s.PromptConfig with { ProviderKind = kind, Model = model },
    };

    /// <summary>
    /// A verified cloud key: the AI providers take Improve, Shorten, Proofread and Prompt with their first curated model;
    /// DeepL and Google Translate take Translate (keeping its model, they use none).
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
