using System.Diagnostics;
using System.Text.Json;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;

namespace PopGuy.Tests.Core;

// Contract: the custom-action JSON shared with the macOS app (spec-3 §2, CustomAction.swift).
public class CustomActionJsonTests
{
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
