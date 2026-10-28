using System.Text.RegularExpressions;
using PopGuy.Core.Actions;

namespace PopGuy.Core.Plugins;

/// <summary>An item not imported, or imported with a caveat, and why (macOS <c>SkippedItem</c>).</summary>
public sealed record SkippedItem(string Label, string Reason);

/// <summary>
/// One import pass, ready for the consent dialog (macOS <c>PluginImportResult</c>). <see cref="Imported"/> holds
/// sanitized actions with their full URL or script in <c>ScriptSource</c>; nothing has run.
/// </summary>
public sealed record PluginImportResult(string SourceName, IReadOnlyList<ImportedAction> Imported, IReadOnlyList<SkippedItem> Skipped);

/// <summary>
/// Maps a <see cref="PopClipConfig"/> to PopGuy custom actions plus a skip report (port of macOS
/// <c>PopClipToPopGuyAdapter.swift</c>, spec-4 §5.5). Every action then goes through <see cref="ActionImport.Prepare"/>,
/// the same gate as a native JSON import. Windows adds one note per action that cannot run as is here.
/// </summary>
public static class PopClipAdapter
{
    /// <summary>The note on an imported AppleScript or Shortcuts action (kept so it round-trips; hidden on Windows).</summary>
    public const string NotRunnableOnWindowsReason = "AppleScript and Shortcuts actions don't run on Windows";

    /// <summary>The note on an imported shell script, which PopClip runs in zsh; it is imported disabled.</summary>
    public const string WrittenForZshReason = "Written for macOS zsh; may not run in PowerShell";

