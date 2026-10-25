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
}
