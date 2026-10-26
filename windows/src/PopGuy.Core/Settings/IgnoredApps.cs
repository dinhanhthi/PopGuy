namespace PopGuy.Core.Settings;

/// <summary>
/// The ignored apps list (<see cref="AppSettings.IgnoredAppExeNames"/>): an entry is an exe name, compared by its file
/// name case-insensitively, so a path or another case still matches. The gate (<c>PresentationGate</c>) and Settings →
/// Ignore use the same rule. Entries are added in ForegroundApp's form (lowercase file name); a blank or null entry
/// (settings.json can hold null in a list) matches nothing.
/// </summary>
public static class IgnoredApps
{
    /// <summary>The lowercase file name of a trimmed exe name or path; null when there is none.</summary>
    public static string? Key(string? exe) => FileName(exe)?.ToLowerInvariant();

    /// <summary>An entry of <paramref name="list"/> matches <paramref name="exe"/>.</summary>
    public static bool Contains(IEnumerable<string?> list, string? exe) =>
        FileName(exe) is { } name && list.Any(e => string.Equals(FileName(e), name, StringComparison.OrdinalIgnoreCase));

    /// <summary>The entries' keys in list order, each once; blank and null entries left out.</summary>
    public static IReadOnlyList<string> Keys(IEnumerable<string?> list) =>
        [.. list.Select(Key).OfType<string>().Distinct(StringComparer.Ordinal)];

    /// <summary><paramref name="list"/> with <paramref name="exe"/>'s key appended, unless an entry already matches it.</summary>
    public static IReadOnlyList<string> Add(IReadOnlyList<string> list, string exe) =>
        Key(exe) is { } key && !Contains(list, key) ? [.. list, key] : list;

    /// <summary><paramref name="list"/> without every entry that matches <paramref name="exe"/>.</summary>
    public static IReadOnlyList<string> Remove(IReadOnlyList<string> list, string exe) =>
        FileName(exe) is { } name
            ? [.. list.Where(e => !string.Equals(FileName(e), name, StringComparison.OrdinalIgnoreCase))]
            : list;

    /// <summary>The file name of a trimmed exe name or path, splitting on both separators on any OS; null when there is none.</summary>
    private static string? FileName(string? exe)
    {
        var trimmed = exe?.Trim() ?? "";
        var name = trimmed[(trimmed.LastIndexOfAny(['\\', '/']) + 1)..];
        return name.Length > 0 ? name : null;
    }
}