    private static readonly Regex PopClipTextPlaceholder =
        new(@"\{popclip[\s\-]text\}", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex PopClipVariable = new(@"POPCLIP_\w+");

    /// <summary>
    /// Executor priority url &gt; shell script &gt; AppleScript &gt; shortcut. Notes per action: icon, untranslated
    /// variables, requirements, then the Windows note; the options note comes last. At most
    /// <see cref="ActionImport.MaxActions"/> actions are kept (macOS truncates, with no note).
    /// </summary>
    public static PluginImportResult Adapt(PopClipConfig config)
    {
        var sourceName = config.Name ?? config.Identifier ?? "PopClip extension";
        var imported = new List<ImportedAction>();
        var skipped = new List<SkippedItem>();
        var hasOptions = false;

        foreach (var action in config.Actions)
        {
            var label = action.Title ?? config.Name ?? "Imported action";
            hasOptions |= action.HasOptions;

            string? unknownVariablesNote = null;
            (CustomActionType Type, string Source)? executor = null;
            if (action.Url is { } url)
            {
                executor = (CustomActionType.OpenUrl, PopClipTextPlaceholder.Replace(url.Replace("***", "{text}"), "{text}"));
            }
            else if (action.ShellScript is { } shell)
            {
                var (rewritten, unknown) = RewriteShellVariables(shell);
                executor = (CustomActionType.ShellScript, rewritten);
                if (unknown.Count > 0)
                    unknownVariablesNote = $"uses PopClip variable(s) not translated: {string.Join(", ", unknown)}";
            }
            else if (action.AppleScript is { } appleScript)
            {
                executor = (CustomActionType.AppleScript, PopClipTextPlaceholder.Replace(appleScript, "{text}"));
            }
            else if (action.ShortcutName is { } shortcut)
            {
                executor = (CustomActionType.RunShortcut, shortcut);
            }

            if (executor is not { } chosen)
            {
                skipped.Add(new SkippedItem(label, UnsupportedReason(action)));
                continue;
            }

            var (icon, iconNote) = ResolveIcon(action.Icon ?? config.Icon);
            if (iconNote is not null)
                skipped.Add(new SkippedItem(label, iconNote));
            if (unknownVariablesNote is not null)
                skipped.Add(new SkippedItem(label, unknownVariablesNote));
            skipped.AddRange(RequirementNotes(action));

            var adapted = new CustomAction
            {
                Title = label,
                Icon = icon,
                Type = chosen.Type,
                SystemPrompt = "",
                ScriptSource = chosen.Source,
                AfterRun = ResolveAfterRun(action.After),
                AppliesWhenRegex = action.Regex ?? "",
            };
            // Script types never fail the provider check, so every adapted action is kept.
            var prepared = ActionImport.Prepare(adapted)!;
            imported.Add(prepared);

            if (!prepared.Action.RunnableOnWindows)
                skipped.Add(new SkippedItem(label, NotRunnableOnWindowsReason));
            else if (prepared.WrittenForMacShell)
                skipped.Add(new SkippedItem(label, WrittenForZshReason));
        }

        if (hasOptions)
            skipped.Add(new SkippedItem(sourceName, "Plugin options are not supported (actions imported without options)"));

        return new PluginImportResult(sourceName, imported.Take(ActionImport.MaxActions).ToList(), skipped);
    }

    /// <summary>
    /// <c>POPCLIP_FULL_TEXT</c> then <c>POPCLIP_TEXT</c> become their <c>POPGUY_</c> names (as <c>$VAR</c>,
    /// <c>${VAR}</c> or a bare whole token); any other <c>POPCLIP_*</c> name is returned for a note.
    /// </summary>
    private static (string Rewritten, IReadOnlyList<string> Unknown) RewriteShellVariables(string script)
    {
        foreach (var (popClip, popGuy) in new[] { ("POPCLIP_FULL_TEXT", "POPGUY_FULL_TEXT"), ("POPCLIP_TEXT", "POPGUY_TEXT") })
        {
            script = script.Replace("$" + popClip, "$" + popGuy).Replace("${" + popClip + "}", "${" + popGuy + "}");
            script = Regex.Replace(script, @"(?<!\w)" + popClip + @"(?!\w)", popGuy);
        }
        var unknown = PopClipVariable.Matches(script).Select(m => m.Value).Distinct().ToList();
        return (script, unknown);
    }

    /// <summary>
    /// <c>symbol:NAME</c> and <c>emoji:X</c> (prefixes case-insensitive), or a bare emoji; anything else (text:,
    /// shapes, image files) falls back to the default icon with a note. Missing or empty: default, no note.
    /// </summary>
    private static (ActionIcon Icon, string? Note) ResolveIcon(string? raw)
    {
        if (string.IsNullOrEmpty(raw))
            return (ActionIcon.Default, null);
        if (raw.StartsWith("symbol:", StringComparison.OrdinalIgnoreCase))
            return (ActionIcon.SfSymbol(raw["symbol:".Length..]), null);
        if (raw.StartsWith("emoji:", StringComparison.OrdinalIgnoreCase))
            return (ActionIcon.Emoji(raw["emoji:".Length..]), null);
        if (LooksLikeEmoji(raw))
            return (ActionIcon.Emoji(raw), null);
        return (ActionIcon.Default, $"icon '{raw}' not supported, using default icon");
    }

    /// <summary>
    /// The macOS heuristic: at most 8 scalars, the first not printable ASCII and in U+2600–U+27BF or from U+1F300 up
    /// (the Swift range's upper bound is a typo that covers everything above).
    /// </summary>
    private static bool LooksLikeEmoji(string value)
    {
        var runes = value.EnumerateRunes().Take(9).ToList();
        if (runes.Count is 0 or > 8)
            return false;
        var first = runes[0].Value;
        return first is >= 0x2600 and <= 0x27BF or >= 0x1F300;
    }

    private static AfterRunBehavior ResolveAfterRun(string? after) => after?.ToLowerInvariant() switch
    {
        "paste-result" => AfterRunBehavior.PasteResult,
        "copy-result" => AfterRunBehavior.CopyResult,
        "show-result" or "preview-result" => AfterRunBehavior.ShowResult,
        _ => AfterRunBehavior.CloseToolbar,
    };

    /// <summary>Every requirement but <c>regex</c> (handled by <c>appliesWhenRegex</c>) is noted as not enforced.</summary>
    private static IEnumerable<SkippedItem> RequirementNotes(PopClipAction action) =>
        (action.Requirements ?? [])
            .Where(r => !r.Equals("regex", StringComparison.OrdinalIgnoreCase))
            .Select(r => new SkippedItem(action.Title ?? "Action", $"requirement '{r}' not enforced"));

    private static string UnsupportedReason(PopClipAction action)
    {
        if (action.Javascript is not null || action.JavascriptFile is not null)
            return "JavaScript actions are not supported";
        if (action.KeyCombo is not null)
            return "Key-combo actions are not supported";
        if (action.ServiceName is not null)
            return "Service actions are not supported";
        return "No supported action type found";
    }
}
