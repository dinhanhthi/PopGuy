using PopGuy.Core.Actions;
using PopGuy.Core.Settings;

namespace PopGuy.Core.Library;

/// <summary>
/// An Action Library category (macOS <c>LibraryCategory</c>), in picker order. The macOS Apps category is not ported:
/// its presets open macOS apps or non-http(s) URL schemes, which the Windows script engine refuses.
/// </summary>
public enum LibraryCategory
{
    AiWriting,
    Search,
    Web,
    Maps,
    AiLaunchers,
    TranslateLaunchers,
    TextTransform,
    DevTools,
}

public static class LibraryCategoryExtensions
{
    /// <summary>The category picker's label.</summary>
    public static string DisplayName(this LibraryCategory category) => category switch
    {
        LibraryCategory.AiWriting => "AI Writing",
        LibraryCategory.Search => "Search Engines",
        LibraryCategory.Web => "Websites",
        LibraryCategory.Maps => "Maps",
        LibraryCategory.AiLaunchers => "AI Launchers",
        LibraryCategory.TranslateLaunchers => "Translate",
        LibraryCategory.TextTransform => "Text Transform",
        _ => "Developer Tools",
    };

    /// <summary>The category's SF Symbol name (drawn through the symbol map, like action icons).</summary>
    public static string IconName(this LibraryCategory category) => category switch
    {
        LibraryCategory.AiWriting => "wand.and.stars",
        LibraryCategory.Search => "magnifyingglass",
        LibraryCategory.Web => "globe",
        LibraryCategory.Maps => "map",
        LibraryCategory.AiLaunchers => "sparkles",
        LibraryCategory.TranslateLaunchers => "character.bubble",
        LibraryCategory.TextTransform => "textformat",
        _ => "hammer",
    };
}

/// <summary>
/// One catalog entry. <paramref name="Id"/> is the stable macOS key (e.g. "search.google"), never a UUID;
/// <paramref name="Make"/> returns a fresh action (new id) on every call.
/// </summary>
public sealed record LibraryPreset(string Id, LibraryCategory Category, Func<CustomAction> Make);

/// <summary>
/// The built-in catalog of ready-made custom actions (macOS <c>ActionLibrary.swift</c>, spec-5 §1). The presets live in
/// the AI, Web, Text and Dev parts, as on macOS. Open URL and AI presets are the macOS ones verbatim; the macOS zsh
/// transforms are rewritten in PowerShell (<c>shell: "powershell"</c>) and read the selection from
/// <c>$env:POPGUY_TEXT</c> only.
/// </summary>
public static partial class ActionLibrary
{
    // Methods, not fields: static field order across partial files is undefined.
    private static readonly LibraryPreset[] Catalog = [.. AiPresets(), .. WebPresets(), .. TextPresets(), .. DevPresets()];

    public static IReadOnlyList<LibraryCategory> Categories { get; } = Enum.GetValues<LibraryCategory>();

    /// <summary>Every preset, in category order.</summary>
    public static IReadOnlyList<LibraryPreset> AllPresets() => Catalog;

    public static IReadOnlyList<LibraryPreset> Presets(LibraryCategory category) =>
        Catalog.Where(p => p.Category == category).ToList();

    public static LibraryPreset? Find(string id) => Catalog.FirstOrDefault(p => p.Id == id);

    /// <summary>Whether <paramref name="actions"/> already holds an action installed from <paramref name="preset"/>.</summary>
    public static bool IsInstalled(LibraryPreset preset, IEnumerable<CustomAction> actions) =>
        actions.Any(a => a.LibraryPresetId == preset.Id);

    /// <summary>
    /// The action the Library installs (macOS <c>installableAction</c>): sanitized like an import, tagged with the
    /// preset id, not from a plugin, and an AI preset runs on the Improve action's provider and model. A PowerShell
    /// preset keeps <c>shell</c>, so it stays enabled. Null when sanitizing refuses it.
    /// </summary>
    public static CustomAction? InstallableAction(LibraryPreset preset, AppSettings settings)
    {
        if (ActionImport.Sanitize(preset.Make()) is not { } action)
            return null;
        action = action with { IsFromPlugin = false, LibraryPresetId = preset.Id };
        // Improve allows only AI providers, so no re-sanitize.
        return action.Type == CustomActionType.Ai
            ? action with { ProviderKind = settings.ImproveConfig.ProviderKind, Model = settings.ImproveConfig.Model }
            : action;
    }

    private static LibraryPreset PowerShell(
        string id, LibraryCategory category, string title, string icon, AfterRunBehavior afterRun, string description,
        string script) =>
        new(id, category, () => new CustomAction
        {
            Title = title,
            ActionDescription = description,
            Icon = ActionIcon.SfSymbol(icon),
            Type = CustomActionType.ShellScript,
            SystemPrompt = "",
            ScriptSource = script,
            AfterRun = afterRun,
            Shell = CustomActionEditing.PowerShell,
        });
}
