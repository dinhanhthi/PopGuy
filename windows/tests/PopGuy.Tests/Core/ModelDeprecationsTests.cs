using System.Text.Json.Nodes;
using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Settings;

namespace PopGuy.Tests.Core;

// Contract: the deprecated-model maps (ModelDeprecationsTests.swift) and their migration of saved settings on load,
// persisted (SettingsStore.swift init). The curated-model invariants are not ported: Windows has no curated lists yet.
public sealed class ModelDeprecationsTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "PopGuyTests-" + Guid.NewGuid().ToString("N"));
    private readonly AppPaths _paths;

    public ModelDeprecationsTests() => _paths = AppPaths.Resolve(_root);

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

    [Theory]
    [InlineData(ProviderKind.OpenAi, "gpt-5.4-nano", "gpt-6-luna")]
    [InlineData(ProviderKind.OpenAi, "gpt-5.5", "gpt-5.5")] // legacy but active on the API
    [InlineData(ProviderKind.CodexCli, "gpt-5.5", "gpt-6.1-sol")]
    [InlineData(ProviderKind.CodexCli, "gpt-5.4-nano", "gpt-6-luna")] // inherited from OpenAI
    [InlineData(ProviderKind.CodexCli, "gpt-5.3-codex", "gpt-6.1-sol")] // the Codex override wins
    [InlineData(ProviderKind.Anthropic, "claude-sonnet-4-5-20250929", "claude-sonnet-5-5")]
    [InlineData(ProviderKind.ClaudeCli, "claude-sonnet-4-5-20250929", "claude-sonnet-5-5")]
    [InlineData(ProviderKind.Anthropic, "claude-opus-4-8", "claude-opus-4-8")]
    [InlineData(ProviderKind.Gemini, "gemini-3.1-pro", "gemini-4-argon")]
    [InlineData(ProviderKind.GeminiCli, "gemini-3-pro", "gemini-3.1-pro-preview")]
    [InlineData(ProviderKind.OpenRouter, "anthropic/claude-opus-4-8", "anthropic/claude-opus-5.5")]
    [InlineData(ProviderKind.OpenAi, "  gpt-5.4-nano\n", "gpt-6-luna")]
    [InlineData(ProviderKind.OpenAi, "my-fine-tune", "my-fine-tune")]
    [InlineData(ProviderKind.OpenAi, "", "")]
    [InlineData(ProviderKind.Glm, "glm-4.7", "glm-4.7")]
    public void MigratedModel(ProviderKind kind, string model, string expected) =>
        Assert.Equal(expected, kind.MigratedModel(model));

    [Fact]
    public void TtsMigratedModel()
    {
        Assert.Equal("gpt-4o-mini-tts", TtsProviderKind.OpenAiTts.MigratedModel("tts-1-hd"));
        Assert.Null(TtsProviderKind.OpenAiTts.MigratedModel(null));
    }

    [Fact]
    public void NoReplacementIsItselfADeprecatedKey()
    {
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            var map = kind.DeprecatedModelReplacements();
            foreach (var (key, value) in map)
                Assert.False(map.ContainsKey(value), $"{kind}: {key} -> {value} is itself a key");
        }
        foreach (var kind in Enum.GetValues<TtsProviderKind>())
        {
            var map = kind.DeprecatedModelReplacements();
            foreach (var (key, value) in map)
                Assert.False(map.ContainsKey(value), $"{kind}: {key} -> {value} is itself a key");
        }
    }

    [Fact]
    public void DefaultModelsAreNotDeprecated()
    {
        Assert.Same(ActionConfig.DefaultModel, ProviderKind.OpenAi.MigratedModel(ActionConfig.DefaultModel));
        var action = new CustomAction { Title = "t", SystemPrompt = "p" };
        Assert.Same(action, ModelDeprecations.Migrated(action));
    }

    [Fact]
    public void CurrentSettingsComeBackAsTheSameInstance()
    {
        var settings = new AppSettings();

        Assert.Same(settings, ModelDeprecations.Migrated(settings));
    }

    [Fact]
    public void SettingsMigrationReplacesConfigsTtsConfigsAndCustomActions()
    {
        var action = new CustomAction
        {
            Title = "t", SystemPrompt = "p", ProviderKind = ProviderKind.Anthropic, Model = "claude-3-opus-latest",
            TtsConfig = new TtsProviderConfig { Model = "tts-1" },
        };
        var settings = new AppSettings
        {
            ImproveConfig = new ActionConfig(ActionKind.Improve, ProviderKind.OpenAi, "gpt-4o"),
            TranslateConfig = new ActionConfig(ActionKind.Translate, ProviderKind.Gemini, "gemini-3-flash") { Tone = TranslateTone.Formal },
            TtsProviderConfigs = new Dictionary<string, TtsProviderConfig>
            {
                ["openai_tts"] = new() { Model = "tts-1-hd", DefaultVoice = "alloy" },
                ["future_tts"] = new() { Model = "tts-1" },
            },
            CustomActions = [action],
        };

        var migrated = ModelDeprecations.Migrated(settings);

        Assert.Equal("gpt-6-luna", migrated.ImproveConfig.Model);
        Assert.Equal(new ActionConfig(ActionKind.Translate, ProviderKind.Gemini, "gemini-3.6-flash") { Tone = TranslateTone.Formal },
            migrated.TranslateConfig);
        Assert.Same(settings.ShortenConfig, migrated.ShortenConfig);
        Assert.Equal("gpt-4o-mini-tts", migrated.TtsProviderConfigs["openai_tts"].Model);
        Assert.Equal("alloy", migrated.TtsProviderConfigs["openai_tts"].DefaultVoice);
        Assert.Equal("tts-1", migrated.TtsProviderConfigs["future_tts"].Model); // unknown key: untouched
        var migratedAction = Assert.Single(migrated.CustomActions);
        Assert.Equal("claude-opus-4-8", migratedAction.Model);
        Assert.Equal("gpt-4o-mini-tts", migratedAction.TtsConfig.Model);
        Assert.Equal(action.Id, migratedAction.Id);
    }

    [Fact]
    public void LoadMigratesADeprecatedModelAndSavesIt()
    {
        WriteSettingsFile("""
            {
              "improveConfig": { "id": "improve", "providerKind": "openai", "model": "gpt-4o" },
              "principalActionIDs": [],
              "futureKey": 1
            }
            """);

        var store = new SettingsStore(_paths);

        Assert.Equal("gpt-6-luna", store.Current.ImproveConfig.Model);
        var saved = JsonNode.Parse(File.ReadAllText(_paths.SettingsFile))!;
        Assert.Equal("gpt-6-luna", (string?)saved["improveConfig"]!["model"]);
        Assert.Equal(1, (int?)saved["futureKey"]);
    }

    [Fact]
    public void LoadWithCurrentModelsLeavesTheFileUntouched()
    {
        const string json = """{ "improveConfig": { "id": "improve", "providerKind": "openai", "model": "gpt-6-luna" }, "principalActionIDs": [] }""";
        WriteSettingsFile(json);

        _ = new SettingsStore(_paths);

        Assert.Equal(json, File.ReadAllText(_paths.SettingsFile));
    }

    [Fact]
    public void AddCustomActionMigratesItsModel()
    {
        var store = new SettingsStore(_paths);

        store.AddCustomAction(new CustomAction { Title = "t", SystemPrompt = "p", ProviderKind = ProviderKind.OpenAi, Model = "o3" });

        Assert.Equal("gpt-5.6-sol", Assert.Single(store.Current.CustomActions).Model);
    }
}
