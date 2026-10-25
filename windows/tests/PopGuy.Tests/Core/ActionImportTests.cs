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
}
