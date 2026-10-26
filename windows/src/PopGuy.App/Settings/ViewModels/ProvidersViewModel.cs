using System.ComponentModel;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;
using PopGuy.Core.Providers;
using PopGuy.Core.Providers.Cli;
using PopGuy.Core.Secrets;
using PopGuy.Core.Settings;

namespace PopGuy.Settings.ViewModels;

/// <summary>
/// The state and checks behind Settings → Providers (macOS SettingsView.swift APIKeysTab). Keys go to and come from
/// the secret store (Credential Manager) only: this class never keeps one, logs one or hands one to the UI — a key is
/// read, masked or checked, and dropped. Every key check, Credential Manager call and CLI lookup runs off the UI
/// thread; the awaits come back to it (UI thread only).
/// </summary>
internal sealed class ProvidersViewModel
{
    private static readonly string AzureRaw = RawValueEnumConverter<TtsProviderKind>.ToRaw(TtsProviderKind.AzureTts);

    private readonly SettingsStore _settings;
    private readonly ISecretStore _secrets;
    private readonly ProviderFactory _providers;
    private readonly Action<string> _log;
    private readonly List<KeyEntryViewModel> _keys = [];

    public ProvidersViewModel(SettingsStore settings, ISecretStore secrets, ProviderFactory providers, Action<string> log)
    {
        _settings = settings;
        _secrets = secrets;
        _providers = providers;
        _log = log;
    }

    public AppSettings Current => _settings.Current;

    /// <summary>The key row of an AI or translation provider: its Save checks the key live, its Verify tests the saved one.</summary>
    public KeyEntryViewModel Key(ProviderKind kind)
    {
        var row = new KeyEntryViewModel(
            SecretIds.Provider(kind), key => SaveProviderKeyAsync(kind, key), () => VerifyProviderKeyAsync(kind), this);
        _keys.Add(row);
        return row;
    }

    /// <summary>The key row of a cloud TTS provider (no Verify, as on macOS).</summary>
    public KeyEntryViewModel TtsKey(TtsProviderKind kind)
    {
        var row = new KeyEntryViewModel(SecretIds.Tts(kind), key => SaveTtsKeyAsync(kind, key), null, this);
        _keys.Add(row);
        return row;
    }

    /// <summary>Reads every row's saved key off the UI thread, keeping only its masked preview.</summary>
    public async Task LoadKeysAsync()
    {
        var ids = _keys.Select(row => row.SecretId).ToArray();
        var previews = await Task.Run(() => ids.Select(id => ProviderFeedback.MaskedPreview(ReadSecret(id))).ToArray());
        for (var i = 0; i < previews.Length; i++)
            _keys[i].SetLoaded(previews[i]);
    }

    /// <summary>Saves one setting; a failed write is logged and false.</summary>
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

    // Settings fields.

    public static string AzureRegion(AppSettings settings) =>
        settings.TtsProviderConfigs.GetValueOrDefault(AzureRaw)?.Region ?? "";

    /// <summary><paramref name="text"/> trimmed as Azure's region; empty removes it (macOS parity).</summary>
    public static AppSettings WithAzureRegion(AppSettings settings, string text)
    {
        var trimmed = text.Trim();
        var config = settings.TtsProviderConfigs.GetValueOrDefault(AzureRaw) ?? new TtsProviderConfig();
        var configs = new Dictionary<string, TtsProviderConfig>(settings.TtsProviderConfigs)
        {
            [AzureRaw] = config with { Region = trimmed.Length == 0 ? null : trimmed },
        };
        return settings with { TtsProviderConfigs = configs };
    }

    public static string CliPath(AppSettings settings, ProviderKind kind) => kind switch
    {
        ProviderKind.ClaudeCli => settings.ClaudeCliPath,
        ProviderKind.CodexCli => settings.CodexCliPath,
        _ => settings.GeminiCliPath,
    };

    public static AppSettings WithCliPath(AppSettings settings, ProviderKind kind, string path) => kind switch
    {
        ProviderKind.ClaudeCli => settings with { ClaudeCliPath = path },
        ProviderKind.CodexCli => settings with { CodexCliPath = path },
        _ => settings with { GeminiCliPath = path },
    };

    // CLIs.

    /// <summary>The installed CLI (its <c>.exe</c> or npm <c>.cmd</c>) on the PATH or in the known folders, or null.</summary>
    public static Task<string?> DetectCliAsync(ProviderKind kind) =>
        Task.Run(() => ShellEnvironment.Shared.Executable(CliName(kind))?.DisplayPath);

