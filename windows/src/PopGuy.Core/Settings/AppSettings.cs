using System.Text.Json;
using System.Text.Json.Serialization;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;

namespace PopGuy.Core.Settings;

/// <summary>
/// Everything in settings.json (spec-3 §1; macOS <c>SettingsStore.swift</c>). JSON names are the macOS UserDefaults
/// keys without the <c>settings.</c> prefix; defaults are the macOS ones (spec-1 §0). The MLX and Dock keys are not
/// ported; the Windows keys are <c>ignoredAppExeNames</c>, <c>defaultLocalModelID</c> and the Windows
/// <see cref="Shortcut"/> form. A missing key
/// reads as its default. API keys are never stored here: they live in Windows Credential Manager.
/// </summary>
public sealed record AppSettings
{
    // Built-in action configs and enable flags (spec-3 §1.1-1.2). Look up's flag is dictionaryConfig.isEnabled.
    [JsonPropertyName("improveConfig")] public ActionConfig ImproveConfig { get; init; } = ActionConfig.Default(ActionKind.Improve);
    [JsonPropertyName("shortenConfig")] public ActionConfig ShortenConfig { get; init; } = ActionConfig.Default(ActionKind.Shorten);
    [JsonPropertyName("proofreadConfig")] public ActionConfig ProofreadConfig { get; init; } = ActionConfig.Default(ActionKind.Proofread);
    [JsonPropertyName("translateConfig")] public ActionConfig TranslateConfig { get; init; } = ActionConfig.Default(ActionKind.Translate);
    [JsonPropertyName("promptConfig")] public ActionConfig PromptConfig { get; init; } = ActionConfig.Default(ActionKind.Prompt);
    [JsonPropertyName("improveEnabled")] public bool ImproveEnabled { get; init; } = true;
    [JsonPropertyName("shortenEnabled")] public bool ShortenEnabled { get; init; } = true;
    [JsonPropertyName("proofreadEnabled")] public bool ProofreadEnabled { get; init; } = true;
    [JsonPropertyName("translateEnabled")] public bool TranslateEnabled { get; init; } = true;
    [JsonPropertyName("speakEnabled")] public bool SpeakEnabled { get; init; } = true;
    [JsonPropertyName("promptEnabled")] public bool PromptEnabled { get; init; }

    // Translate, provider endpoints, CLI paths (§1.3). CLI paths start empty: detection is per-OS.
    [JsonPropertyName("targetLanguage")] public string DefaultTargetLanguage { get; init; } = "en";
    [JsonPropertyName("ollamaBaseURL")] public string OllamaBaseUrl { get; init; } = "http://localhost:11434/v1";
    [JsonPropertyName("customBaseURL")] public string CustomBaseUrl { get; init; } = "";
    [JsonPropertyName("claudeCLIPath")] public string ClaudeCliPath { get; init; } = "";
    [JsonPropertyName("codexCLIPath")] public string CodexCliPath { get; init; } = "";
    [JsonPropertyName("geminiCLIPath")] public string GeminiCliPath { get; init; } = "";

    // Speak, Look up, dictionaries, cloud TTS (§1.4).
    [JsonPropertyName("speakSettings")] public SpeakSettings SpeakSettings { get; init; } = new();
    [JsonPropertyName("dictionaryConfig")] public DictionaryConfig DictionaryConfig { get; init; } = new();
    [JsonPropertyName("babylonDictionaries")] public IReadOnlyList<BabylonDictionary> BabylonDictionaries { get; init; } = [];

    /// <summary>Keyed by <see cref="TtsProviderKind"/> raw value; a missing entry means the default config.</summary>
    [JsonPropertyName("ttsProviderConfigs")]
    public IReadOnlyDictionary<string, TtsProviderConfig> TtsProviderConfigs { get; init; } = new Dictionary<string, TtsProviderConfig>();

    // Custom actions, hotkeys, toolbar layout (§1.5). Change custom actions through SettingsStore's mutation API.
    [JsonPropertyName("customActions")] public IReadOnlyList<CustomAction> CustomActions { get; init; } = [];
    [JsonPropertyName("shortcutBindings")] public IReadOnlyList<ShortcutBinding> ShortcutBindings { get; init; } = ShortcutBinding.DefaultBuiltins;

