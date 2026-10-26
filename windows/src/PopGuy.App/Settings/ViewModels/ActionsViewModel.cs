using System.ComponentModel;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Secrets;
using PopGuy.Core.Settings;

namespace PopGuy.Settings.ViewModels;

/// <summary>The Actions page's type filter (macOS ActionTypeFilter), in menu order.</summary>
internal enum ActionTypeFilter
{
    All,
    Ai,
    Translation,
    Speech,
    Dictionary,
    OpenUrl,
    RunShortcut,
    AppleScript,
    ShellScript,
    FromPlugin,
}

/// <summary>A built-in action's card: its title, toolbar icon (SF Symbol name) and description.</summary>
internal sealed record BuiltinInfo(string Title, string Symbol, string Subtitle);

/// <summary>
/// The state and checks behind Settings → Actions (macOS ActionsView.swift): which cards show for the search and type
/// filter, the settings changes the cards make, and the model Check. Keys are read from the secret store (Credential
/// Manager) for a check only, off the UI thread, and never kept or logged. UI thread only, except where noted.
/// </summary>
internal sealed class ActionsViewModel
{
    private readonly SettingsStore _settings;
    private readonly ISecretStore _secrets;
    private readonly ProviderFactory _providers;
    private readonly Action<string> _log;

    public ActionsViewModel(SettingsStore settings, ISecretStore secrets, ProviderFactory providers, Action<string> log)
    {
        _settings = settings;
        _secrets = secrets;
        _providers = providers;
        _log = log;
    }

    public AppSettings Current => _settings.Current;

    /// <summary>Saves one change; a failed write is logged and false.</summary>
    public bool Save(string key, Func<AppSettings, AppSettings> change)
    {
        try
        {
            _settings.Update(change);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log($"settings: {key} not saved, {e.GetType().Name}");
            return false;
        }
    }

    // Cards and filter.

    /// <summary>The type filter's menu (macOS displayName).</summary>
    public static IReadOnlyList<(ActionTypeFilter Filter, string Name)> Filters { get; } =
    [
        (ActionTypeFilter.All, "All Types"),
        (ActionTypeFilter.Ai, "AI"),
        (ActionTypeFilter.Translation, "Translation"),
        (ActionTypeFilter.Speech, "Speech"),
        (ActionTypeFilter.Dictionary, "Dictionary"),
        (ActionTypeFilter.OpenUrl, "Open URL"),
        (ActionTypeFilter.RunShortcut, "Run Shortcut"),
        (ActionTypeFilter.AppleScript, "AppleScript"),
        (ActionTypeFilter.ShellScript, "Shell Script"),
        (ActionTypeFilter.FromPlugin, "From Plugin"),
    ];

    /// <summary>Every action with a card, in action order: Speak and Look up have none yet.</summary>
    public static IReadOnlyList<ActionIdentifier> CardIds(AppSettings settings) =>
        [.. settings.ActionOrder.Where(id => id.Type is ActionIdentifierType.Builtin or ActionIdentifierType.Custom)];

    /// <summary>
    /// The cards that match <paramref name="filter"/> and <paramref name="query"/> (trimmed, case-insensitive, in the
    /// title), in action order (macOS filteredActionOrder).
    /// </summary>
    public static IReadOnlyList<ActionIdentifier> Filtered(AppSettings settings, ActionTypeFilter filter, string query)
    {
        var q = query.Trim();
        return
        [
            .. CardIds(settings).Where(id =>
                Matches(settings, id, filter)
                && (q.Length == 0 || Title(settings, id).Contains(q, StringComparison.CurrentCultureIgnoreCase))),
        ];
    }

