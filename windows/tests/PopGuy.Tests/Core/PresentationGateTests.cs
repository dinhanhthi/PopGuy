using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;

namespace PopGuy.Tests.Core;

// Contract: the toolbar's show gates in macOS order (ToolbarController.handleEvent, ReentrantSelectionGuardTests): empty
// text, re-entrancy, ignored app (own process never counts), ignored domain, no enabled action. Regression (memory
// speak-reentrant-selection-guard): Speak never sets the action state, so a trailing same-text event while it plays or
// offers "Listen again" must not re-present the toolbar (which stopped playback and moved the panel).
public sealed class PresentationGateTests
{
    private static readonly AppSettings Settings = new()
    {
        IgnoredAppExeNames = ["keepass.exe", "popguy.exe", " 1Password.exe "],
        IgnoredDomainsEnabled = true,
        IgnoredDomains = ["notion.so"],
    };

    private static readonly AppSettings NoActions = Settings with
    {
        ImproveEnabled = false,
        ShortenEnabled = false,
        ProofreadEnabled = false,
        TranslateEnabled = false,
        SpeakEnabled = false,
    };

    private static readonly PresentationInput Shown = new(
        Text: "hello world", IsShowing: true, CurrentText: "hello world", SourceExeName: "notepad.exe");

    public static TheoryData<string, PresentationInput, AppSettings, PresentationVerdict> Cases => new()
    {
        { "empty text", Shown with { Text = "" }, Settings, PresentationVerdict.EmptyText },
        { "action running, same text", Shown with { ActionInProgress = true }, Settings, PresentationVerdict.Reentrant },
        { "action running, new text", Shown with { ActionInProgress = true, Text = "new" }, Settings, PresentationVerdict.Show },
        { "idle, same text: reposition", Shown, Settings, PresentationVerdict.Show },
        { "hidden", Shown with { IsShowing = false, ActionInProgress = true }, Settings, PresentationVerdict.Show },
        { "speak playing, same text", Shown with { SpeakActive = true }, Settings, PresentationVerdict.Reentrant },
        { "listen again shown, same text", Shown with { CanReplaySpeak = true }, Settings, PresentationVerdict.Reentrant },
        { "ignored exe, any case", Shown with { SourceExeName = "KeePass.exe" }, Settings, PresentationVerdict.IgnoredApp },
        { "ignored exe, entry padded", Shown with { SourceExeName = "1password.exe" }, Settings, PresentationVerdict.IgnoredApp },
        { "ignored exe, full path", Shown with { SourceExeName = @"C:\Program Files\KeePass\KeePass.exe" }, Settings, PresentationVerdict.IgnoredApp },
        { "null exe entry matches nothing", Shown, Settings with { IgnoredAppExeNames = [null!, "keepass.exe"] }, PresentationVerdict.Show },
        { "blank exe entries match an empty source", Shown with { SourceExeName = "" }, Settings with { IgnoredAppExeNames = [" ", @"C:\foo\"] }, PresentationVerdict.Show },
        { "ignored apps off", Shown with { SourceExeName = "keepass.exe" }, Settings with { IgnoredAppsEnabled = false }, PresentationVerdict.Show },
        { "own process is never ignored", Shown with { SourceExeName = "PopGuy.exe", IsOwnProcess = true, SourceHost = "notion.so" }, Settings, PresentationVerdict.Show },
        { "ignored subdomain", Shown with { SourceHost = "team.notion.so" }, Settings, PresentationVerdict.IgnoredDomain },
        { "suffix is not a subdomain", Shown with { SourceHost = "evilnotion.so" }, Settings, PresentationVerdict.Show },
        { "null domain entry matches nothing", Shown with { SourceHost = "example.com" }, Settings with { IgnoredDomains = [null!, "notion.so"] }, PresentationVerdict.Show },
        { "ignored domains off", Shown with { SourceHost = "notion.so" }, Settings with { IgnoredDomainsEnabled = false }, PresentationVerdict.Show },
        { "no enabled action", Shown, NoActions, PresentationVerdict.NoEnabledAction },
    };

    [Theory]
    [MemberData(nameof(Cases))]
    public void EvaluateAppliesTheGatesInMacOSOrder(string name, PresentationInput input, AppSettings settings, PresentationVerdict expected)
    {
        var result = PresentationGate.Evaluate(input, settings);

        Assert.True(result.Verdict == expected, $"{name}: expected {expected}, got {result.Verdict}");
        if (input.IsOwnProcess)
            Assert.Equal(new PresentationResult(PresentationVerdict.Show, null, null), result);
    }

    // Security (privacy control): a user-typed entry or a browser host in another form must still match, and an entry
    // that normalizes to nothing must match nothing.
    [Theory]
    [InlineData("team.notion.so", "notion.so", true)]
    [InlineData("evilnotion.so", "notion.so", false)]
    [InlineData("bank.com", "www.bank.com", true)]
    [InlineData("bank.com", ".bank.com", true)]
    [InlineData("bank.com", " bank.com", true)]
    [InlineData("bank.com", "https://bank.com", true)]
    [InlineData("bank.com", "Bank.com/", true)]
    [InlineData("login.bank.com", "https://user@bank.com:443/path?q=1#top", true)]
    [InlineData("bank.com.", "bank.com", true)]
    [InlineData("www.bank.com", "bank.com", true)]
    [InlineData("bank.com.", "", false)]
    [InlineData("bank.com", "/", false)]
    public void HostMatchesNormalizesBothSides(string host, string entry, bool expected) =>
        Assert.Equal(expected, PresentationGate.HostMatches(host, entry));

    // Contract (privacy): the browser reader keeps only the host of a web page's address. Address bars hide "https://",
    // so a bare host counts; browser pages, local files and other schemes have no host, and a search being typed is none.
    [Theory]
    [InlineData("https://www.Notion.so/team/page?x=1#top", "notion.so")]
    [InlineData("http://example.com", "example.com")]
    [InlineData("github.com/foo/bar", "github.com")]
    [InlineData("  docs.github.com  ", "docs.github.com")]
    [InlineData("localhost:3000/app", "localhost")]
    [InlineData("https://user@bank.com:8443/x:y", "bank.com")]
    [InlineData("chrome://newtab", null)]
    [InlineData("edge://settings/privacy", null)]
    [InlineData("about:blank", null)]
    [InlineData("file:///C:/Users/me/doc.html", null)]
    [InlineData("view-source:https://example.com", null)]
    [InlineData("mailto:me@example.com", null)]
    [InlineData("data:text/html,hello.world", null)]
    [InlineData("https://xn--mnchen-3ya.de/karte", "xn--mnchen-3ya.de")]
    [InlineData("https://www.münchen.de/karte", "xn--mnchen-3ya.de")]
    [InlineData("https://ex\"ample.com/", null)]
    [InlineData("search for example.com", null)]
    [InlineData("hello", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void NormalizeHostKeepsOnlyAWebPageHost(string? address, string? expected) =>
        Assert.Equal(expected, PresentationGate.NormalizeHost(address));

    // Contract: Settings → Ignore stores a typed domain in the gate's form; what the gate cannot match is refused, and
    // so is anything but an ASCII host (it goes into AI prompts); a Unicode domain is stored as its punycode form.
    [Theory]
    [InlineData("  Notion.SO/  ", "notion.so")]
    [InlineData("https://www.notion.so/foo/bar", "notion.so")]
    [InlineData("localhost", "localhost")]
    [InlineData("https://", null)]
    [InlineData("notion", null)]
    [InlineData("not ion.so", null)]
    [InlineData("xn--mnchen-3ya.de", "xn--mnchen-3ya.de")]
    [InlineData("my_host.example.com", "my_host.example.com")]
    [InlineData("münchen.de", "xn--mnchen-3ya.de")]
    [InlineData("{{domain}}.com", null)]
    [InlineData("a\"b.com", null)]
    [InlineData("a'b.com", null)]
    public void NormalizeDomainIsTheStoredForm(string raw, string? expected) =>
        Assert.Equal(expected, PresentationGate.NormalizeDomain(raw));

    // Contract: Settings → Ignore edits the list with the gate's rule. A picked path is stored as its lowercase file
    // name, once whatever its case; Remove drops every entry the gate would match, so a removed app shows again.
    [Fact]
    public void IgnoredAppsAddStoresTheKeyOnce()
    {
        IReadOnlyList<string> list = [" KeePass.exe "];

        Assert.Same(list, IgnoredApps.Add(list, @"C:\Program Files\KeePass\keepass.EXE"));
        Assert.Equal([" KeePass.exe ", "notepad.exe"], IgnoredApps.Add(list, @"C:\Windows\System32\Notepad.exe"));
        Assert.Same(list, IgnoredApps.Add(list, @"C:\foo\"));
    }

    [Fact]
    public void IgnoredAppsRemoveDropsEveryMatchingEntry()
    {
        var settings = Settings with { IgnoredAppExeNames = ["keepass.exe", null!, @"D:\Apps\KeePass.EXE", "notepad.exe"] };
        var removed = settings with { IgnoredAppExeNames = IgnoredApps.Remove(settings.IgnoredAppExeNames, "KeePass.exe") };

        Assert.Equal([null!, "notepad.exe"], removed.IgnoredAppExeNames);
        Assert.Equal(PresentationVerdict.Show, PresentationGate.Evaluate(Shown with { SourceExeName = "keepass.exe" }, removed).Verdict);
        Assert.Equal(["keepass.exe", "notepad.exe"], IgnoredApps.Keys(settings.IgnoredAppExeNames));
    }
}
