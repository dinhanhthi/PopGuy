using System.Text.Json;
using System.Text.Json.Serialization;

namespace PopGuy.Core.Updates;

/// <summary>One asset of a GitHub release, as the releases API lists it.</summary>
public sealed record GithubAssetInfo(
    [property: JsonPropertyName("name")] string? Name,
    [property: JsonPropertyName("url")] string? Url,
    [property: JsonPropertyName("browser_download_url")] string? BrowserDownloadUrl,
    [property: JsonPropertyName("content_type")] string? ContentType);

/// <summary>One GitHub release, as the releases API lists it (the fields the update check reads).</summary>
public sealed record GithubReleaseInfo(
    [property: JsonPropertyName("tag_name")] string? TagName,
    [property: JsonPropertyName("name")] string? Name,
    [property: JsonPropertyName("draft")] bool Draft,
    [property: JsonPropertyName("prerelease")] bool Prerelease,
    [property: JsonPropertyName("published_at")] DateTimeOffset? PublishedAt,
    [property: JsonPropertyName("assets")] IReadOnlyList<GithubAssetInfo>? Assets);

/// <summary>
/// Which GitHub releases the Windows update check reads. The macOS and Windows apps share one repository and, from
/// <c>v1.4.0</c>, one release per version; older macOS-only releases (<c>v1.3.2</c>) carry no Velopack feed, so the
/// 10 newest releases Velopack's own GitHub source reads may hold no Windows one at all. The check asks for a page of
/// 100 and keeps the releases that carry a feed (a <c>releases.win-&lt;arch&gt;.json</c> asset), newest first:
/// published (never drafts), no prereleases unless asked, never a QA build (a <c>-dev</c> tag, built to read its feed
/// from an environment variable), at most <see cref="MaxReleases"/> (Velopack's own number; each costs the download of
/// its small feed file).
/// </summary>
public static class ReleaseSelector
{
    public const int MaxReleases = 10;

    /// <summary>The releases API page the check reads (newest first).</summary>
    public const int PageSize = 100;

    /// <summary>
    /// The releases API response. An unreadable one (a captive portal's page, a proxy error) throws
    /// <see cref="JsonException"/>, so the check fails instead of reading as "no update".
    /// </summary>
    public static IReadOnlyList<GithubReleaseInfo> Parse(string json) =>
        JsonSerializer.Deserialize<List<GithubReleaseInfo>>(json) ?? throw new JsonException("The releases API returned null.");

    /// <summary>The Windows releases to read, newest first.</summary>
    public static IReadOnlyList<GithubReleaseInfo> WindowsReleases(
        IEnumerable<GithubReleaseInfo> releases, bool includePrereleases) =>
        [.. releases
            .Where(r => !r.Draft && (includePrereleases || !r.Prerelease))
            .Where(r => (r.Assets ?? []).Any(IsFeed))
            .Where(r => r.TagName?.Contains("-dev", StringComparison.OrdinalIgnoreCase) != true)
            .OrderByDescending(r => r.PublishedAt ?? DateTimeOffset.MinValue)
            .Take(MaxReleases)];

    /// <summary>A Velopack feed of one architecture's channel (<c>releases.win-x64.json</c>).</summary>
    private static bool IsFeed(GithubAssetInfo asset) =>
        asset.Name?.StartsWith("releases.win-", StringComparison.Ordinal) == true
        && asset.Name.EndsWith(".json", StringComparison.Ordinal);
}