    /// <summary>One probe run of the CLI through the app's factory, so it runs in PopGuy's job object.</summary>
    public Task<CliValidationOutcome> VerifyCliAsync(ProviderKind kind, string path, CancellationToken ct) =>
        Task.Run(() => CliProviderValidator.ValidateAsync(kind, path, _providers, ct), ct);

    private static string CliName(ProviderKind kind) => kind switch
    {
        ProviderKind.ClaudeCli => "claude",
        ProviderKind.CodexCli => "codex",
        _ => "gemini",
    };

    // Keys.

    /// <summary>Checks the key live (Custom: against its base URL; without one it is saved unchecked, as on macOS), then stores it.</summary>
    private async Task<string?> SaveProviderKeyAsync(ProviderKind kind, string key)
    {
        var baseUrl = kind == ProviderKind.Custom ? CustomEndpoint() : null;
        try
        {
            await Task.Run(() => ProviderKeyValidator.ValidateAsync(kind, key, baseUrl));
        }
        catch (Exception e)
        {
            return ProviderFeedback.ValidationMessage(e);
        }
        return await StoreAsync(SecretIds.Provider(kind), key);
    }

    private async Task<string?> SaveTtsKeyAsync(TtsProviderKind kind, string key)
    {
        string? region = null;
        if (kind == TtsProviderKind.AzureTts)
        {
            region = AzureRegion(_settings.Current);
            if (region.Length == 0) return ProviderFeedback.MissingRegionMessage;
        }
        try
        {
            await Task.Run(() => TtsKeyValidator.ValidateAsync(kind, key, region));
        }
        catch (Exception e)
        {
            return ProviderFeedback.ValidationMessage(e);
        }
        return await StoreAsync(SecretIds.Tts(kind), key);
    }

    private async Task<VerifyOutcome> VerifyProviderKeyAsync(ProviderKind kind)
    {
        var baseUrl = kind == ProviderKind.Custom ? CustomEndpoint() : null;
        var key = await Task.Run(() => ReadSecret(SecretIds.Provider(kind)));
        var early = ProviderFeedback.MapVerifyOutcome(null, key is not null, kind == ProviderKind.Custom && baseUrl is null);
        if (early != VerifyOutcome.Valid) return early;
        try
        {
            await Task.Run(() => ProviderKeyValidator.ValidateAsync(kind, key!, baseUrl));
            return VerifyOutcome.Valid;
        }
        catch (Exception e)
        {
            return ProviderFeedback.MapVerifyOutcome(e, hasKey: true, customEndpointMissing: false);
        }
    }

    /// <summary>Custom's base URL when it is an absolute http(s) URL, else null (not configured).</summary>
    private Uri? CustomEndpoint() =>
        Uri.TryCreate(_settings.Current.CustomBaseUrl.Trim(), UriKind.Absolute, out var url)
        && (url.Scheme == Uri.UriSchemeHttp || url.Scheme == Uri.UriSchemeHttps)
            ? url
            : null;

    /// <summary>Null when stored; else the message. Failures are logged with the Win32 code only.</summary>
    private async Task<string?> StoreAsync(string id, string key)
    {
        try
        {
            await Task.Run(() => _secrets.Set(id, key));
            return null;
        }
        catch (Win32Exception e)
        {
            _log($"credentials: save failed for {id}, error {e.NativeErrorCode}");
            return "Could not save the key in Windows Credential Manager.";
        }
        catch (ArgumentException)
        {
            return "The API key is too long.";
        }
    }

    /// <summary>Deletes the saved key off the UI thread; false when Credential Manager refused (logged).</summary>
    internal async Task<bool> DeleteAsync(string id)
    {
        try
        {
            await Task.Run(() => _secrets.Delete(id));
            return true;
        }
        catch (Win32Exception e)
        {
            _log($"credentials: delete failed for {id}, error {e.NativeErrorCode}");
            return false;
        }
    }

    /// <summary>The saved key's masked preview, read off the UI thread.</summary>
    internal Task<string?> PreviewAsync(string id) => Task.Run(() => ProviderFeedback.MaskedPreview(ReadSecret(id)));

    /// <summary>Any thread. Null when none is saved or Credential Manager refused (logged, never the key).</summary>
    private string? ReadSecret(string id)
    {
        try
        {
            return _secrets.Get(id);
        }
        catch (Win32Exception e)
        {
            _log($"credentials: read failed for {id}, error {e.NativeErrorCode}");
            return null;
        }
    }
}

