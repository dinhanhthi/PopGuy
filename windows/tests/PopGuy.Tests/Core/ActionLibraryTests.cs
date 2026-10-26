using PopGuy.Core.Actions;
using PopGuy.Core.Library;
using PopGuy.Core.Scripts;
using PopGuy.Core.Settings;

namespace PopGuy.Tests.Core;

// Parity with the macOS catalog (ActionLibrary*.swift) and the install contract (macOS installableAction). Security:
// a preset script gets the selection only from the environment, and an Open URL preset only opens https.
public sealed class ActionLibraryTests
{
    // Every macOS preset id, in macOS catalog order (ActionLibrary+AI/Web/Text/Dev/Apps.swift).
    private static readonly string[] MacPresetIds =
    [
        // AI Writing
        "ai.humanize",
        // Search Engines
        "search.google", "search.bing", "search.duckduckgo", "search.brave", "search.ecosia", "search.kagi",
        "search.startpage", "search.yandex", "search.baidu", "search.qwant", "search.naver", "search.yahoo",
        // Websites
        "web.wikipedia", "web.youtube", "web.imdb", "web.amazon", "web.github", "web.stackoverflow", "web.mdn",
        "web.devdocs", "web.wolframalpha", "web.googlescholar", "web.googleimages", "web.goodreads", "web.letterboxd",
        "web.rottentomatoes", "web.urbandictionary", "web.waybackmachine", "web.pubmed", "web.reddit", "web.twitter",
        "web.spotify", "web.applemusic",
        // Maps
        "maps.apple", "maps.google", "maps.openstreetmap", "maps.what3words",
        // AI Launchers
        "ai.chatgpt", "ai.claude", "ai.grok", "ai.perplexity", "ai.gemini",
        // Translate
        "translate.google", "translate.deepl", "translate.bing", "translate.reverso",
        // Text Transform
        "text.uppercase", "text.lowercase", "text.titlecase", "text.capitalize", "text.sentencecase", "text.slugify",
        "text.hyphenate", "text.underscore", "text.removespaces", "text.joinlines", "text.sortlines",
        "text.reverselineorder", "text.shufflelines", "text.alternatingcase", "text.rot13", "text.reversestring",
        // Developer Tools
        "dev.base64encode", "dev.base64decode", "dev.urlencode", "dev.urldecode", "dev.htmlencode", "dev.htmldecode",
        "dev.sha256", "dev.md5", "dev.unixtimetodate", "dev.datetounixtime", "dev.jsonprettyprint", "dev.wordcount",
        "dev.charactercount", "dev.linecount", "dev.calculate",
        // Apps
        "apps.bear", "apps.drafts", "apps.obsidian", "apps.craft", "apps.dayone", "apps.tot", "apps.things",
        "apps.todoist", "apps.omnifocus", "apps.goodlinks", "apps.anybox", "apps.raindrop", "apps.pocket",
        "apps.instapaper", "apps.call", "apps.facetime",
    ];

    // Not on Windows: the Apps category opens macOS apps or non-http(s) schemes the script engine refuses.
    private static readonly string[] ExcludedOnWindows = MacPresetIds.Where(id => id.StartsWith("apps.")).ToArray();

    [Fact]
    public void PresetsAreTheMacCatalogWithoutTheApps()
    {
        Assert.Equal(MacPresetIds.Except(ExcludedOnWindows), ActionLibrary.AllPresets().Select(p => p.Id));

        // 46 Open URL (search, websites, maps, AI and translate launchers), 1 AI, 31 text/dev transforms.
        var actions = ActionLibrary.AllPresets().Select(p => p.Make()).ToList();
        Assert.Equal(46, actions.Count(a => a.Type == CustomActionType.OpenUrl));
        Assert.Equal(1, actions.Count(a => a.Type == CustomActionType.Ai));
        Assert.Equal(31, actions.Count(a => a.Type == CustomActionType.ShellScript && a.Shell == "powershell"));
        Assert.Equal(78, actions.Count);
    }

    [Fact]
    public void ScriptsTakeTheSelectionOnlyFromTheEnvironment()
    {
        foreach (var action in ActionLibrary.AllPresets().Select(p => p.Make()))
        {
            if (action.Type == CustomActionType.OpenUrl)
            {
                Assert.StartsWith("https://", action.ScriptSource, StringComparison.Ordinal);
                Assert.Contains(PlaceholderExpander.TextToken, action.ScriptSource, StringComparison.Ordinal);
            }
            else if (action.Type == CustomActionType.ShellScript)
            {
                Assert.Contains("$env:POPGUY_TEXT", action.ScriptSource, StringComparison.Ordinal);
                Assert.DoesNotMatch(@"(?i)invoke-expression|\biex\b|scriptblock|\.invoke\(|\{text\}", action.ScriptSource);
            }
        }
    }

    [Fact]
    public void InstallableActionTagsThePresetAndKeepsPowerShellEnabled()
    {
        var preset = ActionLibrary.Find("text.uppercase")!;

        var action = ActionLibrary.InstallableAction(preset, new AppSettings())!;

        Assert.False(action.IsFromPlugin);
        Assert.Equal("text.uppercase", action.LibraryPresetId);
        Assert.True(action.IsEnabled);
        Assert.Equal("powershell", action.Shell);
        // Installed is keyed by the preset id, not by an equal script.
        Assert.True(ActionLibrary.IsInstalled(preset, [action]));
        Assert.False(ActionLibrary.IsInstalled(preset, [preset.Make()]));
    }

    [Fact]
    public void InstallableAiPresetRunsOnImprovesProviderAndModel()
    {
        var settings = new AppSettings { ImproveConfig = new ActionConfig(ActionKind.Improve, ProviderKind.Ollama, "llama3.3") };

        var action = ActionLibrary.InstallableAction(ActionLibrary.Find("ai.humanize")!, settings)!;

        Assert.Equal(CustomActionType.Ai, action.Type);
        Assert.Equal(ProviderKind.Ollama, action.ProviderKind);
        Assert.Equal("llama3.3", action.Model);
        Assert.False(action.IsFromPlugin);
        Assert.Equal("ai.humanize", action.LibraryPresetId);
    }

    // Expected values are the macOS outputs, from the zsh sources run with LANG=en_US.UTF-8 (as macOS runs them).
    [Theory]
    [InlineData("text.uppercase", "Héllo Wörld", "HÉLLO WÖRLD")]
    [InlineData("text.slugify", "Héllo Wörld!  Ça va? -- Ünïcödé_2026", "hello-world-ca-va-unicode-2026")]
    [InlineData("dev.base64encode", "Héllo Wörld", "SMOpbGxvIFfDtnJsZA==")]
    public async Task PowerShellPresetsMatchTheMacOutput(string id, string text, string expected)
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("PowerShell scripts run on Windows only.");
        var action = ActionLibrary.InstallableAction(ActionLibrary.Find(id)!, new AppSettings())!;

        var result = await new ScriptActionEngine().RunAsync(action, text, text, TestContext.Current.CancellationToken);

        Assert.Equal(expected, result.Text);
    }
}
