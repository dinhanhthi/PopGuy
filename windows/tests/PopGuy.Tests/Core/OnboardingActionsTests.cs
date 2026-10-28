using PopGuy.Core.Actions;
using PopGuy.Core.Settings;

namespace PopGuy.Tests.Core;

// Contract: where the wizard points the built-in actions (macOS pointAIActionsAtLocalModel, pointActionsAtCloudProvider).
public sealed class OnboardingActionsTests
{
    [Fact]
    public void AnAiKeyTakesEveryBuiltinAndKeepsTheirPrompts()
    {
        var before = new AppSettings
        {
            ImproveConfig = ActionConfig.Default(ActionKind.Improve) with { CustomPrompt = "Keep it short.", Tone = TranslateTone.Formal },
        };

        var after = OnboardingActions.WithCloudProvider(before, ProviderKind.Anthropic);

        var model = ProviderKind.Anthropic.CuratedModels()[0];
        Assert.Equal("claude-sonnet-5-5", model);
        Assert.All(
            new[] { after.ImproveConfig, after.ShortenConfig, after.ProofreadConfig, after.PromptConfig, after.TranslateConfig },
            c => Assert.Equal((ProviderKind.Anthropic, model), (c.ProviderKind, c.Model)));
        Assert.Equal("Keep it short.", after.ImproveConfig.CustomPrompt);
        Assert.Equal(TranslateTone.Formal, after.ImproveConfig.Tone);
    }

    [Fact]
    public void AnAiProviderLeavesTranslateOnATranslationService()
    {
        var before = new AppSettings
        {
            TranslateConfig = ActionConfig.Default(ActionKind.Translate) with { ProviderKind = ProviderKind.DeepL },
        };

        var after = OnboardingActions.WithAiActionsOn(before, ProviderKind.MlxLocal, "gguf-qwen3.5-4b");

        Assert.Equal(before.TranslateConfig, after.TranslateConfig);
        Assert.Equal((ProviderKind.MlxLocal, "gguf-qwen3.5-4b"), (after.ImproveConfig.ProviderKind, after.ImproveConfig.Model));
    }

    [Fact]
    public void ATranslationKeyTakesTranslateOnly()
    {
        var before = new AppSettings();

        var after = OnboardingActions.WithCloudProvider(before, ProviderKind.DeepL);

        Assert.Equal(ProviderKind.DeepL, after.TranslateConfig.ProviderKind);
        Assert.Equal(before.TranslateConfig.Model, after.TranslateConfig.Model);
        Assert.Equal(before.ImproveConfig, after.ImproveConfig);
    }
}
