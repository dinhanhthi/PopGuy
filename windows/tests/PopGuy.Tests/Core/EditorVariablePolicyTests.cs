using PopGuy.Core.Composer;

namespace PopGuy.Tests.Core;

// Security of the user's environment: Settings -> Composer "Set up" / "Remove" write and delete the user's VISUAL
// (HKCU\Environment\VISUAL). Only our value may be removed, and another editor is replaced only when the user said so.
public sealed class EditorVariablePolicyTests
{
    [Fact]
    public void ClassifiesNotSetOursAndOther()
    {
        Assert.Equal(EditorVariableKind.NotSet, EditorVariablePolicy.Classify(null).Kind);
        Assert.Equal(EditorVariableKind.NotSet, EditorVariablePolicy.Classify("").Kind);
        Assert.Equal(EditorVariableKind.NotSet, EditorVariablePolicy.Classify("  ").Kind);

        Assert.Equal(EditorVariableKind.Ours, EditorVariablePolicy.Classify("popguy-edit").Kind);
        Assert.Equal(EditorVariableKind.Ours, EditorVariablePolicy.Classify("POPGUY-EDIT").Kind);
        Assert.Equal(EditorVariableKind.Ours, EditorVariablePolicy.Classify(" popguy-edit ").Kind);

        Assert.Equal(new EditorVariableStatus(EditorVariableKind.Other, "vim"), EditorVariablePolicy.Classify("vim"));
        Assert.Equal(EditorVariableKind.Other, EditorVariablePolicy.Classify("popguy-edit --wait").Kind);
    }

    [Fact]
    public void RemovesOnlyOurValue()
    {
        Assert.True(EditorVariablePolicy.MayRemove(EditorVariablePolicy.Classify("popguy-edit")));
        Assert.False(EditorVariablePolicy.MayRemove(EditorVariablePolicy.Classify("code --wait")));
        Assert.False(EditorVariablePolicy.MayRemove(EditorVariablePolicy.Classify(null)));
    }

    [Fact]
    public void ReplacesAnotherEditorOnlyWithOverwrite()
    {
        var other = EditorVariablePolicy.Classify("nvim");
        Assert.False(EditorVariablePolicy.MaySet(other, overwrite: false));
        Assert.True(EditorVariablePolicy.MaySet(other, overwrite: true));
        Assert.True(EditorVariablePolicy.MaySet(EditorVariablePolicy.Classify(null), overwrite: false));
        Assert.True(EditorVariablePolicy.MaySet(EditorVariablePolicy.Classify("popguy-edit"), overwrite: false));
    }
}
