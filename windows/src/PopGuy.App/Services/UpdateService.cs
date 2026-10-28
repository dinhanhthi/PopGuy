using Microsoft.UI.Dispatching;
using PopGuy.Core.Settings;
using PopGuy.Core.Updates;
using Velopack;
using Velopack.Sources;

namespace PopGuy.Services;

/// <summary>Where an update check stands.</summary>
internal enum UpdateState { Idle, Checking, Downloading, Ready, UpToDate, Failed }

/// <summary>
/// Updates through Velopack (spec-3 §7, macOS Sparkle): the GitHub releases of PopGuy, the <c>windows-v…</c> ones only
/// (<see cref="WindowsReleasesSource"/>). Only an installed copy (Setup.exe) can update; a build run from a folder
/// shows Check for Updates disabled. With <see cref="AppSettings.AutomaticallyChecksForUpdates"/> on, it checks 10 s
/// after launch and once a day; a found update downloads in the background, then waits (Sparkle's gentle reminder): the
/// Settings banner, the About card and the tray offer "Update now", which restarts PopGuy into it. Builds made with
/// <c>UPDATE_URL_OVERRIDE</c> (the <c>-dev</c> tags, for QA) read the feed from <c>POPGUY_UPDATE_URL</c> instead.
/// Velopack's work runs on the thread pool; the state and <see cref="Changed"/> are on the UI thread.
/// </summary>
internal sealed class UpdateService : IDisposable
{
    private const string RepoUrl = "https://github.com/dinhanhthi/PopGuy";
    private static readonly TimeSpan FirstCheckDelay = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan CheckInterval = TimeSpan.FromDays(1);

    private readonly SettingsStore _settings;
    private readonly DispatcherQueue _dispatcher;
    private readonly Action<string> _log;
    private readonly UpdateManager? _manager;
    private readonly DispatcherQueueTimer _timer;
    private VelopackAsset? _pending;
    private bool _disposed;

    public UpdateService(SettingsStore settings, DispatcherQueue dispatcher, Action<string> log)
    {
        _settings = settings;
        _dispatcher = dispatcher;
        _log = log;
        try
        {
            var manager = new UpdateManager(Source());
            if (manager.IsInstalled) _manager = manager;
        }
        catch (Exception e)
        {
            // A broken install or an unreadable feed URL: no updates, never a failed launch.
            _log($"updates: not available, {e.GetType().Name}");
        }
        _timer = dispatcher.CreateTimer();
        _timer.IsRepeating = false;
        _timer.Tick += (t, _) =>
        {
            t.Stop();
            _ = CheckAsync(userInitiated: false);
        };
        _settings.Changed += OnSettingsChanged;
    }

    /// <summary>The state, the pending version or the last result changed. UI thread.</summary>
    public event Action? Changed;

    /// <summary>Update now: PopGuy is to quit, so the updater can replace it (it restarts PopGuy). UI thread.</summary>
    public event Action? ExitRequested;

    /// <summary>An installed copy (Setup.exe), which can check and update.</summary>
    public bool IsInstalled => _manager is not null;

    public UpdateState State { get; private set; }

    /// <summary>The downloaded version, sanitized for display; null until one is ready.</summary>
    public string? PendingVersion { get; private set; }

    /// <summary>
    /// Whether Check for Updates may start a check now (installed, no check or download running, no update waiting:
    /// then Update now is the offer).
    /// </summary>
    public bool CanCheck =>
        IsInstalled && State is not (UpdateState.Checking or UpdateState.Downloading or UpdateState.Ready);

    /// <summary>The About card's line for the current state, or null when there is nothing to say yet.</summary>
    public string? StatusText => State switch
    {
        _ when !IsInstalled => "Updates come with the installed version of PopGuy.",
        UpdateState.Checking => "Checking for updates…",
        UpdateState.Downloading => "Downloading the update…",
        UpdateState.Ready => $"Update available — v{PendingVersion}",
        UpdateState.UpToDate => "You're on the latest version.",
        UpdateState.Failed => "Could not check for updates. Check your internet connection and try again.",
        _ => null,
    };

    /// <summary>Starts the automatic checks when they are on. UI thread.</summary>
    public void Start() => Schedule(FirstCheckDelay);

    /// <summary>Check for Updates (footer, About, tray): a check now, whatever the automatic setting. UI thread.</summary>
    public void CheckNow()
    {
        if (CanCheck) _ = CheckAsync(userInitiated: true);
    }

    /// <summary>
    /// Update now: hands the ready update to Velopack's updater, which waits for PopGuy to quit, applies it and starts
    /// PopGuy again; <see cref="ExitRequested"/> then shuts PopGuy down (history saved, hooks removed). UI thread.
    /// </summary>
    public void ApplyAndRestart()
    {
        if (_manager is null || _pending is null || State != UpdateState.Ready) return;
        try
        {
            _manager.WaitExitThenApplyUpdates(_pending, silent: false, restart: true);
            _log($"updates: applying {PendingVersion} after exit");
            ExitRequested?.Invoke();
        }
        catch (Exception e)
        {
            _log($"updates: not applied, {e.GetType().Name}");
            SetState(UpdateState.Failed);
        }
    }

