using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using PopGuy.Core.Json;

namespace PopGuy.Core.Actions;

/// <summary>
/// A user-defined action: the persisted form and the plugin export/import format (a JSON array of these), shared with
/// the macOS app (spec-3 §2, <c>CustomAction.swift</c>). The encoder always writes the 18 macOS keys, then
/// <c>libraryPresetID</c> and the Windows-only <c>shell</c> only when they are set.
/// </summary>
[JsonConverter(typeof(CustomActionConverter))]
public sealed record CustomAction
{
    /// <summary>Characters of the selection the visibility regex sees (bounds backtracking on large selections).</summary>
    public const int MaxRegexInputLength = 4096;

    /// <summary>A visibility regex that runs longer than this fails open (ReDoS guard for imported patterns).</summary>
    public static readonly TimeSpan RegexMatchTimeout = TimeSpan.FromMilliseconds(100);

    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Title { get; init; }
    public string ActionDescription { get; init; } = "";
    public ActionIcon Icon { get; init; } = ActionIcon.Default;
    public CustomActionType Type { get; init; } = CustomActionType.Ai;
    public required string SystemPrompt { get; init; }
    public ProviderKind ProviderKind { get; init; } = ProviderKind.Anthropic;
    public string Model { get; init; } = "claude-sonnet-5-5";
    public bool IsEnabled { get; init; } = true;
    public string TargetLanguage { get; init; } = "en";
    public TranslateTone Tone { get; init; } = TranslateTone.Neutral;
    public SpeakSettings SpeakSettings { get; init; } = new();
    public TtsProviderConfig TtsConfig { get; init; } = new();
    public DictionaryConfig DictionaryConfig { get; init; } = new();
    public string ScriptSource { get; init; } = "";

    /// <summary>A new action closes the toolbar; a decoded action without the key does nothing (macOS parity).</summary>
    public AfterRunBehavior AfterRun { get; init; } = AfterRunBehavior.CloseToolbar;

    public string AppliesWhenRegex { get; init; } = "";
    public bool IsFromPlugin { get; init; }

    /// <summary>The Action Library preset this action was installed from (e.g. "ai.humanize"), else null.</summary>
    public string? LibraryPresetId { get; init; }

    /// <summary>Windows only: the shell a <c>shellScript</c> runs in (e.g. "powershell"). The macOS app ignores it.</summary>
    public string? Shell { get; init; }

    /// <summary>The four types that run a script and honour <see cref="AppliesWhenRegex"/>.</summary>
    public bool IsScriptable => Type is CustomActionType.OpenUrl or CustomActionType.RunShortcut
        or CustomActionType.AppleScript or CustomActionType.ShellScript;

    /// <summary>
    /// False for the macOS-only types (AppleScript, Shortcuts): they are kept, so a settings file round-trips, but the
    /// toolbar hides them and lists them as "skipped on Windows".
    /// </summary>
    public bool RunnableOnWindows => Type is not (CustomActionType.AppleScript or CustomActionType.RunShortcut);

    /// <summary>
    /// Whether the action shows on the toolbar for <paramref name="selection"/>. Only scriptable types with a
    /// non-empty <see cref="AppliesWhenRegex"/> filter: visible iff the regex matches the first
    /// <see cref="MaxRegexInputLength"/> characters. An invalid or timed-out pattern fails open (shown). Cosmetic
    /// only: a hotkey still runs a hidden action.
    /// </summary>
    public bool IsVisible(string selection)
    {
        if (!IsScriptable || AppliesWhenRegex.Length == 0)
            return true;
        var searched = selection.Length > MaxRegexInputLength ? selection[..MaxRegexInputLength] : selection;
        try
        {
            // The static overload caches the parsed pattern.
            return Regex.IsMatch(searched, AppliesWhenRegex, RegexOptions.None, RegexMatchTimeout);
        }
        catch (RegexMatchTimeoutException)
        {
            return true;
        }
        catch (ArgumentException)
        {
            return true;
        }
    }
}

/// <summary>Mirrors <c>CustomAction.init(from:)</c> and <c>encode(to:)</c> in <c>CustomAction.swift</c>.</summary>
internal sealed class CustomActionConverter : JsonConverter<CustomAction>
{
    public override CustomAction Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var o = doc.RootElement;
        if (o.ValueKind != JsonValueKind.Object)
            throw new JsonException("A custom action must be a JSON object.");

