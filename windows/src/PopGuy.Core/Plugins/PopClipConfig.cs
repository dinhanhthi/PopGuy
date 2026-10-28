namespace PopGuy.Core.Plugins;

/// <summary>
/// A PopClip extension config (Config.json / .yaml / .plist or a snippet), port of macOS <c>PopClipConfig.swift</c>.
/// Decoded permissively from a plain tree (spec-4 §5.4): unknown keys are ignored, a field of the wrong type reads as
/// null, and <see cref="Actions"/> is always resolved (the <c>actions</c> array, or the root as a single action).
/// </summary>
public sealed record PopClipConfig(string? Name, string? Identifier, string? Icon, IReadOnlyList<PopClipAction> Actions)
{
    /// <summary>
    /// Decodes the plain tree a reader built (dictionaries, lists, strings and other scalars). Only a root that is not
    /// a mapping fails, as the Swift keyed container does.
    /// </summary>
    internal static PopClipConfig FromTree(object? root)
    {
        if (root is not IReadOnlyDictionary<string, object?> map)
            throw PopClipReadException.Malformed("The config is not a key-value mapping.");

        IReadOnlyList<PopClipAction> actions;
        if (map.TryGetValue("actions", out var list))
        {
            // Present: decode element by element, skipping malformed ones; not an array reads as empty.
            actions = list is IReadOnlyList<object?> items
                ? items.OfType<IReadOnlyDictionary<string, object?>>().Select(PopClipAction.FromMap).ToList()
                : [];
        }
        else
        {
            actions = [PopClipAction.FromMap(map)];
        }

        return new PopClipConfig(
            TreeRead.String(map, "name"),
            TreeRead.String(map, "identifier"),
            TreeRead.String(map, "icon"),
            actions);
    }
}

/// <summary>One action of a PopClip config. Every field is optional; the adapter picks the executor.</summary>
public sealed record PopClipAction
{
    public string? Title { get; init; }
    public string? Icon { get; init; }
    public string? Identifier { get; init; }
    public string? Regex { get; init; }
    public IReadOnlyList<string>? Requirements { get; init; }
    public string? Before { get; init; }
    public string? After { get; init; }
    public string? Url { get; init; }
    public string? KeyCombo { get; init; }
    public string? ShellScript { get; init; }
    public string? ShellScriptFile { get; init; }

    /// <summary>Read but never used (macOS parity): an imported script runs in the PopGuy shell, whatever it names.</summary>
    public string? Interpreter { get; init; }

    public string? AppleScript { get; init; }
    public string? AppleScriptFile { get; init; }

    /// <summary>Read but never mapped (macOS parity).</summary>
    public string? AppleScriptCall { get; init; }

    public string? ShortcutName { get; init; }
    public string? ServiceName { get; init; }
    public string? Javascript { get; init; }
    public string? JavascriptFile { get; init; }

    /// <summary>The action declares an <c>options</c> key (user settings PopGuy does not support).</summary>
    public bool HasOptions { get; init; }

    /// <summary>The aliases of macOS <c>PopClipAction.init(from:)</c>: the first key holding a string wins.</summary>
    internal static PopClipAction FromMap(IReadOnlyDictionary<string, object?> map) => new()
    {
        Title = TreeRead.String(map, "title", "label"),
        Icon = TreeRead.String(map, "icon"),
        Identifier = TreeRead.String(map, "identifier"),
        Regex = TreeRead.String(map, "regex"),
        Before = TreeRead.String(map, "before"),
        After = TreeRead.String(map, "after"),
        Url = TreeRead.String(map, "url"),
        Interpreter = TreeRead.String(map, "interpreter"),
        Requirements = RequirementsOf(map),
        KeyCombo = KeyComboOf(map, "key combo", "keyCombo", "key combos"),
        ShellScript = TreeRead.String(map, "shell script", "shellScript"),
        ShellScriptFile = TreeRead.String(map, "shell script file", "shellScriptFile"),
        AppleScript = TreeRead.String(map, "apple script", "applescript", "appleScript"),
        AppleScriptFile = TreeRead.String(map, "apple script file", "applescriptFile", "appleScriptFile"),
        AppleScriptCall = TreeRead.String(map, "apple script call", "applescriptCall"),
        ShortcutName = TreeRead.String(map, "shortcut name", "shortcutName"),
        ServiceName = TreeRead.String(map, "service name", "serviceName"),
        Javascript = TreeRead.String(map, "javascript", "js"),
        JavascriptFile = TreeRead.String(map, "javascript file", "javascriptFile"),
        HasOptions = map.ContainsKey("options"),
    };

    /// <summary>An array of strings, or a single string wrapped into one.</summary>
    private static IReadOnlyList<string>? RequirementsOf(IReadOnlyDictionary<string, object?> map) =>
        map.GetValueOrDefault("requirements") switch
        {
            IReadOnlyList<object?> items when items.All(i => i is string) => items.Cast<string>().ToList(),
            string single => [single],
            _ => null,
        };

    /// <summary>A string, or the first element of an array of strings.</summary>
    private static string? KeyComboOf(IReadOnlyDictionary<string, object?> map, params string[] keys)
    {
        foreach (var key in keys)
        {
            switch (map.GetValueOrDefault(key))
            {
                case string combo:
                    return combo;
                case IReadOnlyList<object?> items when items.Count > 0 && items.All(i => i is string):
                    return (string)items[0]!;
            }
        }
        return null;
    }
}

/// <summary>Field reads over the plain tree.</summary>
internal static class TreeRead
{
    /// <summary>The first of <paramref name="keys"/> whose value is a string; any other type reads as absent.</summary>
    public static string? String(IReadOnlyDictionary<string, object?> map, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (map.GetValueOrDefault(key) is string value)
                return value;
        }
        return null;
    }
}
