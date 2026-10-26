using PopGuy.Core.Actions;

namespace PopGuy.Tests.Core;

// Contract: the Add/Edit action panel's rules (macOS CustomAction.swift isSaveable, CustomActionEditSheet's type
// change, the speech slider levels of ActionsView.swift).
public sealed class CustomActionEditingTests
{
    private static CustomAction Draft(CustomActionType type, string title = "T", string prompt = "", string script = "") =>
        new() { Title = title, SystemPrompt = prompt, Type = type, ScriptSource = script };

    [Fact]
    public void ABlankTitleIsNeverSaveable()
    {
        Assert.False(Draft(CustomActionType.Translation, title: "  \n").IsSaveable);
        Assert.True(Draft(CustomActionType.Translation).IsSaveable);
    }

    [Theory]
    [InlineData(CustomActionType.Ai)]
    [InlineData(CustomActionType.OpenUrl)]
    [InlineData(CustomActionType.RunShortcut)]
    [InlineData(CustomActionType.AppleScript)]
    [InlineData(CustomActionType.ShellScript)]
    public void AiNeedsAPromptAndScriptsNeedASource(CustomActionType type)
    {
        Assert.False(Draft(type, prompt: " ", script: " ").IsSaveable);
        var filled = type == CustomActionType.Ai ? Draft(type, prompt: "p") : Draft(type, script: "s");
        Assert.True(filled.IsSaveable);
    }

    [Theory]
    [InlineData(CustomActionType.Speech)]
    [InlineData(CustomActionType.Dictionary)]
    public void SpeechAndDictionaryNeedOnlyATitle(CustomActionType type) => Assert.True(Draft(type).IsSaveable);

    [Fact]
    public void SwitchingToAiLeavesATranslationOnlyProvider()
    {
        var deepL = Draft(CustomActionType.Translation) with { ProviderKind = ProviderKind.DeepL };

        Assert.Equal(ProviderKind.OpenAi, CustomActionEditing.WithType(deepL, CustomActionType.Ai).ProviderKind);
        // Translation allows every provider: kept.
        var anthropic = Draft(CustomActionType.Ai) with { ProviderKind = ProviderKind.Anthropic };
        Assert.Equal(ProviderKind.Anthropic, CustomActionEditing.WithType(anthropic, CustomActionType.Translation).ProviderKind);
    }

    [Fact]
    public void AScriptableTypeClosesTheToolbarAndAShellScriptIsPowerShell()
    {
        var draft = Draft(CustomActionType.Ai) with { AfterRun = AfterRunBehavior.ShowResult };

        var url = CustomActionEditing.WithType(draft, CustomActionType.OpenUrl);
        var shell = CustomActionEditing.WithType(draft, CustomActionType.ShellScript);

        Assert.Equal(AfterRunBehavior.CloseToolbar, url.AfterRun);
        Assert.Null(url.Shell);
        Assert.Equal(AfterRunBehavior.CloseToolbar, shell.AfterRun);
        Assert.Equal("powershell", shell.Shell);
        Assert.Equal(AfterRunBehavior.ShowResult, CustomActionEditing.WithType(draft, CustomActionType.Speech).AfterRun);
    }

    [Fact]
    public void ADictionaryLeavesTheMacOSDictionary()
    {
        var draft = Draft(CustomActionType.Ai);

        Assert.Equal(DictionaryProviderKind.Minhqnd, CustomActionEditing.WithType(draft, CustomActionType.Dictionary).DictionaryConfig.Provider);
    }

    [Fact]
    public void TheSameTypeChangesNothing()
    {
        var draft = Draft(CustomActionType.ShellScript) with { AfterRun = AfterRunBehavior.ShowResult };

        Assert.Same(draft, CustomActionEditing.WithType(draft, CustomActionType.ShellScript));
    }

    [Fact]
    public void AZshScriptBecomesPowerShellOnlyWhenItsSourceChanged()
    {
        var zsh = Draft(CustomActionType.ShellScript, script: "open -R \"$POPGUY_TEXT\"");

        Assert.Null(CustomActionEditing.ForSave(zsh, zsh with { Title = "Renamed" }).Shell);
        Assert.Equal("powershell", CustomActionEditing.ForSave(zsh, zsh with { ScriptSource = "Get-Item $env:POPGUY_TEXT" }).Shell);
        Assert.Equal("powershell", CustomActionEditing.ForSave(null, zsh).Shell);
        Assert.Null(CustomActionEditing.ForSave(null, Draft(CustomActionType.OpenUrl, script: "https://x/{text}")).Shell);
    }

    [Fact]
    public void SpeechLevelsRoundTripTheMacOSScale()
    {
        Assert.Equal(0.5f, CustomActionEditing.RateForLevel(5));
        Assert.Equal(0f, CustomActionEditing.RateForLevel(1));
        Assert.Equal(1f, CustomActionEditing.RateForLevel(10));
        Assert.Equal(1f, CustomActionEditing.PitchForLevel(4), 4);
        for (var level = 1; level <= 10; level++)
        {
            Assert.Equal(level, CustomActionEditing.LevelForRate(CustomActionEditing.RateForLevel(level)));
            Assert.Equal(level, CustomActionEditing.LevelForPitch(CustomActionEditing.PitchForLevel(level)));
        }
        // The decoded default pitch 1.0 sits at level 4.
        Assert.Equal(4, CustomActionEditing.LevelForPitch(1.0f));
    }
}
