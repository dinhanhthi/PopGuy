using System.Text.Json;
using System.Text.Json.Serialization;
using PopGuy.Core.Json;

namespace PopGuy.Core.Actions;

// The action enums and value types of the macOS app (spec-3 §2.2-2.5), with their exact JSON raw values.
// Swift sources: ActionConfig.swift, CustomAction.swift, ActionIcon.swift, ProviderTypes.swift, SpeakSettings.swift,
// TTSProviderKind.swift, TTSProviderConfig.swift, DictionaryConfig.swift, DictionaryProvider.swift.

/// <summary>Built-in action ids.</summary>
[JsonConverter(typeof(RawValueEnumConverter<ActionKind>))]
public enum ActionKind
{
    [JsonStringEnumMemberName("improve")] Improve,
    [JsonStringEnumMemberName("shorten")] Shorten,
    [JsonStringEnumMemberName("proofread")] Proofread,
    [JsonStringEnumMemberName("translate")] Translate,
    [JsonStringEnumMemberName("prompt")] Prompt,
}

/// <summary>Discriminator of a user-defined action. Declaration order is the picker order.</summary>
[JsonConverter(typeof(RawValueEnumConverter<CustomActionType>))]
public enum CustomActionType
{
    [JsonStringEnumMemberName("ai")] Ai,
    [JsonStringEnumMemberName("translation")] Translation,
    [JsonStringEnumMemberName("speech")] Speech,
    [JsonStringEnumMemberName("dictionary")] Dictionary,
    [JsonStringEnumMemberName("openURL")] OpenUrl,
    [JsonStringEnumMemberName("runShortcut")] RunShortcut,
    [JsonStringEnumMemberName("appleScript")] AppleScript,
    [JsonStringEnumMemberName("shellScript")] ShellScript,
}

/// <summary>What a scriptable action does with its output.</summary>
[JsonConverter(typeof(RawValueEnumConverter<AfterRunBehavior>))]
public enum AfterRunBehavior
{
    [JsonStringEnumMemberName("closeToolbar")] CloseToolbar,
    [JsonStringEnumMemberName("none")] None,
    [JsonStringEnumMemberName("copyResult")] CopyResult,
    [JsonStringEnumMemberName("pasteResult")] PasteResult,
    [JsonStringEnumMemberName("showResult")] ShowResult,
}

/// <summary>Translation tone.</summary>
[JsonConverter(typeof(RawValueEnumConverter<TranslateTone>))]
public enum TranslateTone
{
    [JsonStringEnumMemberName("neutral")] Neutral,
    [JsonStringEnumMemberName("formal")] Formal,
    [JsonStringEnumMemberName("casual")] Casual,
    [JsonStringEnumMemberName("professional")] Professional,
    [JsonStringEnumMemberName("friendly")] Friendly,
}

/// <summary>AI and translation providers.</summary>
[JsonConverter(typeof(RawValueEnumConverter<ProviderKind>))]
public enum ProviderKind
{
    [JsonStringEnumMemberName("openai")] OpenAi,
    [JsonStringEnumMemberName("anthropic")] Anthropic,
    [JsonStringEnumMemberName("ollama")] Ollama,
    [JsonStringEnumMemberName("deepl")] DeepL,
    [JsonStringEnumMemberName("google_translate")] GoogleTranslate,
    [JsonStringEnumMemberName("gemini")] Gemini,
    [JsonStringEnumMemberName("glm")] Glm,
    [JsonStringEnumMemberName("openrouter")] OpenRouter,
    [JsonStringEnumMemberName("custom")] Custom,
    [JsonStringEnumMemberName("claude_cli")] ClaudeCli,
    [JsonStringEnumMemberName("codex_cli")] CodexCli,
    [JsonStringEnumMemberName("gemini_cli")] GeminiCli,
    [JsonStringEnumMemberName("mlx_local")] MlxLocal,
}

[JsonConverter(typeof(RawValueEnumConverter<ActionIconType>))]
public enum ActionIconType
{
    [JsonStringEnumMemberName("sfSymbol")] SfSymbol,
    [JsonStringEnumMemberName("emoji")] Emoji,
}

/// <summary>A toolbar icon: <c>{"type":"sfSymbol"|"emoji","value":"..."}</c>. Both keys are required.</summary>
public sealed record ActionIcon(
    [property: JsonPropertyName("type")] ActionIconType Type,
    [property: JsonPropertyName("value")] string Value)
{
    public static ActionIcon Default { get; } = SfSymbol("sparkles");

    public static ActionIcon SfSymbol(string name) => new(ActionIconType.SfSymbol, name);

    public static ActionIcon Emoji(string character) => new(ActionIconType.Emoji, character);
}

public enum ActionIdentifierType { Builtin, Custom, Speak, Dictionary }

