namespace PopGuy.Core.Actions;

/// <summary>
/// The draft rules of the Add/Edit action panel (macOS <c>CustomActionEditSheet</c>, spec-3 §5.3.2) and the speech
/// slider levels (macOS <c>speakRate(forLevel:)</c> and its inverses, spec-3 §2.4).
/// </summary>
public static class CustomActionEditing
{
    /// <summary>The script shell the Windows editor writes: what it runs in, and what an export says.</summary>
    public const string PowerShell = "powershell";

    /// <summary>
    /// <paramref name="draft"/> switched to <paramref name="type"/>: a provider the type does not allow becomes its first
    /// allowed one; a scriptable type closes the toolbar after it runs (the user can change it); a shell script is
    /// written for PowerShell (a shell script without it reads as macOS zsh); a dictionary leaves the macOS Dictionary,
    /// which Windows does not have.
    /// </summary>
    public static CustomAction WithType(CustomAction draft, CustomActionType type)
    {
        if (draft.Type == type)
            return draft;
        var allowed = ProviderKindExtensions.AllowedProviders(type);
        var changed = draft with
        {
            Type = type,
            ProviderKind = allowed.Count > 0 && !allowed.Contains(draft.ProviderKind) ? allowed[0] : draft.ProviderKind,
        };
        if (changed.IsScriptable)
            changed = changed with { AfterRun = AfterRunBehavior.CloseToolbar };
        if (type == CustomActionType.ShellScript)
            changed = changed with { Shell = PowerShell };
        if (type == CustomActionType.Dictionary && changed.DictionaryConfig.Provider == DictionaryProviderKind.MacOSBuiltin)
            changed = changed with { DictionaryConfig = changed.DictionaryConfig with { Provider = DictionaryProviderKind.Minhqnd } };
        return changed;
    }

    /// <summary>
    /// The action the panel stores: a shell script whose source was written or changed here is PowerShell. One only
    /// opened (an imported macOS zsh script) keeps its origin.
    /// </summary>
    public static CustomAction ForSave(CustomAction? original, CustomAction draft) =>
        draft.Type == CustomActionType.ShellScript && draft.Shell is null
        && (original is null || original.ScriptSource != draft.ScriptSource)
            ? draft with { Shell = PowerShell }
            : draft;

    // Speech sliders: level 1-10 on the macOS AVSpeech rate scale (0.0-1.0, level 5 = the 0.5 default) and pitch
    // (0.5-2.0).

    private const float RateMin = 0f;
    private const float RateDefault = 0.5f;
    private const float RateMax = 1f;

    public static float RateForLevel(int level)
    {
        var l = Math.Clamp(level, 1, 10);
        return l <= 5
            ? RateMin + (l - 1) / 4f * (RateDefault - RateMin)
            : RateDefault + (l - 5) / 5f * (RateMax - RateDefault);
    }

    /// <summary>The nearest level, 1-10.</summary>
    public static int LevelForRate(float rate)
    {
        var raw = rate <= RateDefault
            ? (rate - RateMin) / (RateDefault - RateMin) * 4 + 1
            : (rate - RateDefault) / (RateMax - RateDefault) * 5 + 5;
        return Math.Clamp((int)MathF.Round(raw, MidpointRounding.AwayFromZero), 1, 10);
    }

    public static float PitchForLevel(int level) => 0.5f + (Math.Clamp(level, 1, 10) - 1) / 9f * 1.5f;

    /// <summary>The nearest level, 1-10.</summary>
    public static int LevelForPitch(float pitch) =>
        Math.Clamp((int)MathF.Round((pitch - 0.5f) / 1.5f * 9, MidpointRounding.AwayFromZero) + 1, 1, 10);
}
