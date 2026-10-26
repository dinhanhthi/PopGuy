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

public static class CustomActionTypeExtensions
{
    /// <summary>CustomActionType.displayName: a script run's history label and the engine's messages.</summary>
    public static string DisplayName(this CustomActionType type) => type switch
    {
        CustomActionType.Ai => "AI",
        CustomActionType.Translation => "Translation",
        CustomActionType.Speech => "Speech",
        CustomActionType.Dictionary => "Dictionary",
        CustomActionType.OpenUrl => "Open URL",
        CustomActionType.RunShortcut => "Run Shortcut",
        CustomActionType.AppleScript => "AppleScript",
        _ => "Shell Script",
    };
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

/// <summary>
/// A provider's name in messages and Settings, whether its runs name a model, its Settings hints, and which actions may
/// use it (macOS ProviderTypes.swift, ActionConfig.swift, CustomAction.swift).
/// </summary>
public static class ProviderKindExtensions
{
    // ProviderKind.displayName.
    public static string DisplayName(this ProviderKind kind) => kind switch
    {
        ProviderKind.OpenAi => "OpenAI",
        ProviderKind.Anthropic => "Anthropic (Claude)",
        ProviderKind.Ollama => "Ollama / LM Studio",
        ProviderKind.DeepL => "DeepL",
        ProviderKind.GoogleTranslate => "Google Translate",
        ProviderKind.Gemini => "Google Gemini",
        ProviderKind.Glm => "GLM / z.ai",
        ProviderKind.OpenRouter => "OpenRouter",
        ProviderKind.Custom => "Custom (OpenAI-compatible)",
        ProviderKind.ClaudeCli => "Claude CLI (subscription)",
        ProviderKind.CodexCli => "Codex CLI (subscription)",
        ProviderKind.GeminiCli => "Gemini CLI (subscription)",
        ProviderKind.MlxLocal => "Local (MLX)",
        _ => kind.ToString(),
    };

    // ProviderKind.usesModel: the translation services have no model.
    public static bool UsesModel(this ProviderKind kind) => kind is not (ProviderKind.DeepL or ProviderKind.GoogleTranslate);

    /// <summary>
    /// ProviderKind.curatedModels: the model suggestions in Settings (any id can still be typed). Empty for the
    /// user-defined runtimes and the translation services; the local model's catalog comes with its adapter.
    /// </summary>
    public static IReadOnlyList<string> CuratedModels(this ProviderKind kind) => kind switch
    {
        ProviderKind.OpenAi or ProviderKind.CodexCli => ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"],
        ProviderKind.Anthropic => ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"],
        ProviderKind.Gemini => ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite"],
        ProviderKind.Glm => ["glm-5.3", "glm-5.3-flashx", "glm-5.3-flash", "glm-5.2", "glm-5.1", "glm-4.7"],
        ProviderKind.OpenRouter => ["openai/gpt-6.1-sol", "anthropic/claude-opus-5.5", "google/gemini-4-argon", "z-ai/glm-5.3"],
        ProviderKind.ClaudeCli => ["opus", "sonnet", "haiku", "fable"],
        ProviderKind.GeminiCli => ["gemini-3.1-pro-preview", "gemini-3.8-flash", "gemini-3.5-flash-lite"],
        _ => [],
    };

    // ProviderKind.modelHint: the Model field's (i) text.
    public static string ModelHint(this ProviderKind kind) => kind switch
    {
        ProviderKind.OpenAi => "Enter an OpenAI model id, e.g. \"gpt-6.1-sol\" or \"gpt-6-luna\". Find available models in your OpenAI account.",
        ProviderKind.Anthropic => "Enter an Anthropic model id, e.g. \"claude-sonnet-5-5\" or \"claude-opus-5-5\". See Anthropic's model list for valid identifiers.",
        ProviderKind.Ollama => "Enter the name of a model installed in Ollama / LM Studio, e.g. \"llama3.1\" or \"qwen2.5\". Run `ollama list` to see installed models.",
        ProviderKind.DeepL => "DeepL handles translation automatically and does not use a model identifier — this field can be left empty.",
        ProviderKind.GoogleTranslate => "Google Translate handles translation automatically and does not use a model identifier — this field can be left empty.",
        ProviderKind.Gemini => "Enter a Gemini model id, e.g. \"gemini-4-argon\" or \"gemini-3.8-flash\". See Google AI for Developers for the current model list.",
        ProviderKind.Glm => "Enter a GLM model id, e.g. \"glm-5.3\" or \"glm-5.3-flash\". See the z.ai / BigModel documentation for available models.",
        ProviderKind.OpenRouter => "Enter an OpenRouter model id in provider/model format, e.g. \"openai/gpt-6.1-sol\" or \"google/gemini-4-argon\". Browse models at openrouter.ai.",
        ProviderKind.Custom => "Enter the model identifier expected by your custom OpenAI-compatible endpoint (e.g. the model name your local server advertises).",
        ProviderKind.ClaudeCli => "Optional. A model alias (opus/sonnet/haiku/fable) or full id; empty uses the CLI default.",
        ProviderKind.CodexCli => "Optional. A model id (e.g. gpt-6.1-sol); empty uses the CLI default.",
        ProviderKind.GeminiCli => "Optional. A model id (e.g. gemini-3.8-flash); empty uses the CLI default.",
        _ => "Local models are not available on Windows yet.",
    };

    /// <summary>ProviderKind.latencyWarning: shown under the provider picker for the subscription CLIs; null otherwise.</summary>
    public static string? LatencyWarning(this ProviderKind kind) =>
        kind is ProviderKind.ClaudeCli or ProviderKind.CodexCli or ProviderKind.GeminiCli
            ? "This provider runs a local CLI using your subscription — slower than the API providers (a few seconds, up to ~15s)."
            : null;

    /// <summary>
    /// The providers a built-in action may use (macOS ActionKind.allowedProviders): every one for Translate, every one
    /// but the translation services for the others. In declaration order (the picker order).
    /// </summary>
    public static IReadOnlyList<ProviderKind> AllowedProviders(ActionKind kind) => kind == ActionKind.Translate
        ? Enum.GetValues<ProviderKind>()
        : [.. Enum.GetValues<ProviderKind>().Where(UsesModel)];

    /// <summary>
    /// The providers a custom action may use (macOS CustomAction.allowedProviders(for:)): AI as Improve, translation as
    /// Translate; none for the types without a provider.
    /// </summary>
    public static IReadOnlyList<ProviderKind> AllowedProviders(CustomActionType type) => type switch
    {
        CustomActionType.Ai => AllowedProviders(ActionKind.Improve),
        CustomActionType.Translation => AllowedProviders(ActionKind.Translate),
        _ => [],
    };
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