    /// <summary>The display order of every action, built-ins and custom actions interleaved.</summary>
    [JsonPropertyName("actionOrder")] public IReadOnlyList<ActionIdentifier> ActionOrder { get; init; } = DefaultBuiltinOrder;

    /// <summary>
    /// The actions on the inline toolbar row (a set; order is meaningless). Null means never set (first launch, to be
    /// migrated); empty is the user's choice of everything in More actions.
    /// </summary>
    [JsonPropertyName("principalActionIDs")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<ActionIdentifier>? PrincipalActionIds { get; init; }

    /// <summary>The actions whose button shows its label (a set), kept while the action sits in More actions.</summary>
    [JsonPropertyName("labeledActionIDs")] public IReadOnlyList<ActionIdentifier> LabeledActionIds { get; init; } = [];

    // Triggers and the master switch (§1.6).
    [JsonPropertyName("popGuyEnabled")] public bool PopGuyEnabled { get; init; } = true;
    [JsonPropertyName("triggerOnSelect")] public bool TriggerOnSelectEnabled { get; init; }
    [JsonPropertyName("triggerOnSelectEditableOnly")] public bool TriggerOnSelectEditableOnly { get; init; }
    [JsonPropertyName("triggerDoubleClick")] public bool TriggerDoubleClickEnabled { get; init; }

    /// <summary>When set, a double-click runs this action instead of showing the toolbar.</summary>
    [JsonPropertyName("doubleClickAssignedAction")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ActionIdentifier? DoubleClickAssignedAction { get; init; }

    /// <summary>The Ctrl+C+C double-tap (the macOS Cmd+C+C chord).</summary>
    [JsonPropertyName("triggerChord")] public bool TriggerChordEnabled { get; init; } = true;

    /// <summary>When set (and the chord is on), this hotkey replaces the Ctrl+C+C chord.</summary>
    [JsonPropertyName("chordReplacementShortcut")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Shortcut? ChordReplacementShortcut { get; init; }

    [JsonPropertyName("ocrEnabled")] public bool OcrEnabled { get; init; }

    [JsonPropertyName("ocrShortcut")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Shortcut? OcrShortcut { get; init; }

    /// <summary>
    /// Windows only: the local model (a <c>gguf-…</c> catalog id) an action runs when its model id is empty or names
    /// no local model, set on Settings → Providers → Local AI; null is the catalog's default.
    /// </summary>
    [JsonPropertyName("defaultLocalModelID")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? DefaultLocalModelId { get; init; }

    // Ignore lists (§1.7). Apps are matched by process exe name (e.g. "keepass.exe"), not a bundle id.
    [JsonPropertyName("ignoredAppsEnabled")] public bool IgnoredAppsEnabled { get; init; } = true;
    [JsonPropertyName("ignoredAppExeNames")] public IReadOnlyList<string> IgnoredAppExeNames { get; init; } = [];
    [JsonPropertyName("ignoredDomainsEnabled")] public bool IgnoredDomainsEnabled { get; init; }
    [JsonPropertyName("ignoredDomains")] public IReadOnlyList<string> IgnoredDomains { get; init; } = [];

    // General, appearance, behaviour (§1.8).
    [JsonPropertyName("hasOnboarded")] public bool HasOnboarded { get; init; }
    [JsonPropertyName("confirmCloseAfterResult")] public bool ConfirmCloseAfterResult { get; init; } = true;
    [JsonPropertyName("resultFontSize")] public ResultFontSize ResultFontSize { get; init; } = ResultFontSize.Normal;
    [JsonPropertyName("preserveFormatting")] public bool PreserveFormatting { get; init; }

    /// <summary>Prepended to every AI action prompt.</summary>
    [JsonPropertyName("globalPrompt")] public string GlobalPrompt { get; init; } = "";

    [JsonPropertyName("toolbarZoom")] public ToolbarZoom ToolbarZoom { get; init; } = ToolbarZoom.X1;
    [JsonPropertyName("zoomIncludesFontSize")] public bool ZoomIncludesFontSize { get; init; } = true;
    [JsonPropertyName("showToolbarSettingsButton")] public bool ShowToolbarSettingsButton { get; init; } = true;
    [JsonPropertyName("hideToolbarLogo")] public bool HideToolbarLogo { get; init; }
    [JsonPropertyName("inlineToolbarSystemButtons")] public bool InlineToolbarSystemButtons { get; init; }

    // History (§1.9).
    [JsonPropertyName("historyEnabled")] public bool HistoryEnabled { get; init; } = true;
    [JsonPropertyName("historyStoreFullText")] public bool HistoryStoreFullText { get; init; } = true;

    /// <summary>Keys this build does not know (a newer version's), written back unchanged on save.</summary>
    [JsonExtensionData] public Dictionary<string, JsonElement>? UnknownKeys { get; init; }

    /// <summary>The fresh-install order: Improve, Shorten, Proofread, Prompt, Translate, Look up, Speak.</summary>
    public static IReadOnlyList<ActionIdentifier> DefaultBuiltinOrder { get; } =
    [
        ActionIdentifier.Builtin(ActionKind.Improve),
        ActionIdentifier.Builtin(ActionKind.Shorten),
        ActionIdentifier.Builtin(ActionKind.Proofread),
        ActionIdentifier.Builtin(ActionKind.Prompt),
        ActionIdentifier.Builtin(ActionKind.Translate),
        ActionIdentifier.Dictionary,
        ActionIdentifier.Speak,
    ];
}

/// <summary>A built-in action's provider and model (macOS <c>ActionConfig.swift</c>). nil optionals are omitted.</summary>
public sealed record ActionConfig(
    [property: JsonPropertyName("id")] ActionKind Id,
    [property: JsonPropertyName("providerKind")] ProviderKind ProviderKind,
    [property: JsonPropertyName("model")] string Model)
{
    /// <summary>The first curated OpenAI model, as on macOS (the spec's "gpt-5.5" is stale).</summary>
    public const string DefaultModel = "gpt-6.1-sol";

    /// <summary>Improve, Shorten, Proofread: replaces the predefined prompt. Translate: added to it. Null: none.</summary>
    [JsonPropertyName("customPrompt")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? CustomPrompt { get; init; }

    /// <summary>Null means neutral. Proofread ignores it.</summary>
    [JsonPropertyName("tone")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public TranslateTone? Tone { get; init; }

    public static ActionConfig Default(ActionKind kind) => new(kind, ProviderKind.OpenAi, DefaultModel);
}

/// <summary>A user-loaded Babylon .bgl file (metadata only; the file stays where it is).</summary>
public sealed record BabylonDictionary
{
    [JsonPropertyName("id")] public required Guid Id { get; init; }
    [JsonPropertyName("displayName")] public required string DisplayName { get; init; }
    [JsonPropertyName("filePath")] public required string FilePath { get; init; }
    [JsonPropertyName("isEnabled")] public required bool IsEnabled { get; init; }
    [JsonPropertyName("entryCount")] public required int EntryCount { get; init; }
    [JsonPropertyName("sourceLanguage")] public string SourceLanguage { get; init; } = "";
    [JsonPropertyName("targetLanguage")] public string TargetLanguage { get; init; } = "";
}

[JsonConverter(typeof(RawValueEnumConverter<ResultFontSize>))]
public enum ResultFontSize
{
    [JsonStringEnumMemberName("small")] Small,
    [JsonStringEnumMemberName("normal")] Normal,
    [JsonStringEnumMemberName("big")] Big,
}

/// <summary>Toolbar zoom: 1.0, 1.2 or 1.3.</summary>
[JsonConverter(typeof(RawValueEnumConverter<ToolbarZoom>))]
public enum ToolbarZoom
{
    [JsonStringEnumMemberName("x1")] X1,
    [JsonStringEnumMemberName("x1_2")] X1_2,
    [JsonStringEnumMemberName("x1_3")] X1_3,
}
