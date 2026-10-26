using System.Globalization;
using System.Text;
using System.Text.Json;
using PopGuy.Core.Json;

namespace PopGuy.Core.Actions;

/// <summary>Why a whole import file was refused.</summary>
public enum ImportRejection
{
    /// <summary>Over <see cref="ActionImport.MaxFileBytes"/>.</summary>
    TooLarge,

    /// <summary>Not a JSON array of valid actions (one bad element fails the whole file, as on macOS).</summary>
    Unreadable,

    /// <summary>Over <see cref="ActionImport.MaxActions"/>.</summary>
    TooManyActions,
}

/// <summary>
/// A sanitized action ready for the consent sheet. <paramref name="WrittenForMacShell"/>: a <c>shellScript</c> without
/// <c>shell: "powershell"</c>, imported disabled and shown as "written for macOS (zsh)".
/// </summary>
public sealed record ImportedAction(CustomAction Action, bool WrittenForMacShell);

/// <summary>
/// The import outcome: <see cref="Rejection"/> is set (and <see cref="Actions"/> empty) when the whole file is refused.
/// <see cref="SkippedCount"/> counts actions dropped for a provider their type does not allow.
/// </summary>
public sealed record ActionImportResult(ImportRejection? Rejection, IReadOnlyList<ImportedAction> Actions, int SkippedCount)
{
    public static ActionImportResult Rejected(ImportRejection reason) => new(reason, [], 0);
}

/// <summary>
/// The sole security gate for untrusted action files (spec-3 §2.10, spec-4 §5.2; macOS <c>CustomAction.swift</c>
/// "Import sanitization" and the import limits of <c>ActionsView.swift</c>).
/// </summary>
public static class ActionImport
{
    public const int MaxFileBytes = 2 * 1024 * 1024;
    public const int MaxActions = 100;

    /// <summary>
    /// Decodes and sanitizes an import file. Order: size, decode, count, then <see cref="Sanitize"/> each action, mark
    /// it <c>isFromPlugin</c>, and disable a script not written for PowerShell.
    /// </summary>
    public static ActionImportResult SanitizeImported(ReadOnlySpan<byte> json)
    {
        if (json.Length > MaxFileBytes)
            return ActionImportResult.Rejected(ImportRejection.TooLarge);

        // Windows editors may write a UTF-8 BOM, which the JSON reader refuses.
        if (json.StartsWith(Encoding.UTF8.Preamble))
            json = json[Encoding.UTF8.Preamble.Length..];

        List<CustomAction?>? decoded;
        try
        {
            decoded = JsonSerializer.Deserialize<List<CustomAction?>>(json, PopGuyJson.Options);
        }
        catch (JsonException)
        {
            return ActionImportResult.Rejected(ImportRejection.Unreadable);
        }
        // A top-level, element or dictionary-value null is not caught by the nullable annotations (macOS refuses these).
        if (decoded is null || decoded.Contains(null)
            || decoded.Any(a => a!.TtsConfig.VoiceOverrides.Values.Contains(null!)))
            return ActionImportResult.Rejected(ImportRejection.Unreadable);

        // macOS keeps the first 100; Windows refuses the file instead (plan 4.2).
        if (decoded.Count > MaxActions)
            return ActionImportResult.Rejected(ImportRejection.TooManyActions);

        var imported = new List<ImportedAction>();
        var skipped = 0;
        foreach (var action in decoded)
        {
            if (Prepare(action!) is { } prepared)
                imported.Add(prepared);
            else
                skipped++;
        }
        return new ActionImportResult(null, imported, skipped);
    }

    /// <summary>
    /// One action of any import path (native JSON, PopClip): <see cref="Sanitize"/>, mark it <c>isFromPlugin</c>, and
    /// disable a script not written for PowerShell. Null when <see cref="Sanitize"/> refuses the provider.
    /// </summary>
    public static ImportedAction? Prepare(CustomAction action)
    {
        if (Sanitize(action) is not { } safe)
            return null;
        var macShell = safe.Type == CustomActionType.ShellScript && safe.Shell is null;
        return new ImportedAction(safe with { IsFromPlugin = true, IsEnabled = safe.IsEnabled && !macShell }, macShell);
    }

