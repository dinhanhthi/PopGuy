// Pure edits of the user PATH string (HKCU\Environment\Path as stored, unexpanded, ";"-separated) for Settings ->
// "Install command" / "Remove": add or remove only our popguy-edit folder and keep every other segment byte-for-byte
// and in order (empty segments included).
//
// Comparison of a segment with our entry: ordinal ignore case, surrounding whitespace trimmed, trailing backslashes
// ignored ("C:\x\bin" == "c:\x\bin\"). "%VAR%" segments are compared literally and never expanded or rewritten, so
// "%LOCALAPPDATA%\PopGuy\current\bin" is not equal to its expanded form "C:\Users\...\PopGuy\current\bin".

namespace PopGuy.Core.Composer;

public static class UserPathEdit
{
    public static bool Contains(string? userPath, string entry)
    {
        var key = Key(entry);
        return (userPath ?? "").Split(';').Any(segment => Matches(segment, key));
    }

    /// <summary>Appends <paramref name="entry"/> unless already present; an existing trailing ";" is not doubled.</summary>
    public static string Add(string? userPath, string entry)
    {
        if (Contains(userPath, entry)) return userPath!;
        if (string.IsNullOrEmpty(userPath)) return entry;
        return userPath.EndsWith(';') ? userPath + entry : userPath + ";" + entry;
    }

    /// <summary>Removes every segment equal to <paramref name="entry"/> with its separator; anything else is kept.</summary>
    public static string Remove(string? userPath, string entry)
    {
        var key = Key(entry);
        var segments = (userPath ?? "").Split(';');
        var kept = segments.Where(segment => !Matches(segment, key)).ToArray();
        return kept.Length == segments.Length ? userPath ?? "" : string.Join(';', kept);
    }

    // An empty entry would match (and remove) the user's empty segments; one with ";" would add two segments.
    private static string Key(string entry)
    {
        var key = Normalize(entry);
        if (key.Length == 0 || entry.Contains(';')) throw new ArgumentException("Invalid PATH entry.", nameof(entry));
        return key;
    }

    private static bool Matches(string segment, string key) =>
        string.Equals(Normalize(segment), key, StringComparison.OrdinalIgnoreCase);

    private static string Normalize(string value) => value.Trim().TrimEnd('\\');
}
