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
/// Which GitHub releases the Windows update check reads. The macOS and Windows apps share one repository: the macOS
/// releases (<c>v1.3.2</c>) carry no Velopack feed, and they come often, so the 10 newest releases Velopack's own
/// GitHub source reads may hold no Windows one at all. The check asks for a page of 100 and keeps the
/// <see cref="TagPrefix"/> releases, newest first: published (never drafts), no prereleases unless asked, at most
/// <see cref="MaxReleases"/> (Velopack's own number; each costs the download of its small feed file).
/// </summary>
public static class ReleaseSelector
{
    public const string TagPrefix = "windows-v";

    public const int MaxReleases = 10;

    /// <summary>The releases API page the check reads (newest first).</summary>
    public const int PageSize = 100;

    /// <summary>The releases API response; an unreadable one is empty.</summary>
    public static IReadOnlyList<GithubReleaseInfo> Parse(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<List<GithubReleaseInfo>>(json) ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// <summary>The Windows releases to read, newest first.</summary>
    public static IReadOnlyList<GithubReleaseInfo> WindowsReleases(
        IEnumerable<GithubReleaseInfo> releases, bool includePrereleases) =>
        [.. releases
            .Where(r => !r.Draft && (includePrereleases || !r.Prerelease))
            .Where(r => r.TagName?.StartsWith(TagPrefix, StringComparison.Ordinal) == true)
            .OrderByDescending(r => r.PublishedAt ?? DateTimeOffset.MinValue)
            .Take(MaxReleases)];
}
