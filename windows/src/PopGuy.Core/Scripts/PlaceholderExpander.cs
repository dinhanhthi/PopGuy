using System.Text;

namespace PopGuy.Core.Scripts;

/// <summary>
/// Injection-safe delivery of the selected text into scriptable actions (macOS <c>PlaceholderExpander.swift</c>,
/// spec-4 §4.3). The selection is UNTRUSTED (it may be attacker-crafted page or document content): it enters a URL only
/// percent-encoded, and a shell script only as environment values, never its source. AppleScript expansion is not
/// ported: AppleScript actions don't run on Windows.
/// </summary>
public static class PlaceholderExpander
{
    /// <summary>The only token; replaced by the trimmed selection.</summary>
    public const string TextToken = "{text}";

    // Foundation's urlQueryAllowed minus "/?#&=+%@:;": with ALPHA and DIGIT, the only characters left bare.
    private const string UrlBare = "-._~!$'()*,";

    /// <summary>
    /// Every <c>{text}</c> in <paramref name="template"/> replaced with <paramref name="text"/> percent-encoded as UTF-8
    /// (uppercase hex, space as <c>%20</c>), so it can only fill the path segment or query value the token marks: the
    /// structural characters <c>/ ? # &amp; = + % @ : ;</c> are all encoded. <c>{text}</c> in the host is unsupported.
    /// </summary>
    public static string ExpandUrl(string template, string text) =>
        template.Replace(TextToken, PercentEncode(text), StringComparison.Ordinal);

    /// <summary>
    /// A shell script's view of the selection: <c>POPGUY_TEXT</c> (the trimmed selection) and <c>POPGUY_FULL_TEXT</c>
    /// (the full one), each with a leading <c>~</c>, <c>~/</c> or <c>~\</c> expanded to <paramref name="home"/> (an
    /// environment value gets no shell tilde expansion). <c>~user</c> stays as is. NUL characters are dropped: one would
    /// end the variable in the Windows environment block and let the selection add variables of its own.
    /// </summary>
    public static Dictionary<string, string> ScriptEnvironment(string text, string fullText, string home) => new()
    {
        ["POPGUY_TEXT"] = ExpandingLeadingTilde(text.Replace("\0", "", StringComparison.Ordinal), home),
        ["POPGUY_FULL_TEXT"] = ExpandingLeadingTilde(fullText.Replace("\0", "", StringComparison.Ordinal), home),
    };

    private static string PercentEncode(string text)
    {
        var encoded = new StringBuilder(text.Length);
        // A lone surrogate becomes U+FFFD's bytes (Swift strings cannot hold one).
        foreach (var b in Encoding.UTF8.GetBytes(text))
        {
            var c = (char)b;
            if (char.IsAsciiLetterOrDigit(c) || UrlBare.Contains(c))
                encoded.Append(c);
            else
                encoded.Append('%').Append(b.ToString("X2"));
        }
        return encoded.ToString();
    }

    private static string ExpandingLeadingTilde(string s, string home)
    {
        if (home.Length == 0)
            return s;
        if (s == "~")
            return home;
        return s.StartsWith("~/", StringComparison.Ordinal) || s.StartsWith(@"~\", StringComparison.Ordinal) ? home + s[1..] : s;
    }
}
