using System.Globalization;
using System.Text.Json;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;

namespace PopGuy.Tests.Core;

// Security: the import gate for untrusted action files (spec-3 §2.10, spec-4 §5.2, CustomAction.swift sanitizeImported).
public class ActionImportTests
{
    private static CustomAction Action(CustomActionType type, string title = "Action") =>
        new() { Title = title, SystemPrompt = "Rewrite {{text}}.", Type = type, ScriptSource = "echo hi" };

    private static byte[] Encode(IEnumerable<CustomAction> actions) =>
        JsonSerializer.SerializeToUtf8Bytes(actions.ToList(), PopGuyJson.Options);

    [Fact]
    public void OversizeOrOverCountFileIsRejected()
    {
        var oversize = ActionImport.SanitizeImported(new byte[ActionImport.MaxFileBytes + 1]);
        var overCount = ActionImport.SanitizeImported(
            Encode(Enumerable.Range(0, ActionImport.MaxActions + 1).Select(_ => Action(CustomActionType.Ai))));
        var atLimit = ActionImport.SanitizeImported(
            Encode(Enumerable.Range(0, ActionImport.MaxActions).Select(_ => Action(CustomActionType.Ai))));

        Assert.Equal(ImportRejection.TooLarge, oversize.Rejection);
        Assert.Equal(ImportRejection.TooManyActions, overCount.Rejection);
        Assert.Empty(overCount.Actions);
        Assert.Null(atLimit.Rejection);
        Assert.Equal(ActionImport.MaxActions, atLimit.Actions.Count);
    }

    [Theory]
    [InlineData("""[{"title": 5}]""")]
    [InlineData("[null]")]
    [InlineData("""{"fr": null}""")]
    public void MalformedFileIsRefusedNotThrown(string fragment)
    {
        // A fragment that is not a JSON array is a voiceOverrides value inside an otherwise valid action.
        var json = fragment.StartsWith('[')
            ? fragment
            : System.Text.Encoding.UTF8.GetString(Encode([Action(CustomActionType.Speech)]))
                .Replace("\"voiceOverrides\": {}", $"\"voiceOverrides\": {fragment}");
        Assert.Contains(fragment, json);

        var result = ActionImport.SanitizeImported(System.Text.Encoding.UTF8.GetBytes(json));

        Assert.Equal(ImportRejection.Unreadable, result.Rejection);
    }

    [Fact]
    public void ImportedActionsGetFreshIdentityAndDisallowedProvidersAreSkipped()
    {
        var original = Action(CustomActionType.Ai) with { LibraryPresetId = "ai.humanize", IsFromPlugin = false };
        // DeepL is a translation-only provider: an AI action that names it is skipped.
        var badProvider = Action(CustomActionType.Ai) with { ProviderKind = ProviderKind.DeepL };

        var result = ActionImport.SanitizeImported(Encode([original, badProvider]));

        var imported = Assert.Single(result.Actions).Action;
        Assert.Equal(1, result.SkippedCount);
        Assert.NotEqual(original.Id, imported.Id);
        Assert.True(imported.IsFromPlugin);
        Assert.Null(imported.LibraryPresetId);
    }

    [Fact]
    public void MacOnlyActionsAreKeptButNotRunnableAndZshScriptsAreDisabled()
    {
        var result = ActionImport.SanitizeImported(Encode([
            Action(CustomActionType.AppleScript),
            Action(CustomActionType.RunShortcut),
            Action(CustomActionType.ShellScript),
            Action(CustomActionType.ShellScript) with { Shell = "powershell" },
        ]));

        Assert.Equal(4, result.Actions.Count);
        var (appleScript, shortcut, zsh, powershell) =
            (result.Actions[0], result.Actions[1], result.Actions[2], result.Actions[3]);
        Assert.False(appleScript.Action.RunnableOnWindows);
        Assert.False(shortcut.Action.RunnableOnWindows);
        Assert.True(appleScript.Action.IsEnabled);

        Assert.True(zsh.WrittenForMacShell);
        Assert.False(zsh.Action.IsEnabled);
        Assert.True(zsh.Action.RunnableOnWindows);

        Assert.False(powershell.WrittenForMacShell);
        Assert.True(powershell.Action.IsEnabled);
        Assert.Equal("powershell", powershell.Action.Shell);
    }