/// <summary>
/// Any action, built-in or user-defined (the key of shortcut bindings). JSON: <c>{"type":"builtin","value":"improve"}</c>,
/// <c>{"type":"custom","value":"&lt;UPPERCASE UUID&gt;"}</c>, <c>{"type":"speak"}</c>, <c>{"type":"dictionary"}</c>.
/// </summary>
[JsonConverter(typeof(ActionIdentifierConverter))]
public sealed record ActionIdentifier
{
    private ActionIdentifier(ActionIdentifierType type, ActionKind? builtinKind = null, Guid? customId = null)
    {
        Type = type;
        BuiltinKind = builtinKind;
        CustomId = customId;
    }

    public ActionIdentifierType Type { get; }

    /// <summary>Set only when <see cref="Type"/> is <see cref="ActionIdentifierType.Builtin"/>.</summary>
    public ActionKind? BuiltinKind { get; }

    /// <summary>Set only when <see cref="Type"/> is <see cref="ActionIdentifierType.Custom"/>.</summary>
    public Guid? CustomId { get; }

    public static ActionIdentifier Builtin(ActionKind kind) => new(ActionIdentifierType.Builtin, builtinKind: kind);

    public static ActionIdentifier Custom(Guid id) => new(ActionIdentifierType.Custom, customId: id);

    public static ActionIdentifier Speak { get; } = new(ActionIdentifierType.Speak);

    public static ActionIdentifier Dictionary { get; } = new(ActionIdentifierType.Dictionary);
}

internal sealed class ActionIdentifierConverter : JsonConverter<ActionIdentifier>
{
    public override ActionIdentifier Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        var type = JsonRead.RequiredString(root, "type");
        switch (type)
        {
            case "speak":
                return ActionIdentifier.Speak;
            case "dictionary":
                return ActionIdentifier.Dictionary;
            case "builtin":
                var raw = JsonRead.RequiredString(root, "value");
                return RawValueEnumConverter<ActionKind>.TryParse(raw, out var kind)
                    ? ActionIdentifier.Builtin(kind)
                    : throw new JsonException($"Unknown ActionKind: {raw}");
            case "custom":
                return ActionIdentifier.Custom(JsonRead.Uuid(JsonRead.RequiredString(root, "value")));
            default:
                throw new JsonException($"Unknown ActionIdentifier type: {type}");
        }
    }

    public override void Write(Utf8JsonWriter writer, ActionIdentifier value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        switch (value.Type)
        {
            case ActionIdentifierType.Builtin:
                writer.WriteString("type", "builtin");
                writer.WriteString("value", RawValueEnumConverter<ActionKind>.ToRaw(value.BuiltinKind!.Value));
                break;
            case ActionIdentifierType.Custom:
                writer.WriteString("type", "custom");
                writer.WriteString("value", JsonRead.UuidString(value.CustomId!.Value));
                break;
            case ActionIdentifierType.Speak:
                writer.WriteString("type", "speak");
                break;
            case ActionIdentifierType.Dictionary:
                writer.WriteString("type", "dictionary");
                break;
        }
        writer.WriteEndObject();
    }
}

// MARK: - Speech

[JsonConverter(typeof(RawValueEnumConverter<SpeakAccent>))]
public enum SpeakAccent
{
    [JsonStringEnumMemberName("usEnglish")] UsEnglish,
    [JsonStringEnumMemberName("ukEnglish")] UkEnglish,
    [JsonStringEnumMemberName("french")] French,
    [JsonStringEnumMemberName("spanish")] Spanish,
    [JsonStringEnumMemberName("german")] German,
}

[JsonConverter(typeof(RawValueEnumConverter<TtsProviderKind>))]
public enum TtsProviderKind
{
    [JsonStringEnumMemberName("openai_tts")] OpenAiTts,
    [JsonStringEnumMemberName("google_cloud_tts")] GoogleCloudTts,
    [JsonStringEnumMemberName("azure_tts")] AzureTts,
}

/// <summary>
/// The speech engine: JSON <c>"system"</c> or <c>"cloud:&lt;TtsProviderKind raw&gt;"</c>. Decoding never fails: any
/// unknown or malformed value reads as <see cref="System"/> (macOS parity).
/// </summary>
[JsonConverter(typeof(SpeakEngineSelectionConverter))]
public readonly record struct SpeakEngineSelection(TtsProviderKind? CloudProvider)
{
    public static SpeakEngineSelection System => default;

    public static SpeakEngineSelection Cloud(TtsProviderKind kind) => new(kind);
}

internal sealed class SpeakEngineSelectionConverter : JsonConverter<SpeakEngineSelection>
{
    private const string CloudPrefix = "cloud:";

    public override SpeakEngineSelection Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string? raw = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
        reader.Skip();
        return raw is not null
            && raw.StartsWith(CloudPrefix, StringComparison.Ordinal)
            && RawValueEnumConverter<TtsProviderKind>.TryParse(raw[CloudPrefix.Length..], out var kind)
            ? SpeakEngineSelection.Cloud(kind)
            : SpeakEngineSelection.System;
    }

    public override void Write(Utf8JsonWriter writer, SpeakEngineSelection value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.CloudProvider is { } kind
            ? CloudPrefix + RawValueEnumConverter<TtsProviderKind>.ToRaw(kind)
            : "system");
}

