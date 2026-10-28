using System.Text;
using PopGuy.Core.Actions;
using PopGuy.Core.Plugins;

namespace PopGuy.Tests.Core;

// Contract: export round-trips through the import gate, and every import path reaches the consent dialog with the same
// Windows notes (ActionsView.swift exportActions / handleConsentConfirm, PluginImportConsentView.swift).
public class ImportConsentTests
{
    private static string MacExample(string name) =>
        Path.Combine(AppContext.BaseDirectory, "Fixtures", "macos-examples", name);

    private static CustomAction Script(string title, string? shell) => new()
    {
        Title = title,
        SystemPrompt = "",
        Type = CustomActionType.ShellScript,
        ScriptSource = "Write-Output $env:POPGUY_TEXT",
        Shell = shell,
    };

    [Fact]
    public void ExportReimportsWithPowerShellScriptsRunnable()
    {
        var json = ActionExport.Serialize([Script("Windows", "powershell"), Script("Mac", null)]);

        Assert.Contains("\"shell\": \"powershell\"", Encoding.UTF8.GetString(json));
        var result = ActionImport.SanitizeImported(json);
        Assert.Null(result.Rejection);
        var (windows, mac) = (result.Actions[0], result.Actions[1]);
        Assert.Equal("Windows", windows.Action.Title);
        Assert.False(windows.WrittenForMacShell);
        Assert.True(windows.Action.IsEnabled);
        Assert.True(mac.WrittenForMacShell);
        Assert.False(mac.Action.IsEnabled);
    }

    [Fact]
    public void NativeJsonGetsTheAdapterWindowsNotes()
    {
        var reveal = ActionImport.SanitizeImported(File.ReadAllBytes(MacExample("reveal-in-finder.json")));
        var wikipedia = ActionImport.SanitizeImported(File.ReadAllBytes(MacExample("search-wikipedia.json")));
        var appleScript = ActionImport.SanitizeImported(ActionExport.Serialize(
            [new CustomAction { Title = "Tell", SystemPrompt = "", Type = CustomActionType.AppleScript, ScriptSource = "beep" }]));

        var consent = ImportConsent.FromNative("reveal-in-finder", reveal);

        Assert.Equal("reveal-in-finder", consent.SourceName);
        Assert.Empty(consent.Skipped);
        Assert.Equal(PopClipAdapter.WrittenForZshReason, Assert.Single(consent.Actions).WindowsNote);
        Assert.All(ImportConsent.FromNative("w", wikipedia).Actions, a => Assert.Null(a.WindowsNote));
        Assert.Equal(PopClipAdapter.NotRunnableOnWindowsReason, Assert.Single(ImportConsent.FromNative("a", appleScript).Actions).WindowsNote);
    }

    [Fact]
    public void PluginWindowsNotesMoveToTheirCardAndOtherNotesStay()
    {
        var result = PopClipAdapter.Adapt(PopClipReader.ReadFolder(MacExample("Alfred.popclipext")));

        var consent = ImportConsent.FromPlugin(result);

        Assert.Equal(PopClipAdapter.NotRunnableOnWindowsReason, Assert.Single(consent.Actions).WindowsNote);
        Assert.Equal(new SkippedItem("Alfred", "icon 'bowler.png' not supported, using default icon"), Assert.Single(consent.Skipped));
        Assert.Equal(0, consent.UnsupportedProviderCount);
    }

    [Fact]
    public void ProviderRefusalsAreCountedForTheAlert()
    {
        var json = ActionExport.Serialize(
        [
            new CustomAction { Title = "Bad", SystemPrompt = "Fix {{text}}", ProviderKind = ProviderKind.DeepL },
            new CustomAction { Title = "Good", SystemPrompt = "Fix {{text}}" },
        ]);

        var consent = ImportConsent.FromNative("f", ActionImport.SanitizeImported(json));

        Assert.Equal("Good", Assert.Single(consent.Actions).Imported.Action.Title);
        Assert.Equal(1, consent.UnsupportedProviderCount);
        Assert.Equal("Skipped 1 action whose provider is not valid for its action type.", ImportConsent.UnsupportedProviderMessage(1));
        Assert.Equal("Skipped 2 actions whose provider is not valid for its action type.", ImportConsent.UnsupportedProviderMessage(2));
    }
}