/// <summary>
/// One API key row (macOS <c>KeyEntryRow</c>). No key saved: the key field with Save (checks the key live and stores it
/// only when it passes) and Clear (disabled). Key saved: the masked preview with Edit (an empty field and Cancel),
/// Verify (AI and translation only; its feedback clears after 1 s) and Clear. The row never holds the key: the view
/// passes the typed draft to <see cref="SaveAsync"/> and empties its field when it returns true. UI thread only.
/// </summary>
internal sealed class KeyEntryViewModel
{
    private static readonly TimeSpan VerifyFeedbackDuration = TimeSpan.FromSeconds(1);

    private readonly Func<string, Task<string?>> _validateAndStore;
    private readonly Func<Task<VerifyOutcome>>? _verify;
    private readonly ProvidersViewModel _owner;
    private CancellationTokenSource? _dismiss;

    internal KeyEntryViewModel(
        string secretId, Func<string, Task<string?>> validateAndStore, Func<Task<VerifyOutcome>>? verify, ProvidersViewModel owner)
    {
        SecretId = secretId;
        _validateAndStore = validateAndStore;
        _verify = verify;
        _owner = owner;
    }

    /// <summary>Any state change: the view renders again.</summary>
    public event Action? Changed;

    /// <summary>The Credential Manager target (not a secret).</summary>
    public string SecretId { get; }

    public bool CanVerify => _verify is not null;

    /// <summary>False until the saved key was looked up: the row stays hidden until then.</summary>
    public bool IsLoaded { get; private set; }

    /// <summary>The saved key's masked preview; null when none is saved.</summary>
    public string? Preview { get; private set; }

    public bool IsSaved => Preview is not null;

    public bool IsEditing { get; private set; }

    /// <summary>The draft is being checked against the provider.</summary>
    public bool IsValidating { get; private set; }

    /// <summary>The saved key is being verified.</summary>
    public bool IsVerifying { get; private set; }

    /// <summary>Why the last Save failed, shown until the next Save, Edit, Cancel or Clear.</summary>
    public string? ErrorMessage { get; private set; }

    /// <summary>The last Verify result, shown for a moment.</summary>
    public VerifyOutcome? Outcome { get; private set; }

    /// <summary>The key field shows when no key is saved, or after Edit.</summary>
    public bool ShowsField => !IsSaved || IsEditing;

    internal void SetLoaded(string? preview)
    {
        IsLoaded = true;
        Preview = preview;
        Changed?.Invoke();
    }

    /// <summary>Checks and stores <paramref name="draft"/> (trimmed); true when it was saved.</summary>
    public async Task<bool> SaveAsync(string draft)
    {
        if (draft.Length == 0 || IsValidating) return false;
        var key = draft.Trim();
        if (key.Length == 0)
        {
            ErrorMessage = ProviderFeedback.MissingKeyMessage;
            Changed?.Invoke();
            return false;
        }
        IsValidating = true;
        ErrorMessage = null;
        Changed?.Invoke();
        var error = await _validateAndStore(key);
        IsValidating = false;
        if (error is not null)
        {
            ErrorMessage = error;
            Changed?.Invoke();
            return false;
        }
        Preview = ProviderFeedback.MaskedPreview(key);
        IsEditing = false;
        Outcome = null;
        Changed?.Invoke();
        return true;
    }

    public void Edit()
    {
        ErrorMessage = null;
        Outcome = null;
        IsEditing = true;
        Changed?.Invoke();
    }

    /// <summary>Leaves Edit without touching the saved key.</summary>
    public void Cancel()
    {
        if (IsValidating) return;
        ErrorMessage = null;
        IsEditing = false;
        Changed?.Invoke();
    }

    /// <summary>Deletes the saved key; when Credential Manager refuses, the row shows the key that is still there.</summary>
    public async Task ClearAsync()
    {
        if (!IsSaved || IsValidating) return;
        _dismiss?.Cancel();
        Preview = null;
        ErrorMessage = null;
        Outcome = null;
        IsEditing = false;
        Changed?.Invoke();
        if (await _owner.DeleteAsync(SecretId)) return;
        Preview = await _owner.PreviewAsync(SecretId);
        Changed?.Invoke();
    }

    /// <summary>Tests the saved key; the feedback clears after 1 s.</summary>
    public async Task VerifyAsync()
    {
        if (_verify is null || IsVerifying) return;
        _dismiss?.Cancel();
        IsVerifying = true;
        Outcome = null;
        Changed?.Invoke();
        var outcome = await _verify();
        IsVerifying = false;
        Outcome = outcome;
        Changed?.Invoke();

        var dismiss = _dismiss = new CancellationTokenSource();
        try
        {
            await Task.Delay(VerifyFeedbackDuration, dismiss.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        Outcome = null;
        Changed?.Invoke();
    }
}
