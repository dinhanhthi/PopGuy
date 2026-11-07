// Pure decisions for Settings -> Composer "Set up" / "Remove" of the user's editor variable (HKCU\Environment\VISUAL):
// what the stored value means, and whether PopGuy may write or delete it. Ours is "popguy-edit" (surrounding whitespace
// trimmed, ordinal ignore case); any other value is the user's own editor, replaced only after the user confirms and
// never removed.

namespace PopGuy.Core.Composer;

public enum EditorVariableKind
{
    NotSet,
    Ours,
    Other,
}

/// <summary>The variable's kind and its stored value (null when not set).</summary>
public readonly record struct EditorVariableStatus(EditorVariableKind Kind, string? Value);

public static class EditorVariablePolicy
{
    public const string Name = "VISUAL";
    public const string Value = "popguy-edit";

    public static EditorVariableStatus Classify(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return new EditorVariableStatus(EditorVariableKind.NotSet, null);
        var kind = string.Equals(value.Trim(), Value, StringComparison.OrdinalIgnoreCase)
            ? EditorVariableKind.Ours
            : EditorVariableKind.Other;
        return new EditorVariableStatus(kind, value);
    }

    /// <summary>Another editor's value is replaced only with <paramref name="overwrite"/> (the user confirmed).</summary>
    public static bool MaySet(EditorVariableStatus status, bool overwrite) =>
        status.Kind != EditorVariableKind.Other || overwrite;

    /// <summary>Only our own value is ever deleted.</summary>
    public static bool MayRemove(EditorVariableStatus status) => status.Kind == EditorVariableKind.Ours;
}