    [Fact]
    public void TitleIsClampedByGraphemeClusters()
    {
        // A ZWJ family emoji (8 UTF-16 units, 1 grapheme) straddles the 100th position: a UTF-16 cut would split it.
        const string family = "\U0001F468‍\U0001F469‍\U0001F467";
        var title = new string('a', 99) + family + "b";

        var imported = Assert.Single(
            ActionImport.SanitizeImported(Encode([Action(CustomActionType.Ai, title)])).Actions).Action;

        Assert.Equal(100, new StringInfo(imported.Title).LengthInTextElements);
        Assert.EndsWith(family, imported.Title, StringComparison.Ordinal);
    }

    // Fields a type never uses are dropped, so the consent panel shows everything an import saves (commit security
    // review): a hidden script on an AI action could surface after a type change.
    [Theory]
    [InlineData(CustomActionType.Ai, false, true)]
    [InlineData(CustomActionType.Translation, false, true)]
    [InlineData(CustomActionType.Speech, false, false)]
    [InlineData(CustomActionType.Dictionary, false, false)]
    [InlineData(CustomActionType.OpenUrl, true, false)]
    [InlineData(CustomActionType.ShellScript, true, false)]
    [InlineData(CustomActionType.AppleScript, true, false)]
    [InlineData(CustomActionType.RunShortcut, true, false)]
    public void FieldsTheTypeDoesNotUseAreCleared(CustomActionType type, bool keepsScript, bool keepsPrompt)
    {
        var safe = ActionImport.Sanitize(Action(type) with { AppliesWhenRegex = "^x" })!;

        Assert.Equal(keepsScript ? "echo hi" : "", safe.ScriptSource);
        Assert.Equal(keepsScript ? "^x" : "", safe.AppliesWhenRegex);
        Assert.Equal(keepsPrompt ? "Rewrite {{text}}." : "", safe.SystemPrompt);
    }

    // The Azure region names the host the user's key goes to (Phase 15 follow-up a): only Speech and Dictionary actions
    // keep a cloud TTS config, and a region that is not a plain host label is dropped.
    [Theory]
    [InlineData(CustomActionType.Speech, "westeurope", true, "westeurope")]
    [InlineData(CustomActionType.Dictionary, "eastus", true, "eastus")]
    [InlineData(CustomActionType.Speech, "evil.example.com/x", true, null)]
    [InlineData(CustomActionType.Speech, "East US", true, null)]
    [InlineData(CustomActionType.Ai, "eastus", false, null)]
    [InlineData(CustomActionType.OpenUrl, "eastus", false, null)]
    public void TtsConfigIsKeptOnlyForSpeakingTypesWithAValidRegion(CustomActionType type, string region, bool keepsConfig, string? expected)
    {
        var tts = new TtsProviderConfig
        {
            Region = region, Model = "gpt-4o-mini-tts", DefaultVoice = "nova",
            VoiceOverrides = new Dictionary<string, string> { ["en-US"] = "en-US-JennyNeural" },
        };

        var safe = ActionImport.Sanitize(Action(type) with { TtsConfig = tts })!;

        Assert.Equal(expected, safe.TtsConfig.Region);
        Assert.Equal(keepsConfig ? "gpt-4o-mini-tts" : null, safe.TtsConfig.Model);
        Assert.Equal(keepsConfig ? "nova" : null, safe.TtsConfig.DefaultVoice);
        Assert.Equal(keepsConfig ? 1 : 0, safe.TtsConfig.VoiceOverrides.Count);
    }
}
