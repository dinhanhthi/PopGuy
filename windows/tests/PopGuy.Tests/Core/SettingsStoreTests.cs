using System.Text.Json.Nodes;
using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.Settings;

namespace PopGuy.Tests.Core;

// Contract: settings.json (spec-3 §1 with the Windows keys) and the custom-action mutation API (SettingsStore.swift).
public sealed class SettingsStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "PopGuyTests-" + Guid.NewGuid().ToString("N"));
    private readonly AppPaths _paths;

    public SettingsStoreTests() => _paths = AppPaths.Resolve(_root);

    public void Dispose()
    {
        if (Directory.Exists(_root))
            Directory.Delete(_root, recursive: true);
    }

    private void WriteSettingsFile(string json)
    {
        Directory.CreateDirectory(_paths.DataDirectory);
        File.WriteAllText(_paths.SettingsFile, json);
    }

    [Fact]
    public void FreshInstallUsesTheMacOSTriggerDefaults()
    {
        var s = new SettingsStore(_paths).Current;
        var improveHotkey = s.ShortcutBindings.Single(b => b.Id == ActionIdentifier.Builtin(ActionKind.Improve));

        // The toolbar appears only through the chord and the per-action hotkeys (spec-1 §0).
        (string Setting, object Actual, object Expected)[] table =
        [
            ("popGuyEnabled", s.PopGuyEnabled, true),
            ("triggerChord", s.TriggerChordEnabled, true),
            ("triggerOnSelect", s.TriggerOnSelectEnabled, false),
            ("triggerDoubleClick", s.TriggerDoubleClickEnabled, false),
            ("ocrEnabled", s.OcrEnabled, false),
            ("improveEnabled", s.ImproveEnabled, true),
            ("shortenEnabled", s.ShortenEnabled, true),
            ("proofreadEnabled", s.ProofreadEnabled, true),
            ("translateEnabled", s.TranslateEnabled, true),
            ("speakEnabled", s.SpeakEnabled, true),
            ("promptEnabled", s.PromptEnabled, false),
            ("dictionaryConfig.isEnabled", s.DictionaryConfig.IsEnabled, false),
            ("hotkey count", s.ShortcutBindings.Count, 5),
            ("improve hotkey", improveHotkey.Shortcut.ToString(), "Ctrl+Alt+Shift+I"),
        ];
        foreach (var (setting, actual, expected) in table)
            Assert.True(expected.Equals(actual), $"{setting}: expected {expected}, got {actual}");
    }

    [Fact]
    public void UnknownKeySurvivesASave()
    {
        WriteSettingsFile("""{ "triggerChord": false, "futureKey": { "nested": [1, 2] } }""");

        new SettingsStore(_paths).Update(s => s with { TriggerOnSelectEnabled = true });

        var saved = JsonNode.Parse(File.ReadAllText(_paths.SettingsFile))!;
        Assert.Equal("""{"nested":[1,2]}""", saved["futureKey"]!.ToJsonString());
        var reloaded = new SettingsStore(_paths).Current;
        Assert.False(reloaded.TriggerChordEnabled);
        Assert.True(reloaded.TriggerOnSelectEnabled);
    }

    [Fact]
    public void CorruptFileLoadsDefaultsAndKeepsABackup()
    {
        const string corrupt = """{ "triggerChord": false, """;
        WriteSettingsFile(corrupt);

        var s = new SettingsStore(_paths).Current;

        Assert.True(s.TriggerChordEnabled);
        Assert.False(File.Exists(_paths.SettingsFile));
        var backup = Assert.Single(Directory.GetFiles(_paths.DataDirectory, "settings.corrupt-*.json"));
        Assert.Equal(corrupt, File.ReadAllText(backup));
    }

    // Security: API keys live in Windows Credential Manager only, never in settings.json.
    [Fact]
    public void SerializedSettingsContainNoApiKey()
    {
        var store = new SettingsStore(_paths);
        store.AddCustomAction(new CustomAction { Title = "Summarise", SystemPrompt = "Summarise {{text}}." });
        store.Update(s => s with
        {
            ImproveConfig = s.ImproveConfig with { CustomPrompt = "Rewrite.", Tone = TranslateTone.Formal },
            TtsProviderConfigs = new Dictionary<string, TtsProviderConfig>
            {
                ["openai_tts"] = new() { Model = "gpt-4o-mini-tts", DefaultVoice = "marin" },
            },
            ChordReplacementShortcut = new Shortcut(0x43, ShortcutModifiers.Control | ShortcutModifiers.Shift),
        });

        var json = File.ReadAllText(_paths.SettingsFile);

        Assert.Contains("Summarise", json);
        Assert.DoesNotContain("apikey", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void DeleteCustomActionRemovesItsBindingAndLayoutEntries()
    {
        var store = new SettingsStore(_paths);
        var action = new CustomAction { Title = "Summarise", SystemPrompt = "Summarise {{text}}." };
        var id = ActionIdentifier.Custom(action.Id);
        store.AddCustomAction(action);
        store.Update(s => s with
        {
            ShortcutBindings = [.. s.ShortcutBindings, new ShortcutBinding(id, new Shortcut(0x55, ShortcutModifiers.Control))],
            PrincipalActionIds = [id],
            LabeledActionIds = [id],
        });
        Assert.Contains(id, store.Current.ActionOrder);

        var changes = 0;
        store.Changed += (_, _) => changes++;
        store.DeleteCustomAction(action.Id);

        var s = new SettingsStore(_paths).Current;
        Assert.Equal(1, changes);
        Assert.Empty(s.CustomActions);
        Assert.DoesNotContain(s.ShortcutBindings, b => b.Id == id);
        Assert.Equal(5, s.ShortcutBindings.Count);
        Assert.DoesNotContain(id, s.ActionOrder);
        Assert.Empty(s.PrincipalActionIds!);
        Assert.Empty(s.LabeledActionIds);
    }
}
