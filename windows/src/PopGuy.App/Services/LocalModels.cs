using PopGuy.Core.Actions;
using PopGuy.Core.Settings;
using PopGuy.LocalLLM;
using PopGuy.Onboarding;

namespace PopGuy.Services;

/// <summary>What is on disk for a catalog model.</summary>
internal enum LocalModelFile { Missing, Partial, Installed }

/// <summary>
/// The local models' state for Settings → Providers → Local AI (macOS SettingsStore's installedLocalModels,
/// activeLocalModelDownloadID, localModelDownloadProgress, localModelDownloadError and their functions): which files
/// are on disk, the one download at a time with its progress and Cancel, deletes, the last error, and the default
/// model. Owned by <see cref="AppServices"/>, so a download goes on while the Settings window is closed. Files are read
/// and written off the UI thread; everything else, <see cref="Changed"/> included, is on the UI thread.
/// </summary>
internal sealed class LocalModels
{
    private readonly SettingsStore _settings;
    private readonly Action<string> _log;
    private readonly HashSet<string> _deleting = [];
    private Dictionary<string, LocalModelFile> _files = [];
    private CancellationTokenSource? _download;
    private int _refreshes;

    public LocalModels(ModelDownloader downloader, LlamaProvider provider, SettingsStore settings, Action<string> log)
    {
        Downloader = downloader;
        Provider = provider;
        _settings = settings;
        _log = log;
    }

    public ModelDownloader Downloader { get; }

    public LlamaProvider Provider { get; }

    /// <summary>The state changed (files, a download's progress, an error, a delete). UI thread.</summary>
    public event Action? Changed;

    /// <summary>The files were looked up once: the rows show their controls from then on.</summary>
    public bool IsLoaded { get; private set; }

    /// <summary>The model being downloaded, or null.</summary>
    public string? ActiveDownloadId { get; private set; }

    /// <summary>The active download's fraction, null until the first bytes arrive.</summary>
    public double? DownloadFraction { get; private set; }

    /// <summary>The last download or delete failure, cleared by the next one.</summary>
    public string? Error { get; private set; }

    /// <summary>
    /// The wizard's Local AI download (macOS pendingOnboardingLocalMapID): once that model is on disk, Improve, Shorten,
    /// Proofread and Prompt run it, even when the wizard closed meanwhile. In memory only; a cancel, a failure, another
    /// download or the wizard's cloud choice clears it.
    /// </summary>
    public string? PendingOnboardingMapId { get; set; }

    /// <summary>The model an action without a local model id runs: the one set here, else the catalog's.</summary>
    public string DefaultId => GgufCatalog.Find(_settings.Current.DefaultLocalModelId)?.Id ?? GgufCatalog.Default.Id;

    public LocalModelFile FileState(GgufModel entry) => _files.GetValueOrDefault(entry.Id);

    public bool IsDeleting(GgufModel entry) => _deleting.Contains(entry.Id);

    /// <summary>Looks up every catalog file off the UI thread; the latest lookup wins.</summary>
    public async Task RefreshAsync()
    {
        var refresh = ++_refreshes;
        var files = await Task.Run(() => GgufCatalog.All.ToDictionary(
            m => m.Id,
            m => Downloader.IsDownloaded(m) ? LocalModelFile.Installed
                : Downloader.HasPartial(m) ? LocalModelFile.Partial
                : LocalModelFile.Missing));
        if (refresh != _refreshes) return;
        _files = files;
        IsLoaded = true;
        Changed?.Invoke();
    }

    /// <summary>
    /// Makes <paramref name="entry"/> the default; the catalog's default is stored as none. A failed write is logged and
    /// shown.
    /// </summary>
    public void SetDefault(GgufModel entry)
    {
        try
        {
            _settings.Update(s => s with { DefaultLocalModelId = entry.IsDefault ? null : entry.Id });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _log($"settings: defaultLocalModelID not saved, {e.GetType().Name}");
            Error = "The default model could not be saved.";
        }
        Changed?.Invoke();
    }

