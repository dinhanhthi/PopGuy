using System.Globalization;
using System.Text;

namespace PopGuy.Core.Actions;

// Prompt placeholder expansion, a port of PromptContext.swift. Tokens: {{text}}, {{app}}, {{domain}}, {{date}},
// {{language}}. One left-to-right pass: substituted values are never re-scanned, so selected text or an app name that
// contains a token stays literal (prompt-injection guard). Unknown tokens and an unterminated "{{" stay literal.

/// <summary>The context values of a prompt template, each flattened to a single line.</summary>
public sealed record PromptContext
{
    public static PromptContext Empty { get; } = new("", "", "", "");

    public PromptContext(string appName, string domain, string date, string language)
    {
        AppName = SingleLine(appName);
        Domain = SingleLine(domain);
        Date = SingleLine(date);
        Language = SingleLine(language);
    }

    public string AppName { get; }
    public string Domain { get; }
    public string Date { get; }
    public string Language { get; }

    /// <summary>The <c>{{date}}</c> value: <c>yyyy-MM-dd</c> (Gregorian) in <paramref name="timeZone"/>, local by default.</summary>
    public static string DateString(DateTimeOffset date, TimeZoneInfo? timeZone = null) =>
        TimeZoneInfo.ConvertTime(date, timeZone ?? TimeZoneInfo.Local).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    // Each run of control, format or newline characters becomes one space (Swift controlCharacters ∪ newlines), then
    // spaces and tabs are trimmed.
    private static string SingleLine(string value)
    {
        var builder = new StringBuilder(value.Length);
        var lastWasSeparator = false;
        foreach (var rune in value.EnumerateRunes())
        {
            if (IsSeparator(rune))
            {
                if (!lastWasSeparator)
                    builder.Append(' ');
                lastWasSeparator = true;
            }
            else
            {
                builder.Append(rune.ToString());
                lastWasSeparator = false;
            }
        }
        return PromptTemplate.TrimSpaces(builder.ToString());
    }

    private static bool IsSeparator(Rune rune) =>
        Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format
            or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator;
}

public static class PromptTemplate
{
    /// <summary>
    /// Expands the tokens of <paramref name="template"/> in one pass. <c>ConsumedText</c> reports whether the template
    /// itself contained <c>{{text}}</c>. A null <paramref name="text"/> leaves <c>{{text}}</c> literal (not consumed).
    /// </summary>
    public static (string Output, bool ConsumedText) Expand(string template, string? text, PromptContext context)
    {
        var output = new StringBuilder(template.Length);
        var consumedText = false;
        var cursor = 0;

        int open;
        while ((open = template.IndexOf("{{", cursor, StringComparison.Ordinal)) >= 0)
        {
            output.Append(template, cursor, open - cursor);
            var nameStart = open + 2;
            var close = template.IndexOf("}}", nameStart, StringComparison.Ordinal);
            var name = close < 0 ? null : template[nameStart..close];
            if (name is null || Value(name, text, context) is not { } value)
            {
                // Unknown or unterminated token: keep "{{" and scan on right after it.
                output.Append("{{");
                cursor = nameStart;
                continue;
            }
            if (name == "text")
                consumedText = true;
            output.Append(value);
            cursor = close + 2;
        }
        output.Append(template, cursor, template.Length - cursor);
        return (output.ToString(), consumedText);
    }

    private static string? Value(string name, string? text, PromptContext context) => name switch
    {
        "text" => text,
        "app" => context.AppName,
        "domain" => context.Domain,
        "date" => context.Date,
        "language" => context.Language,
        _ => null,
    };

    /// <summary>Trims spaces and tabs but not newlines (Swift <c>.whitespaces</c>); <c>Trim()</c> also strips newlines.</summary>
    internal static string TrimSpaces(string value)
    {
        int start = 0, end = value.Length;
        while (start < end && IsSpace(value[start]))
            start++;
        while (end > start && IsSpace(value[end - 1]))
            end--;
        return value[start..end];
    }

    private static bool IsSpace(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
}