/// <summary>Speech settings. Every key is optional on decode; nil optionals are omitted on encode.</summary>
public sealed record SpeakSettings
{
    public static IReadOnlyList<SpeakAccent> DefaultQuickSwitchAccents { get; } =
        [SpeakAccent.UsEnglish, SpeakAccent.UkEnglish, SpeakAccent.French, SpeakAccent.Spanish, SpeakAccent.German];

    [JsonPropertyName("defaultAccent")]
    public SpeakAccent DefaultAccent { get; init; } = SpeakAccent.UsEnglish;

    [JsonPropertyName("defaultVoiceID")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? DefaultVoiceId { get; init; }

    /// <summary>Unknown accents are dropped on decode; an absent or wrong-typed key reads as the default list.</summary>
    [JsonPropertyName("quickSwitchAccents")]
    [JsonConverter(typeof(QuickSwitchAccentsConverter))]
    public IReadOnlyList<SpeakAccent> QuickSwitchAccents { get; init; } = DefaultQuickSwitchAccents;

    /// <summary>The macOS AVSpeech scale (0.0-1.0, default 0.5); map it to the Windows engine's scale.</summary>
    [JsonPropertyName("rate")]
    public float Rate { get; init; } = 0.5f;

    [JsonPropertyName("pitch")]
    public float Pitch { get; init; } = 1.0f;

    [JsonPropertyName("dictionaryAudioEnabled")]
    public bool DictionaryAudioEnabled { get; init; } = true;

    [JsonPropertyName("selectedEngine")]
    public SpeakEngineSelection SelectedEngine { get; init; } = SpeakEngineSelection.System;

    [JsonPropertyName("cloudCharLimit")]
    public int CloudCharLimit { get; init; } = 600;
}

internal sealed class QuickSwitchAccentsConverter : JsonConverter<IReadOnlyList<SpeakAccent>>
{
    public override bool HandleNull => true;

    public override IReadOnlyList<SpeakAccent> Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        // Swift decodes [String]: anything else (null, wrong type, a non-string element) falls back to the default.
        if (root.ValueKind != JsonValueKind.Array || root.EnumerateArray().Any(e => e.ValueKind != JsonValueKind.String))
            return SpeakSettings.DefaultQuickSwitchAccents;
        var accents = new List<SpeakAccent>();
        foreach (var element in root.EnumerateArray())
        {
            if (RawValueEnumConverter<SpeakAccent>.TryParse(element.GetString()!, out var accent))
                accents.Add(accent);
        }
        return accents;
    }

    public override void Write(Utf8JsonWriter writer, IReadOnlyList<SpeakAccent> value, JsonSerializerOptions options)
    {
        writer.WriteStartArray();
        foreach (var accent in value)
            writer.WriteStringValue(RawValueEnumConverter<SpeakAccent>.ToRaw(accent));
        writer.WriteEndArray();
    }
}

/// <summary>Cloud TTS configuration. Every key is optional on decode; nil optionals are omitted on encode.</summary>
public sealed record TtsProviderConfig
{
    /// <summary>BCP-47 tag → voice id. Always written, even when empty.</summary>
    [JsonPropertyName("voiceOverrides")]
    public IReadOnlyDictionary<string, string> VoiceOverrides { get; init; } = new Dictionary<string, string>();

    [JsonPropertyName("defaultVoice")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? DefaultVoice { get; init; }

    /// <summary>Null means the provider default (OpenAI: gpt-4o-mini-tts).</summary>
    [JsonPropertyName("model")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Model { get; init; }

    /// <summary>Azure only, e.g. "eastus".</summary>
    [JsonPropertyName("region")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Region { get; init; }
}

// MARK: - Dictionary

[JsonConverter(typeof(RawValueEnumConverter<DictionaryProviderKind>))]
public enum DictionaryProviderKind
{
    [JsonStringEnumMemberName("macOSBuiltin")] MacOSBuiltin,
    [JsonStringEnumMemberName("minhqnd")] Minhqnd,
    [JsonStringEnumMemberName("freeDictionaryAPI")] FreeDictionaryApi,
    [JsonStringEnumMemberName("babylonBGL")] BabylonBgl,
}

/// <summary>Dictionary lookup configuration. Every key is optional on decode.</summary>
public sealed record DictionaryConfig
{
    [JsonPropertyName("provider")]
    public DictionaryProviderKind Provider { get; init; } = DictionaryProviderKind.MacOSBuiltin;

    [JsonPropertyName("definitionLanguage")]
    public string DefinitionLanguage { get; init; } = "en";

    [JsonPropertyName("isEnabled")]
    public bool IsEnabled { get; init; }

    [JsonPropertyName("speakSettings")]
    public SpeakSettings SpeakSettings { get; init; } = new();

    [JsonPropertyName("accent")]
    public SpeakAccent Accent { get; init; } = SpeakAccent.UsEnglish;
}
