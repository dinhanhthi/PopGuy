using System.Text.Json;
using PopGuy.Core.Updates;

namespace PopGuy.Tests.Core;

// Contract: the Windows update check reads only the windows-v releases of the repository it shares with macOS.
public sealed class ReleaseSelectorTests
{
    private const string Releases = """
        [
          { "tag_name": "v1.3.2", "name": "PopGuy 1.3.2", "draft": false, "prerelease": false,
            "published_at": "2026-10-15T20:54:37Z", "assets": [ { "name": "PopGuy-1.3.2.dmg" } ] },
          { "tag_name": "windows-v0.2.0", "name": "next", "draft": true, "prerelease": false,
            "published_at": null, "assets": [] },
          { "tag_name": "windows-v0.1.2-dev", "draft": false, "prerelease": false,
            "published_at": "2026-10-16T10:00:00Z", "assets": [] },
          { "tag_name": "windows-v0.1.1-beta", "draft": false, "prerelease": true,
            "published_at": "2026-10-14T10:00:00Z", "assets": [] },
          { "tag_name": "windows-v0.1.0", "name": "PopGuy for Windows 0.1.0", "draft": false, "prerelease": false,
            "published_at": "2026-10-13T10:00:00Z",
            "assets": [ { "name": "releases.win-arm64.json",
                          "browser_download_url": "https://github.com/dinhanhthi/PopGuy/releases/download/windows-v0.1.0/releases.win-arm64.json" } ] },
          { "tag_name": "v1.2.0", "draft": false, "prerelease": false, "published_at": "2026-10-13T09:19:45Z", "assets": [] }
        ]
        """;

    [Fact]
    public void OnlyPublishedWindowsReleasesAreReadNeverAQaBuild()
    {
        var selected = ReleaseSelector.WindowsReleases(ReleaseSelector.Parse(Releases), includePrereleases: false);

        var release = Assert.Single(selected);
        Assert.Equal("windows-v0.1.0", release.TagName);
        Assert.Equal("releases.win-arm64.json", Assert.Single(release.Assets!).Name);
    }

    [Fact]
    public void PrereleasesComeFirstOnlyWhenAsked()
    {
        var selected = ReleaseSelector.WindowsReleases(ReleaseSelector.Parse(Releases), includePrereleases: true);

        Assert.Equal(["windows-v0.1.1-beta", "windows-v0.1.0"], selected.Select(r => r.TagName));
    }

    [Fact]
    public void AnUnreadableResponseFailsTheCheck() =>
        Assert.ThrowsAny<JsonException>(() => ReleaseSelector.Parse("<html>sign in to the network</html>"));
}