    private static bool Matches(AppSettings settings, ActionIdentifier id, ActionTypeFilter filter) => filter switch
    {
        ActionTypeFilter.All => true,
        ActionTypeFilter.FromPlugin => Custom(settings, id)?.IsFromPlugin ?? false,
        _ => ActionType(settings, id) == filter switch
        {
            ActionTypeFilter.Ai => CustomActionType.Ai,
            ActionTypeFilter.Translation => CustomActionType.Translation,
            ActionTypeFilter.Speech => CustomActionType.Speech,
            ActionTypeFilter.Dictionary => CustomActionType.Dictionary,
            ActionTypeFilter.OpenUrl => CustomActionType.OpenUrl,
            ActionTypeFilter.RunShortcut => CustomActionType.RunShortcut,
            ActionTypeFilter.AppleScript => CustomActionType.AppleScript,
            _ => CustomActionType.ShellScript,
        },
    };

    /// <summary>The action's type: Translate is translation, the other built-ins AI; a custom action has its own.</summary>
    public static CustomActionType ActionType(AppSettings settings, ActionIdentifier id) => id.Type switch
    {
        ActionIdentifierType.Builtin => id.BuiltinKind == ActionKind.Translate ? CustomActionType.Translation : CustomActionType.Ai,
        ActionIdentifierType.Speak => CustomActionType.Speech,
        ActionIdentifierType.Dictionary => CustomActionType.Dictionary,
        _ => Custom(settings, id)?.Type ?? CustomActionType.Ai,
    };

    /// <summary>The action's name (macOS displayTitle); an untitled custom action is "(untitled)", as on its card.</summary>
    public static string Title(AppSettings settings, ActionIdentifier id) => id.Type switch
    {
        ActionIdentifierType.Builtin => Builtin(id.BuiltinKind!.Value).Title,
        ActionIdentifierType.Speak => "Speak",
        ActionIdentifierType.Dictionary => "Dictionary",
        _ => Custom(settings, id)?.Title is { Length: > 0 } title ? title : "(untitled)",
    };

    public static CustomAction? Custom(AppSettings settings, ActionIdentifier id) =>
        id.Type == ActionIdentifierType.Custom ? settings.CustomActions.FirstOrDefault(a => a.Id == id.CustomId) : null;

    /// <summary>The built-in cards' titles, icons and descriptions (macOS card(for:)).</summary>
    public static BuiltinInfo Builtin(ActionKind kind) => kind switch
    {
        ActionKind.Improve => new("Improve", "wand.and.stars",
            "Fix grammar and improve clarity while preserving the original meaning and tone."),
        ActionKind.Shorten => new("Shorten", "text.badge.minus",
            "Make the selected text more concise and simpler without losing the main ideas."),
        ActionKind.Proofread => new("Proofread", "checkmark.bubble",
            "Fix spelling, grammar, and punctuation without changing the meaning or tone."),
        ActionKind.Prompt => new("Prompt", "bubble.and.pencil",
            "Type a one-off prompt for the selected text. Use {{text}} to place the selection; it's added automatically if omitted. Also available: {{app}}, {{date}}, {{language}}, {{domain}} (only when Ignored Domains is on)."),
        _ => new("Translate", "character.bubble", "Translate the selected text into your chosen language."),
    };

    // Settings changes.

    public static ActionConfig Config(AppSettings settings, ActionKind kind) => kind switch
    {
        ActionKind.Improve => settings.ImproveConfig,
        ActionKind.Shorten => settings.ShortenConfig,
        ActionKind.Proofread => settings.ProofreadConfig,
        ActionKind.Prompt => settings.PromptConfig,
        _ => settings.TranslateConfig,
    };

    public static AppSettings WithConfig(AppSettings settings, ActionKind kind, Func<ActionConfig, ActionConfig> change) => kind switch
    {
        ActionKind.Improve => settings with { ImproveConfig = change(settings.ImproveConfig) },
        ActionKind.Shorten => settings with { ShortenConfig = change(settings.ShortenConfig) },
        ActionKind.Proofread => settings with { ProofreadConfig = change(settings.ProofreadConfig) },
        ActionKind.Prompt => settings with { PromptConfig = change(settings.PromptConfig) },
        _ => settings with { TranslateConfig = change(settings.TranslateConfig) },
    };

