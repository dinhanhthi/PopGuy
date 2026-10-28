using System.Text.Json;
using PopGuy.Core.Updates;

namespace PopGuy.Tests.Core;

// Contract: the Windows update check reads only the releases of the shared repository that carry a Velopack feed.
public sealed class ReleaseSelectorTests
{
    private const string Releases = """
        [
          { "tag_name": "v1.5.0", "name": "next", "draft": true, "prerelease": false,
            "published_at": null, "assets": [ { "name": "releases.win-x64.json" } ] },
          { "tag_name": "windows-v1.4.1-dev", "draft": false, "prerelease": false,
            "published_at": "2026-10-30T10:00:00Z", "assets": [ { "name": "releases.win-x64.json" } ] },
          { "tag_name": "v1.4.0", "name": "PopGuy 1.4.0", "draft": false, "prerelease": false,
            "published_at": "2026-10-29T10:00:00Z",
            "assets": [ { "name": "PopGuy-1.4.0.zip" },
                        { "name": "releases.win-x64.json",
                          "browser_download_url": "https://github.com/dinhanhthi/PopGuy/releases/download/v1.4.0/releases.win-x64.json" } ] },
          { "tag_name": "v1.4.0-beta", "draft": false, "prerelease": true,
            "published_at": "2026-10-20T10:00:00Z", "assets": [ { "name": "releases.win-arm64.json" } ] },
          { "tag_name": "v1.3.2", "name": "PopGuy 1.3.2", "draft": false, "prerelease": false,
            "published_at": "2026-10-15T20:54:37Z",
            "assets": [ { "name": "PopGuy-1.3.2.zip" }, { "name": "PopGuy-1.3.2.dmg" } ] },
          { "tag_name": "windows-v0.1.0", "name": "PopGuy for Windows 0.1.0", "draft": false, "prerelease": false,
            "published_at": "2026-10-13T10:00:00Z", "assets": [ { "name": "releases.win-arm64.json" } ] }
        ]
        """;

    [Fact]
    public void OnlyPublishedReleasesWithAFeedAreReadNeverAQaBuild()
    {
        var selected = ReleaseSelector.WindowsReleases(ReleaseSelector.Parse(Releases), includePrereleases: false);

        Assert.Equal(["v1.4.0", "windows-v0.1.0"], selected.Select(r => r.TagName));
        Assert.Equal("releases.win-x64.json", selected[0].Assets![1].Name);
    }

    [Fact]
    public void PrereleasesAreReadOnlyWhenAsked()
    {
        var selected = ReleaseSelector.WindowsReleases(ReleaseSelector.Parse(Releases), includePrereleases: true);

        Assert.Equal(["v1.4.0", "v1.4.0-beta", "windows-v0.1.0"], selected.Select(r => r.TagName));
    }

    [Fact]
    public void AnUnreadableResponseFailsTheCheck() =>
        Assert.ThrowsAny<JsonException>(() => ReleaseSelector.Parse("<html>sign in to the network</html>"));
}
