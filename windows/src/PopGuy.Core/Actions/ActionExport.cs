using System.Text.Json;
using PopGuy.Core.Json;

namespace PopGuy.Core.Actions;

/// <summary>
/// The custom-action export (macOS <c>ActionsView.exportActions</c>, spec-3 §5.3.4): a JSON array of every custom action,
/// the same format the import reads. A PowerShell script keeps its <c>shell</c> key, so it re-imports runnable.
/// </summary>
public static class ActionExport
{
    /// <summary>The save picker's suggested name (macOS <c>popguy-actions.json</c>).</summary>
    public const string DefaultFileName = "popguy-actions.json";

    /// <summary>Pretty-printed UTF-8 JSON, keys in the macOS encode order (macOS also sorts them; readers accept either).</summary>
    public static byte[] Serialize(IReadOnlyList<CustomAction> actions) =>
        JsonSerializer.SerializeToUtf8Bytes(actions, PopGuyJson.Options);
}
