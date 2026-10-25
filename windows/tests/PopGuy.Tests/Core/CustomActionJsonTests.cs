using System.Diagnostics;
using System.Text.Json;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;

namespace PopGuy.Tests.Core;

// Contract: the custom-action JSON shared with the macOS app (spec-3 §2, CustomAction.swift).
public class CustomActionJsonTests
{
    // Regenerates the cross-platform fixtures: run these tests, then the macOS CrossPlatformActionsFixtureTests,
    // both with the variable set.
    private static readonly bool WriteFixtures = Environment.GetEnvironmentVariable("POPGUY_WRITE_FIXTURES") == "1";

    /// <summary>A cross-platform fixture in the source tree (not bin/): both apps' writers update the committed files.</summary>
    private static string FixturePath(string fileName)
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "windows", "PopGuy.slnx")))
                return Path.Combine(dir.FullName, "windows", "tests", "PopGuy.Tests", "Fixtures", fileName);
        }
        throw new DirectoryNotFoundException("Repository root (windows/PopGuy.slnx) not found.");
    }

    private static CustomAction DecodeMacExample(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "macos-examples", fileName);
        var actions = JsonSerializer.Deserialize<List<CustomAction>>(File.ReadAllText(path), PopGuyJson.Options);
        return Assert.Single(actions!);
    }

    [Fact]
    public void MacExampleOpenUrlDecodes()
    {
        var action = DecodeMacExample("search-wikipedia.json");

        Assert.Equal(Guid.Parse("A1B2C3D4-E5F6-7890-ABCD-EF1234567890"), action.Id);
        Assert.Equal("Wikipedia", action.Title);
        Assert.Equal(CustomActionType.OpenUrl, action.Type);
        Assert.Equal(ActionIcon.SfSymbol("book.fill"), action.Icon);
        Assert.Equal(ProviderKind.Anthropic, action.ProviderKind);
        Assert.Equal("https://en.wikipedia.org/w/index.php?search={text}", action.ScriptSource);
        Assert.Equal(AfterRunBehavior.CloseToolbar, action.AfterRun);
        // Keys absent from the file take the Swift decode fallbacks.
        Assert.Equal("en", action.TargetLanguage);
        Assert.False(action.IsFromPlugin);
        Assert.Null(action.LibraryPresetId);
    }

    [Fact]
    public void MacExampleShellScriptDecodesAndFiltersBySelection()
    {
        var action = DecodeMacExample("reveal-in-finder.json");

        Assert.Equal("Reveal in Finder", action.Title);
        Assert.Equal(CustomActionType.ShellScript, action.Type);
        Assert.Equal("open -R \"$POPGUY_TEXT\"", action.ScriptSource);
        Assert.Equal("^(/|~|file://)", action.AppliesWhenRegex);
        Assert.True(action.IsVisible("/Users/thi/notes.txt"));
        Assert.False(action.IsVisible("hello world"));
    }

    [Fact]
    public void RoundTripWritesAllKeysAndOptionalKeysOnlyWhenSet()
    {
        var plain = new CustomAction
        {
            Title = "Summarise",
            SystemPrompt = "Summarise {{text}} in one sentence.",
            Icon = ActionIcon.Emoji("✨"),
            Type = CustomActionType.Translation,
            ProviderKind = ProviderKind.GoogleTranslate,
            Tone = TranslateTone.Friendly,
            SpeakSettings = new SpeakSettings
            {
                SelectedEngine = SpeakEngineSelection.Cloud(TtsProviderKind.OpenAiTts),
                QuickSwitchAccents = [SpeakAccent.French],
            },
            TtsConfig = new TtsProviderConfig { VoiceOverrides = new Dictionary<string, string> { ["fr"] = "marin" } },
        };
        var withOptionals = plain with { LibraryPresetId = "ai.humanize", Shell = "powershell" };

        foreach (var (action, expectedKeys) in new[] { (plain, 18), (withOptionals, 20) })
        {
            var json = JsonSerializer.Serialize(action, PopGuyJson.Options);
            var decoded = JsonSerializer.Deserialize<CustomAction>(json, PopGuyJson.Options)!;

            Assert.Equal(json, JsonSerializer.Serialize(decoded, PopGuyJson.Options));
            Assert.Equal(action.Id, decoded.Id);
            Assert.Equal(action.LibraryPresetId, decoded.LibraryPresetId);
            Assert.Equal(action.Shell, decoded.Shell);

            using var doc = JsonDocument.Parse(json);
            var keys = doc.RootElement.EnumerateObject().Select(p => p.Name).ToList();
            Assert.Equal(expectedKeys, keys.Count);
            Assert.Equal(action.LibraryPresetId is not null, keys.Contains("libraryPresetID"));
            Assert.Equal(action.Shell is not null, keys.Contains("shell"));
            // Swift writes the UUID uppercase.
            Assert.Equal(action.Id.ToString("D").ToUpperInvariant(), doc.RootElement.GetProperty("id").GetString());
        }
    }

    [Fact]
    public void WriteWindowsExportedActionsFixture()
    {
        if (!WriteFixtures)
            Assert.Skip("Set POPGUY_WRITE_FIXTURES=1 to regenerate windows-exported-actions.json");

        // Fixed ids keep the committed fixture stable across writer runs.
        static CustomAction Fixture(int number, string title, CustomActionType type, ActionIcon icon, ProviderKind provider) =>
            new()
            {
                Id = Guid.Parse($"00000000-0000-4000-9000-{number:D12}"),
                Title = title,
                SystemPrompt = "",
                Type = type,
                Icon = icon,
                ProviderKind = provider,
            };

        List<CustomAction> actions =
        [
            Fixture(1, "Windows AI", CustomActionType.Ai, ActionIcon.Emoji("✨"), ProviderKind.OpenAi) with
            {
                SystemPrompt = "Rewrite {{text}} plainly.",
                Model = "gpt-5",
                LibraryPresetId = "ai.humanize",
            },
            Fixture(2, "Windows Translate", CustomActionType.Translation, ActionIcon.SfSymbol("globe"), ProviderKind.GoogleTranslate) with
            {
                TargetLanguage = "de",
                Tone = TranslateTone.Casual,
            },
            Fixture(3, "Windows Speak", CustomActionType.Speech, ActionIcon.SfSymbol("speaker.wave.3"), ProviderKind.Anthropic) with
            {
                SpeakSettings = new SpeakSettings { SelectedEngine = SpeakEngineSelection.Cloud(TtsProviderKind.AzureTts) },
                TtsConfig = new TtsProviderConfig { Region = "eastus" },
            },
            Fixture(4, "Windows Define", CustomActionType.Dictionary, ActionIcon.Emoji("📚"), ProviderKind.Ollama) with
            {
                DictionaryConfig = new DictionaryConfig { Provider = DictionaryProviderKind.Minhqnd, DefinitionLanguage = "vi" },
            },
            Fixture(5, "Windows Search", CustomActionType.OpenUrl, ActionIcon.SfSymbol("safari"), ProviderKind.Gemini) with
            {
                ScriptSource = "https://www.bing.com/search?q={text}",
            },
            Fixture(6, "Windows Shortcut", CustomActionType.RunShortcut, ActionIcon.SfSymbol("bolt"), ProviderKind.Custom) with
            {
                ScriptSource = "Make PDF",
            },
            Fixture(7, "Windows AppleScript", CustomActionType.AppleScript, ActionIcon.Emoji("📜"), ProviderKind.ClaudeCli) with
            {
                ScriptSource = "display dialog \"{text}\"",
            },
            Fixture(8, "Windows PowerShell", CustomActionType.ShellScript, ActionIcon.SfSymbol("terminal.fill"), ProviderKind.CodexCli) with
            {
                ScriptSource = "Get-Date",
                AfterRun = AfterRunBehavior.ShowResult,
                Shell = "powershell",
            },
        ];
        Assert.Equal(Enum.GetValues<CustomActionType>(), actions.Select(a => a.Type));

        var path = FixturePath("windows-exported-actions.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(actions, PopGuyJson.Options));
    }

    [Fact]
    public void MacExportedActionsImport()
    {
        var path = FixturePath("macos-exported-actions.json");
        if (!File.Exists(path) && WriteFixtures)
            Assert.Skip("macos-exported-actions.json missing (writer run)");

        var result = ActionImport.SanitizeImported(File.ReadAllBytes(path));

        Assert.Null(result.Rejection);
        Assert.Equal(0, result.SkippedCount);
        (string Title, CustomActionType Type, ActionIcon Icon, ProviderKind Provider)[] expected =
        [
            ("Mac AI", CustomActionType.Ai, ActionIcon.Emoji("🪄"), ProviderKind.Anthropic),
            ("Mac Translate", CustomActionType.Translation, ActionIcon.SfSymbol("character.bubble"), ProviderKind.DeepL),
            ("Mac Speak", CustomActionType.Speech, ActionIcon.SfSymbol("speaker.wave.2"), ProviderKind.OpenAi),
            ("Mac Define", CustomActionType.Dictionary, ActionIcon.Emoji("📖"), ProviderKind.Gemini),
            ("Mac Search", CustomActionType.OpenUrl, ActionIcon.SfSymbol("magnifyingglass"), ProviderKind.Ollama),
            ("Mac Shortcut", CustomActionType.RunShortcut, ActionIcon.SfSymbol("square.stack.3d.up"), ProviderKind.Glm),
            ("Mac AppleScript", CustomActionType.AppleScript, ActionIcon.Emoji("🍎"), ProviderKind.OpenRouter),
            ("Mac Shell", CustomActionType.ShellScript, ActionIcon.SfSymbol("terminal"), ProviderKind.MlxLocal),
        ];
        Assert.Equal(expected, result.Actions.Select(a => (a.Action.Title, a.Action.Type, a.Action.Icon, a.Action.ProviderKind)));

        var actions = result.Actions.Select(a => a.Action).ToList();
        Assert.Equal("fr", actions[1].TargetLanguage);
        Assert.Equal(TranslateTone.Formal, actions[1].Tone);
        Assert.Equal(SpeakEngineSelection.Cloud(TtsProviderKind.OpenAiTts), actions[2].SpeakSettings.SelectedEngine);
        Assert.Equal("marin", actions[2].TtsConfig.VoiceOverrides["fr"]);
        Assert.Equal(DictionaryProviderKind.FreeDictionaryApi, actions[3].DictionaryConfig.Provider);
        // Foundation escapes "/" as "\/" in the macOS file.
        Assert.Equal("https://example.com/search?q={text}", actions[4].ScriptSource);
        Assert.True(actions[4].IsVisible("word"));
        Assert.False(actions[4].IsVisible("two words"));
        Assert.Equal(AfterRunBehavior.ShowResult, actions[5].AfterRun);
        Assert.False(actions[5].RunnableOnWindows);
        Assert.False(actions[6].RunnableOnWindows);
        // macOS scripts carry no "shell": imported disabled, flagged as written for zsh.
        Assert.Equal(AfterRunBehavior.PasteResult, actions[7].AfterRun);
        Assert.True(result.Actions[7].WrittenForMacShell);
        Assert.False(actions[7].IsEnabled);
    }

    [Fact]
    public void CatastrophicOrInvalidRegexFailsOpen()
    {
        var action = new CustomAction
        {
            Title = "Probe",
            SystemPrompt = "",
            Type = CustomActionType.ShellScript,
            AppliesWhenRegex = "(a+)+$",
        };
        // No match exists, so only the timeout path can return true.
        var selection = new string('a', 64) + "!";

        var stopwatch = Stopwatch.StartNew();
        var visible = action.IsVisible(selection);
        stopwatch.Stop();

        Assert.True(visible);
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(2), $"took {stopwatch.Elapsed}");
        Assert.True((action with { AppliesWhenRegex = "([unclosed" }).IsVisible("anything"));
    }
}
