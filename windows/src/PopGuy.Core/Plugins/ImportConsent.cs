using PopGuy.Core.Actions;

namespace PopGuy.Core.Plugins;

/// <summary>One action of the consent dialog with its Windows note (null when it runs here as is).</summary>
public sealed record ConsentAction(ImportedAction Imported, string? WindowsNote);

/// <summary>
/// What the consent dialog shows for any import path (macOS <c>PluginImportConsentView</c>): the actions, each with its
/// Windows note, and the other skip notes. <see cref="UnsupportedProviderCount"/> counts native JSON actions dropped for
/// a provider their type does not allow; they are reported after Add, as macOS does.
/// </summary>
public sealed record ImportConsent(
    string SourceName,
    IReadOnlyList<ConsentAction> Actions,
    IReadOnlyList<SkippedItem> Skipped,
    int UnsupportedProviderCount)
{
    /// <summary>
    /// A PopClip import. The adapter's Windows notes move to their action's card, so a note is never shown twice; every
    /// other skip note stays.
    /// </summary>
    public static ImportConsent FromPlugin(PluginImportResult result) => new(
        result.SourceName,
        [.. result.Imported.Select(a => new ConsentAction(a, WindowsNote(a)))],
        [.. result.Skipped.Where(s => s.Reason is not (PopClipAdapter.NotRunnableOnWindowsReason or PopClipAdapter.WrittenForZshReason))],
        0);

    /// <summary>A native JSON import (no skip notes, as on macOS); the Windows notes come from the action flags.</summary>
    public static ImportConsent FromNative(string sourceName, ActionImportResult result) => new(
        sourceName,
        [.. result.Actions.Select(a => new ConsentAction(a, WindowsNote(a)))],
        [],
        result.SkippedCount);

    /// <summary>The note the adapter gives the same action: macOS-only types first, then a zsh script.</summary>
    public static string? WindowsNote(ImportedAction action) =>
        !action.Action.RunnableOnWindows ? PopClipAdapter.NotRunnableOnWindowsReason
        : action.WrittenForMacShell ? PopClipAdapter.WrittenForZshReason
        : null;

    /// <summary>The "Import Failed" message for a refused file (the macOS text; over 100 actions is Windows only).</summary>
    public static string RejectionMessage(ImportRejection rejection) => rejection switch
    {
        ImportRejection.TooLarge => "The file is too large to import.",
        ImportRejection.TooManyActions => $"The file contains more than {ActionImport.MaxActions} actions.",
        _ => "The file does not contain a valid list of custom actions.",
    };

    /// <summary>The "Unsupported Provider" message (macOS text).</summary>
    public static string UnsupportedProviderMessage(int count) =>
        $"Skipped {count} action{(count == 1 ? "" : "s")} whose provider is not valid for its action type.";
}