    /// <summary>
    /// Port of macOS <c>sanitizeImported</c> for one action: null when an <c>ai</c>/<c>translation</c> action names a
    /// provider its type does not allow; otherwise a copy with a fresh id, every string clamped (by grapheme cluster,
    /// as Swift counts), <c>isFromPlugin</c> false, <c>libraryPresetID</c> cleared (an imported file must not claim a
    /// Library identity; a Library install sets it after this) and <c>shell</c> kept only when it is "powershell".
    /// The macOS cloud-TTS gate is not ported: production always allows cloud engines, so it is a no-op.
    /// </summary>
    public static CustomAction? Sanitize(CustomAction action)
    {
        if (!IsProviderAllowed(action.Type, action.ProviderKind))
            return null;

        var tts = action.TtsConfig;
        var voiceOverrides = new Dictionary<string, string>();
        // Two long keys can collide after clamping: the last one wins.
        foreach (var (key, value) in tts.VoiceOverrides.Take(20))
            voiceOverrides[Clamp(key, 20)] = Clamp(value, 100);

        var icon = action.Icon.Type == ActionIconType.SfSymbol
            ? ActionIcon.SfSymbol(Clamp(action.Icon.Value, 100))
            : ActionIcon.Emoji(Clamp(action.Icon.Value, 8));

        return action with
        {
            Id = Guid.NewGuid(),
            Title = Clamp(action.Title, 100),
            ActionDescription = Clamp(action.ActionDescription, 500),
            Icon = icon,
            SystemPrompt = Clamp(action.SystemPrompt, 10000),
            Model = Clamp(action.Model, 200),
            TargetLanguage = Clamp(action.TargetLanguage, 20),
            SpeakSettings = SanitizeSpeakSettings(action.SpeakSettings),
            TtsConfig = new TtsProviderConfig
            {
                VoiceOverrides = voiceOverrides,
                DefaultVoice = ClampOptional(tts.DefaultVoice, 100),
                Model = ClampOptional(tts.Model, 200),
                Region = ClampOptional(tts.Region, 50),
            },
            DictionaryConfig = action.DictionaryConfig with
            {
                DefinitionLanguage = Clamp(action.DictionaryConfig.DefinitionLanguage, 20),
                SpeakSettings = SanitizeSpeakSettings(action.DictionaryConfig.SpeakSettings),
            },
            ScriptSource = Clamp(action.ScriptSource, 20000),
            AppliesWhenRegex = Clamp(action.AppliesWhenRegex, 500),
            IsFromPlugin = false,
            LibraryPresetId = null,
            Shell = string.Equals(action.Shell, "powershell", StringComparison.Ordinal) ? action.Shell : null,
        };
    }

    /// <summary>macOS <c>allowedProviders(for:)</c>: AI takes every provider but the translation-only ones.</summary>
    private static bool IsProviderAllowed(CustomActionType type, ProviderKind provider) => type switch
    {
        CustomActionType.Ai => provider is not (ProviderKind.DeepL or ProviderKind.GoogleTranslate),
        _ => true,
    };

    private static SpeakSettings SanitizeSpeakSettings(SpeakSettings settings) => settings with
    {
        DefaultVoiceId = ClampOptional(settings.DefaultVoiceId, 100),
        QuickSwitchAccents = settings.QuickSwitchAccents.Count > 20
            ? settings.QuickSwitchAccents.Take(20).ToList()
            : settings.QuickSwitchAccents,
    };

    private static string? ClampOptional(string? value, int maxGraphemes) =>
        value is null ? null : Clamp(value, maxGraphemes);

    /// <summary>The first <paramref name="maxGraphemes"/> grapheme clusters, like Swift's <c>String.prefix</c>.</summary>
    private static string Clamp(string value, int maxGraphemes)
    {
        // Every grapheme is at least one UTF-16 unit, so a short string needs no scan.
        if (value.Length <= maxGraphemes)
            return value;
        var end = 0;
        for (var i = 0; i < maxGraphemes && end < value.Length; i++)
            end += StringInfo.GetNextTextElementLength(value, end);
        return value[..end];
    }
}