    public void Dispose()
    {
        _disposed = true;
        _timer.Stop();
        _settings.Changed -= OnSettingsChanged;
    }

    /// <summary>
    /// Checks the feed, then downloads a newer version. A failure is logged with its type only (never a URL) and shown
    /// as <see cref="UpdateState.Failed"/>; an automatic check that fails says nothing until the user looks.
    /// </summary>
    private async Task CheckAsync(bool userInitiated)
    {
        if (_manager is not { } manager || !CanCheck) return;
        SetState(UpdateState.Checking);
        try
        {
            var update = await Task.Run(manager.CheckForUpdatesAsync);
            if (_disposed) return;
            if (update is null)
            {
                _log("updates: up to date");
                SetState(UpdateState.UpToDate);
                return;
            }
            SetState(UpdateState.Downloading);
            await Task.Run(() => manager.DownloadUpdatesAsync(update));
            if (_disposed) return;
            _pending = update.TargetFullRelease;
            PendingVersion = SanitizedVersion(_pending.Version.ToString());
            _log($"updates: {PendingVersion} ready");
            SetState(PendingVersion is null ? UpdateState.Failed : UpdateState.Ready);
        }
        catch (Exception e)
        {
            _log($"updates: check failed{(userInitiated ? "" : " (automatic)")}, {e.GetType().Name}");
            if (!_disposed) SetState(UpdateState.Failed);
        }
        finally
        {
            if (!_disposed && State != UpdateState.Ready) Schedule(CheckInterval);
        }
    }

    private void SetState(UpdateState state)
    {
        State = state;
        Changed?.Invoke();
    }

    /// <summary>The next automatic check after <paramref name="delay"/>, while they are on and nothing is ready.</summary>
    private void Schedule(TimeSpan delay)
    {
        _timer.Stop();
        if (!IsInstalled || !_settings.Current.AutomaticallyChecksForUpdates || State == UpdateState.Ready) return;
        _timer.Interval = delay;
        _timer.Start();
    }

    /// <summary>Queued: a change may be saved from any thread. Turning the automatic checks on schedules the next one.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => _dispatcher.TryEnqueue(() =>
    {
        if (_disposed) return;
        if (!_settings.Current.AutomaticallyChecksForUpdates) _timer.Stop();
        else if (!_timer.IsRunning && CanCheck) Schedule(FirstCheckDelay);
    });

    /// <summary>
    /// The feed: PopGuy's GitHub releases, or in an <c>UPDATE_URL_OVERRIDE</c> build the <c>POPGUY_UPDATE_URL</c> folder
    /// when it is set (QA's local feed).
    /// </summary>
    private static IUpdateSource Source()
    {
#if UPDATE_URL_OVERRIDE
        if (Environment.GetEnvironmentVariable("POPGUY_UPDATE_URL") is { Length: > 0 } url) return new SimpleWebSource(url);
#endif
        return new WindowsReleasesSource(RepoUrl);
    }

    /// <summary>
    /// macOS pendingVersion: only ASCII letters, digits, '.', '-', '+' and spaces, trimmed, at most 32 characters; empty
    /// is null. The version comes from the feed, so nothing else reaches the UI.
    /// </summary>
    internal static string? SanitizedVersion(string raw)
    {
        var kept = new string(raw.Where(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '+' or ' ').ToArray()).Trim();
        if (kept.Length > 32) kept = kept[..32].Trim();
        return kept.Length == 0 ? null : kept;
    }
}

/// <summary>
/// Velopack's GitHub source over the Windows releases only (<see cref="ReleaseSelector"/>): Velopack's own reads the 10
/// newest releases, which the macOS releases of the shared repository can fill. Anonymous (the public API), so assets
/// come by their browser download URLs, as in Velopack.
/// </summary>
internal sealed class WindowsReleasesSource(string repoUrl) : GithubSource(repoUrl, accessToken: null, prerelease: false)
{
    protected override async Task<GithubRelease[]> GetReleases(bool includePrereleases)
    {
        var url = new Uri(GetApiBaseUrl(RepoUri), $"repos{RepoUri.AbsolutePath}/releases?per_page={ReleaseSelector.PageSize}");
        var json = await Downloader.DownloadString(url.ToString(), GetRequestHeaders("application/vnd.github.v3+json"))
            .ConfigureAwait(false);
        return [.. ReleaseSelector.WindowsReleases(ReleaseSelector.Parse(json), includePrereleases).Select(r => new GithubRelease
        {
            Name = r.Name ?? r.TagName,
            Prerelease = r.Prerelease,
            PublishedAt = r.PublishedAt?.UtcDateTime,
            Assets = [.. (r.Assets ?? []).Select(a => new GithubReleaseAsset
            {
                Name = a.Name,
                Url = a.Url,
                BrowserDownloadUrl = a.BrowserDownloadUrl,
                ContentType = a.ContentType,
            })],
        })];
    }
}
