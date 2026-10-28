namespace PopGuy.Core.Text;

/// <summary>
/// Line endings at the Windows edges. PopGuy keeps text with "\n" (as on macOS): UI Automation returns a selection's
/// line breaks as a bare "\r" in some editors (Notepad), and providers given those merged the paragraphs (VM QA).
/// The clipboard gets "\r\n", the CF_UNICODETEXT convention older edit controls need.
/// </summary>
public static class LineEndings
{
    /// <summary>"\r\n" and a bare "\r" become "\n".</summary>
    public static string ToLf(string text) =>
        text.Contains('\r') ? text.Replace("\r\n", "\n").Replace('\r', '\n') : text;

    /// <summary>Every line break ("\n", "\r\n" or a bare "\r") becomes "\r\n".</summary>
    public static string ToCrLf(string text)
    {
        var lf = ToLf(text);
        return lf.Contains('\n') ? lf.Replace("\n", "\r\n") : lf;
    }
}