    /// <summary>
    /// Downloads <paramref name="entry"/>, resuming its partial file; nothing while another download runs. Never
    /// throws: a failure shows as <see cref="Error"/>, a cancel as nothing. UI thread (the progress is posted back to
    /// it).
    /// </summary>
    public async Task DownloadAsync(GgufModel entry)
    {
        if (ActiveDownloadId is not null || _deleting.Contains(entry.Id)) return;
        if (PendingOnboardingMapId != entry.Id) PendingOnboardingMapId = null;
        var run = _download = new CancellationTokenSource();
        ActiveDownloadId = entry.Id;
        DownloadFraction = null;
        Error = null;
        Changed?.Invoke();
        // Created here, so each report runs on the UI thread; a row redraws once per percent.
        var progress = new Progress<ModelDownloadProgress>(p =>
        {
            if (_download != run || p.CompletedBytes == 0) return;
            var fraction = Math.Floor(p.Fraction * 100) / 100;
            if (fraction == DownloadFraction) return;
            DownloadFraction = fraction;
            Changed?.Invoke();
        });
        try
        {
            // A new download replaces the file, which the provider may have mapped.
            if (FileState(entry) == LocalModelFile.Installed) await Provider.UnloadAsync(run.Token);
            await Task.Run(() => Downloader.DownloadAsync(entry, progress, run.Token), run.Token);
            _log($"local model: {entry.Id} downloaded");
            if (PendingOnboardingMapId == entry.Id)
                OnboardingActions.Save(_settings, _log, s => OnboardingActions.WithAiActionsOn(s, ProviderKind.MlxLocal, entry.Id));
        }
        catch (OperationCanceledException) when (run.IsCancellationRequested)
        {
            _log($"local model: {entry.Id} download cancelled");
        }
        catch (Exception e) when (e is ModelDownloadException or HttpRequestException or IOException
            or UnauthorizedAccessException or OperationCanceledException)
        {
            _log($"local model: {entry.Id} download failed, {e.GetType().Name} {(e as ModelDownloadException)?.Kind}");
            Error = DownloadErrorText(entry, e);
        }
        finally
        {
            if (PendingOnboardingMapId == entry.Id) PendingOnboardingMapId = null;
            _download = null;
            run.Dispose();
            ActiveDownloadId = null;
            DownloadFraction = null;
        }
        await RefreshAsync();
    }

    /// <summary>Stops the active download; its partial file stays for Resume.</summary>
    public void CancelDownload() => _download?.Cancel();

    /// <summary>
    /// Unloads the provider (a mapped model file cannot be deleted on Windows; this waits for a running action), then
    /// deletes the file and any partial download. Never throws: a failure shows as <see cref="Error"/>. UI thread.
    /// </summary>
    public async Task DeleteAsync(GgufModel entry)
    {
        if (ActiveDownloadId == entry.Id || !_deleting.Add(entry.Id)) return;
        Error = null;
        Changed?.Invoke();
        try
        {
            await Provider.UnloadAsync();
            await Task.Run(() => Downloader.DeleteAsync(entry));
            _log($"local model: {entry.Id} deleted");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ModelDownloadException)
        {
            _log($"local model: {entry.Id} not deleted, {e.GetType().Name}");
            Error = $"Could not delete {entry.DisplayName}. Check disk permissions and try again.";
        }
        finally
        {
            _deleting.Remove(entry.Id);
        }
        await RefreshAsync();
    }

    /// <summary>A failed download in words; never the server's text or a path.</summary>
    private static string DownloadErrorText(GgufModel entry, Exception e) => e switch
    {
        ModelDownloadException { Kind: ModelDownloadError.UnknownModel or ModelDownloadError.UnsafePath } =>
            $"{entry.DisplayName} can't be downloaded.",
        ModelDownloadException { Kind: ModelDownloadError.HttpStatus } =>
            $"The server refused the download of {entry.DisplayName}. Try again later.",
        ModelDownloadException { Kind: ModelDownloadError.InsecureRedirect } =>
            $"The download of {entry.DisplayName} was stopped: the server sent it to an insecure address.",
        ModelDownloadException { Kind: ModelDownloadError.SizeMismatch or ModelDownloadError.ChecksumMismatch } =>
            $"The download of {entry.DisplayName} didn't match the expected file and was discarded. Try again.",
        ModelDownloadException { Kind: ModelDownloadError.Incomplete } =>
            $"The download of {entry.DisplayName} stopped early. Click Resume to continue.",
        // HttpIOException is an IOException: the connection dropped while reading the file.
        HttpRequestException or HttpIOException or OperationCanceledException
            or IOException { InnerException: System.Net.Sockets.SocketException } =>
            "Download failed. Check your internet connection and try again.",
        _ => $"{entry.DisplayName} could not be saved. Check the free disk space and try again.",
    };
}