    /// <summary>The custom action changed by <paramref name="change"/>; nothing when it is gone.</summary>
    public static AppSettings WithCustom(AppSettings settings, ActionIdentifier id, Func<CustomAction, CustomAction> change) =>
        settings with { CustomActions = [.. settings.CustomActions.Select(a => a.Id == id.CustomId ? change(a) : a)] };

    /// <summary>
    /// The provider picker's entries: <paramref name="allowed"/> without the local model, which has no Windows adapter
    /// yet (macOS hides it on unsupported Macs), unless it is the saved one.
    /// </summary>
    public static IReadOnlyList<ProviderKind> PickerProviders(IReadOnlyList<ProviderKind> allowed, ProviderKind current) =>
        [.. allowed.Where(k => k != ProviderKind.MlxLocal || k == current)];

    // Model check (macOS ModelField.runCheck).

    /// <summary>
    /// Whether Check means anything for <paramref name="kind"/>: not for the translation services (no model), the CLIs
    /// (too slow to run for a name) or the local model, which ProviderModelValidator passes without a request.
    /// </summary>
    public static bool CanCheckModel(ProviderKind kind) => kind.UsesModel()
        && kind is not (ProviderKind.ClaudeCli or ProviderKind.CodexCli or ProviderKind.GeminiCli or ProviderKind.MlxLocal);

    /// <summary>
    /// A one-token call with <paramref name="model"/> and the saved key: no key (except Ollama) is NoKey, Custom
    /// without a base URL is NoEndpoint. Cancelling <paramref name="ct"/> throws.
    /// </summary>
    public async Task<VerifyOutcome> CheckModelAsync(ProviderKind kind, string model, CancellationToken ct)
    {
        var key = await Task.Run(() => ReadKey(kind), ct);
        if (kind != ProviderKind.Ollama && key is null) return VerifyOutcome.NoKey;
        var baseUrl = kind == ProviderKind.Custom ? CustomEndpoint() : null;
        if (kind == ProviderKind.Custom && baseUrl is null) return VerifyOutcome.NoEndpoint;
        try
        {
            await Task.Run(() => ProviderModelValidator.ValidateAsync(kind, key ?? "", model, _providers, baseUrl, ct), ct);
            return ProviderFeedback.MapModelCheckOutcome(null, customEndpointMissing: false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception e)
        {
            return ProviderFeedback.MapModelCheckOutcome(e, customEndpointMissing: false);
        }
    }

    /// <summary>The inline text of a model Check (macOS modelCheckFeedbackView).</summary>
    public static string CheckText(VerifyOutcome outcome) => outcome switch
    {
        VerifyOutcome.Valid => "Model OK",
        VerifyOutcome.Invalid => "Model not found or key invalid",
        VerifyOutcome.Unreachable => "Couldn't reach provider",
        VerifyOutcome.NoEndpoint => "Set the base URL first",
        _ => "No key saved",
    };

    /// <summary>Custom's base URL when it is an absolute http(s) URL, else null (not configured).</summary>
    private Uri? CustomEndpoint() =>
        Uri.TryCreate(_settings.Current.CustomBaseUrl.Trim(), UriKind.Absolute, out var url)
        && (url.Scheme == Uri.UriSchemeHttp || url.Scheme == Uri.UriSchemeHttps)
            ? url
            : null;

    /// <summary>Any thread. Null when none is saved or Credential Manager refused (logged, never the key).</summary>
    private string? ReadKey(ProviderKind kind)
    {
        try
        {
            return _secrets.Get(SecretIds.Provider(kind));
        }
        catch (Win32Exception e)
        {
            _log($"credentials: read failed for {kind}, error {e.NativeErrorCode}");
            return null;
        }
    }
}