        return new CustomAction
        {
            // Required, as in Swift: a missing key fails the decode.
            Id = JsonRead.Uuid(JsonRead.RequiredString(o, "id")),
            Title = JsonRead.RequiredString(o, "title"),
            SystemPrompt = JsonRead.RequiredString(o, "systemPrompt"),
            ProviderKind = JsonRead.Required<ProviderKind>(o, "providerKind", options),
            Model = JsonRead.RequiredString(o, "model"),
            IsEnabled = JsonRead.RequiredBool(o, "isEnabled"),
            // Added by later macOS builds: absent reads as the default.
            ActionDescription = JsonRead.OptionalString(o, "actionDescription") ?? "",
            Icon = JsonRead.Optional<ActionIcon>(o, "icon", options)
                ?? (JsonRead.OptionalString(o, "iconSystemName") is { } legacyName
                    ? ActionIcon.SfSymbol(legacyName)
                    : ActionIcon.Default),
            Type = JsonRead.OptionalValue<CustomActionType>(o, "type", options) ?? CustomActionType.Ai,
            TargetLanguage = JsonRead.OptionalString(o, "targetLanguage") ?? "en",
            Tone = JsonRead.OptionalValue<TranslateTone>(o, "tone", options) ?? TranslateTone.Neutral,
            SpeakSettings = JsonRead.Optional<SpeakSettings>(o, "speakSettings", options) ?? new(),
            TtsConfig = JsonRead.Optional<TtsProviderConfig>(o, "ttsConfig", options) ?? new(),
            DictionaryConfig = JsonRead.Optional<DictionaryConfig>(o, "dictionaryConfig", options) ?? new(),
            ScriptSource = JsonRead.OptionalString(o, "scriptSource") ?? "",
            AfterRun = JsonRead.OptionalValue<AfterRunBehavior>(o, "afterRun", options) ?? AfterRunBehavior.None,
            AppliesWhenRegex = JsonRead.OptionalString(o, "appliesWhenRegex") ?? "",
            IsFromPlugin = JsonRead.OptionalBool(o, "isFromPlugin") ?? false,
            LibraryPresetId = JsonRead.OptionalString(o, "libraryPresetID"),
            Shell = JsonRead.OptionalString(o, "shell"),
        };
    }

    public override void Write(Utf8JsonWriter writer, CustomAction value, JsonSerializerOptions options)
    {
        // The macOS encode order.
        writer.WriteStartObject();
        writer.WriteString("id", JsonRead.UuidString(value.Id));
        writer.WriteString("title", value.Title);
        writer.WriteString("actionDescription", value.ActionDescription);
        writer.WritePropertyName("icon");
        JsonSerializer.Serialize(writer, value.Icon, options);
        writer.WriteString("systemPrompt", value.SystemPrompt);
        writer.WriteString("providerKind", RawValueEnumConverter<ProviderKind>.ToRaw(value.ProviderKind));
        writer.WriteString("model", value.Model);
        writer.WriteBoolean("isEnabled", value.IsEnabled);
        writer.WriteString("type", RawValueEnumConverter<CustomActionType>.ToRaw(value.Type));
        writer.WriteString("targetLanguage", value.TargetLanguage);
        writer.WriteString("tone", RawValueEnumConverter<TranslateTone>.ToRaw(value.Tone));
        writer.WritePropertyName("speakSettings");
        JsonSerializer.Serialize(writer, value.SpeakSettings, options);
        writer.WritePropertyName("ttsConfig");
        JsonSerializer.Serialize(writer, value.TtsConfig, options);
        writer.WritePropertyName("dictionaryConfig");
        JsonSerializer.Serialize(writer, value.DictionaryConfig, options);
        writer.WriteString("scriptSource", value.ScriptSource);
        writer.WriteString("afterRun", RawValueEnumConverter<AfterRunBehavior>.ToRaw(value.AfterRun));
        writer.WriteString("appliesWhenRegex", value.AppliesWhenRegex);
        writer.WriteBoolean("isFromPlugin", value.IsFromPlugin);
        if (value.LibraryPresetId is { } presetId)
            writer.WriteString("libraryPresetID", presetId);
        if (value.Shell is { } shell)
            writer.WriteString("shell", shell);
        writer.WriteEndObject();
    }
}
