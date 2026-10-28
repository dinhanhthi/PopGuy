using PopGuy.Core.Actions;
using PopGuy.Core.Settings;

namespace PopGuy.Tests.Core;

// Contract: the rules behind Settings → Actions (macOS SettingsStore.swift isLastEnabledAction and setShortcut,
// ActionConfig.swift / CustomAction.swift allowedProviders, ProviderTypes.swift latencyWarning).
public sealed class ActionsSettingsTests
{
    private static readonly ActionIdentifier Improve = ActionIdentifier.Builtin(ActionKind.Improve);
    private static readonly ActionIdentifier Translate = ActionIdentifier.Builtin(ActionKind.Translate);
    private static readonly Shortcut CtrlAltI = new('I', ShortcutModifiers.Control | ShortcutModifiers.Alt);

    [Fact]
    public void OnlyTheSoleEnabledActionIsLocked()
    {
        var onlyImprove = new AppSettings
        {
            ShortenEnabled = false, ProofreadEnabled = false, TranslateEnabled = false, SpeakEnabled = false,
        };

        Assert.True(ToolbarLayout.IsLastEnabledAction(onlyImprove, Improve));
        Assert.False(ToolbarLayout.IsLastEnabledAction(onlyImprove, Translate));
        Assert.False(ToolbarLayout.IsLastEnabledAction(ToolbarLayout.WithEnabled(onlyImprove, Translate, true), Improve));
    }

    [Fact]
    public void WithEnabledTurnsOffOnlyThatCustomAction()
    {
        var a = new CustomAction { Title = "A", SystemPrompt = "p" };
        var b = new CustomAction { Title = "B", SystemPrompt = "p" };
        var s = new AppSettings { CustomActions = [a, b] };

        var updated = ToolbarLayout.WithEnabled(s, ActionIdentifier.Custom(a.Id), false);

        Assert.False(updated.CustomActions[0].IsEnabled);
        Assert.True(updated.CustomActions[1].IsEnabled);
    }

    [Fact]
    public void SettingAShortcutTakesItFromAnotherActionAndKeepsTheBindingInPlace()
    {
        IReadOnlyList<ShortcutBinding> bindings = [new(Improve, CtrlAltI), new(Translate, new('T', ShortcutModifiers.Alt))];

        var moved = ShortcutBinding.Set(bindings, Translate, CtrlAltI);

        Assert.Equal([new ShortcutBinding(Translate, CtrlAltI)], moved);
        Assert.Equal([new ShortcutBinding(Improve, CtrlAltI)], ShortcutBinding.Set(bindings, Translate, null));
    }

    [Fact]
    public void AiActionsCannotUseTheTranslationServices()
    {
        Assert.DoesNotContain(ProviderKind.DeepL, ProviderKindExtensions.AllowedProviders(ActionKind.Improve));
        Assert.Contains(ProviderKind.DeepL, ProviderKindExtensions.AllowedProviders(ActionKind.Translate));
        Assert.Equal(ProviderKindExtensions.AllowedProviders(ActionKind.Improve), ProviderKindExtensions.AllowedProviders(CustomActionType.Ai));
        Assert.Empty(ProviderKindExtensions.AllowedProviders(CustomActionType.Speech));
    }

    [Fact]
    public void OnlyTheSubscriptionClisWarnAboutLatency()
    {
        var warned = Enum.GetValues<ProviderKind>().Where(k => k.LatencyWarning() is not null);

        Assert.Equal([ProviderKind.ClaudeCli, ProviderKind.CodexCli, ProviderKind.GeminiCli], warned);
    }
}
