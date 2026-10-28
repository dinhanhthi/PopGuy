using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Dispatching;
using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.Dictionaries;
using PopGuy.Core.History;
using PopGuy.Core.Providers;
using PopGuy.Core.Providers.Cli;
using PopGuy.Core.Scripts;
using PopGuy.Core.Secrets;
using PopGuy.Core.Settings;
using PopGuy.Core.Speak;
using PopGuy.Core.Speak.CloudTts;
using PopGuy.Core.Toolbar;
using PopGuy.LocalLLM;
using PopGuy.Ocr;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using PopGuy.Platform.Speech;
using PopGuy.Platform.SystemServices;
using PopGuy.Toolbar;

namespace PopGuy.Services;

/// <summary>
/// The composition root: every long-lived service, built once on the UI thread at launch and disposed at exit. API
/// keys come from Credential Manager (<see cref="CredentialStore"/>) by <see cref="SecretIds.Provider"/> and
/// <see cref="SecretIds.Tts"/>; settings and history live under <see cref="AppPaths"/>.
/// </summary>
internal sealed class AppServices : IDisposable
{
    private static readonly TimeSpan HistoryFlushTimeout = TimeSpan.FromSeconds(2);

    private readonly GlobalInput _input;
    private readonly ClipboardHistoryCache _clipboardCache;
    private readonly HotkeyService _hotkeys;
    private readonly SelectionPipeline _pipeline;
    private readonly ToolbarWindow _toolbar;
    private readonly OcrCaptureController _ocr;
    private readonly ToolbarController _controller;
    private readonly SpeakCoordinator _speak;
    private readonly SystemTts _systemTts = new();
    private readonly Dictionary<TtsProviderKind, ITtsProvider> _ttsProviders;
    private SpeakCoordinator? _speakPreview;
    private int _disposed;

    private AppServices(AppLog log, AppPaths paths, DispatcherQueue dispatcher)
    {
        Log = log;
        Paths = paths;
        Settings = new SettingsStore(paths);
        History = new HistoryStore(paths);
        Credentials = new CredentialStore();
        // A lambda, not the method group: Shared is created on the first CLI run, so a refused job object fails that
        // run only, never the launch.
        Providers = new ProviderFactory(cli: new CliRunner(onStarted: process => ChildProcessJob.Shared.Assign(process)));
        // One downloader and one provider (one model in memory) for every run and Settings. The token stops a download,
        // never a timeout: models are GBs.
        var downloader = new ModelDownloader(
            ModelDownloader.DefaultFolder(paths), new HttpClient { Timeout = Timeout.InfiniteTimeSpan });
        var local = new LlamaProvider(model => downloader.ResolvePath(model, Settings.Current.DefaultLocalModelId));
        Providers.Register(ProviderKind.MlxLocal, _ => local);
        LocalModels = new LocalModels(downloader, local, Settings, log.Write);
        Updates = new UpdateService(Settings, dispatcher, log.Write);
        var engine = new ActionEngine(Providers, ApiKey);
        // Script shells go in their own job, which what a script opens leaves (it outlives PopGuy, as on macOS).
        var scripts = new ScriptActionEngine(onStarted: process => ChildProcessJob.Scripts.Assign(process));
        // Babylon takes part in a lookup only while one of the settings' .bgl files is enabled (read at each lookup).
        var dictionary = new DictionaryEngine(DictionaryEngine.DefaultProviders(() => Settings.Current.BabylonDictionaries));
        var session = new ToolbarSession(engine, History, () => Settings.Current, scripts: scripts, dictionary: dictionary);
        // One cloud adapter per kind, created once; the coordinator reads each key when a request needs it (off the UI
        // thread: it routes on the thread pool), never caching it.
        _ttsProviders = new Dictionary<TtsProviderKind, ITtsProvider>
        {
            [TtsProviderKind.OpenAiTts] = new OpenAITtsProvider(),
            [TtsProviderKind.GoogleCloudTts] = new GoogleCloudTtsProvider(),
            [TtsProviderKind.AzureTts] = new AzureTtsProvider(),
        };
        IAudioPlayback playback = new AudioPlayback();
#if DEBUG
        playback = new PopGuy.Debug.SpeakProbe(playback, () => Settings.Current.SpeakSettings.SelectedEngine);
#endif
        _speak = new SpeakCoordinator(_systemTts, playback, kind => _ttsProviders.GetValueOrDefault(kind), TtsKey);
#if DEBUG
        ((PopGuy.Debug.SpeakProbe)playback).Watch(_speak);
#endif

        _input = new GlobalInput(log.Write);
        try
        {
            _clipboardCache = new ClipboardHistoryCache(log.Write);
            var chord = new ChordMonitor(_input, _clipboardCache, log.Write);
            _hotkeys = new HotkeyService(_input, log.Write);
            _pipeline = new SelectionPipeline(_input, log.Write);
            _toolbar = new ToolbarWindow(session);
            // Its overlays are made per capture; the controller wires its text to the toolbar.
            _ocr = new OcrCaptureController(log.Write);
            _controller = new ToolbarController(
                Settings, session, _speak, _toolbar, _ocr, _input, chord, _hotkeys, _pipeline, dispatcher, log.Write);
        }
        catch
        {
            _toolbar?.Close();
            _pipeline?.Dispose();
            _hotkeys?.Dispose();
            _clipboardCache?.Dispose();
            _input.Dispose();
            throw;
        }
    }

    public AppLog Log { get; }

    public AppPaths Paths { get; }

    public SettingsStore Settings { get; }

    public HistoryStore History { get; }

    public CredentialStore Credentials { get; }

    /// <summary>The provider adapters, for the Settings Verify checks too (its CLI runner puts every CLI in the job object).</summary>
    public ProviderFactory Providers { get; }

    /// <summary>The local models' files, download and default, for Settings → Providers → Local AI. UI thread.</summary>
    public LocalModels LocalModels { get; }

    /// <summary>Velopack updates: the checks, the ready update and Update now. UI thread.</summary>
    public UpdateService Updates { get; }

    /// <summary>The toolbar's Settings button (see <see cref="ToolbarController.SettingsRequested"/>). UI thread.</summary>
    public event Action? SettingsRequested
    {
        add => _controller.SettingsRequested += value;
        remove => _controller.SettingsRequested -= value;
    }

    /// <summary>Settings → General's Setup Guide… (see <see cref="RequestSetupGuide"/>). UI thread.</summary>
    public event Action? SetupGuideRequested;

    /// <summary>Opens the wizard again (the App shows it). UI thread.</summary>
    public void RequestSetupGuide() => SetupGuideRequested?.Invoke();

    /// <summary>A settings apply finished (see <see cref="ToolbarController.HotkeysApplied"/>). Thread pool.</summary>
    public event Action? HotkeysApplied
    {
        add => _controller.HotkeysApplied += value;
        remove => _controller.HotkeysApplied -= value;
    }

    /// <summary>
    /// Settings' voice previews (macOS: the Speak card's own coordinator), apart from the toolbar's Speak so a preview
    /// never shows on the toolbar: the same system voice, cloud adapters and keys, its own player. Created on first use.
    /// UI thread.
    /// </summary>
    public SpeakCoordinator SpeakPreview => _speakPreview ??= CreateSpeakPreview();

    /// <summary>The installed system voices. Any thread (Settings reads them off the UI thread).</summary>
    public IReadOnlyList<SystemVoice> SystemVoices() => _systemTts.Voices();

    /// <summary>Every hotkey of the last apply with its status (empty while suspended). Any thread.</summary>
    public IReadOnlyList<HotkeyRegistration> HotkeyRegistrations => _hotkeys.Registrations;

    /// <summary>Settings' shortcut recorder listens (see <see cref="ToolbarController.SetHotkeysSuspended"/>). Any thread.</summary>
    public void SetHotkeysSuspended(bool suspended) => _controller.SetHotkeysSuspended(suspended);

    /// <summary>The tray's Capture Screen Text… (see <see cref="ToolbarController.BeginOcrCapture"/>). UI thread.</summary>
    public void CaptureScreenText() => _controller.BeginOcrCapture();

    /// <summary>
    /// Builds every service and starts the triggers. UI thread (the toolbar window is created here). Throws when Windows
    /// refuses the hooks or the clipboard listener (<see cref="Win32Exception"/>); the log then has the reason.
    /// </summary>
    public static AppServices Start(DispatcherQueue dispatcher)
    {
        var paths = AppPaths.Resolve();
        var log = AppLog.Open(paths);
        log.Write($"start, version {App.Version}");
        try
        {
            var services = new AppServices(log, paths, dispatcher);
            services._controller.Start();
            services.PrepareBabylonIndexes();
            services.Updates.Start();
            return services;
        }
        catch (Exception e)
        {
            log.Write($"start failed, {e.GetType().Name} {e.Message}");
            log.Dispose();
            throw;
        }
    }

#if DEBUG
    /// <summary>DEBUG only (<c>--selftest-toolbar</c>): see <see cref="ToolbarController.ShowCanned"/>. UI thread.</summary>
    public void ShowCannedToolbar(string text, ForegroundApp source) => _controller.ShowCanned(text, source);
#endif

    /// <summary>
    /// Builds each Babylon file's missing or stale index in the background (macOS: at launch), so the first Look up
    /// after a .bgl file changed does not build it inline. A failure is left to the lookup (logged, never the path).
    /// </summary>
    private void PrepareBabylonIndexes()
    {
        var dictionaries = Settings.Current.BabylonDictionaries;
        if (dictionaries.Count == 0) return;
        _ = Task.Run(async () =>
        {
            foreach (var dictionary in dictionaries)
            {
                // Removed in Settings meanwhile: its index was deleted and must not come back.
                if (!Settings.Current.BabylonDictionaries.Any(d => d.Id == dictionary.Id)) continue;
                try
                {
                    await BabylonIndexCache.Shared.PrepareAsync(dictionary, CancellationToken.None);
                }
                catch (Exception e)
                {
                    Log.Write($"babylon: index not prepared at launch, {e.GetType().Name}");
                }
            }
        });
    }

    private SpeakCoordinator CreateSpeakPreview()
    {
        IAudioPlayback playback = new AudioPlayback();
#if DEBUG
        playback = new PopGuy.Debug.SpeakProbe(playback, () => Settings.Current.SpeakSettings.SelectedEngine);
#endif
        var preview = new SpeakCoordinator(_systemTts, playback, kind => _ttsProviders.GetValueOrDefault(kind), TtsKey);
#if DEBUG
        ((PopGuy.Debug.SpeakProbe)playback).Watch(preview);
#endif
        return preview;
    }

    /// <summary>The stored key of <paramref name="kind"/>, or null (none saved, or Credential Manager refused: logged, never the key).</summary>
    private string? ApiKey(ProviderKind kind)
    {
        try
        {
            return Credentials.Get(SecretIds.Provider(kind));
        }
        catch (Win32Exception e)
        {
            Log.Write($"credentials: read failed for {kind}, error {e.NativeErrorCode}");
            return null;
        }
    }

    /// <summary>The stored cloud speech key of <paramref name="kind"/>, or null (as <see cref="ApiKey"/>). Thread pool.</summary>
    private string? TtsKey(TtsProviderKind kind)
    {
        try
        {
            return Credentials.Get(SecretIds.Tts(kind));
        }
        catch (Win32Exception e)
        {
            Log.Write($"credentials: read failed for {kind}, error {e.NativeErrorCode}");
            return null;
        }
    }

    /// <summary>
    /// Stops speech, then the triggers, then the input they read, then the toolbar; flushes history last. UI thread.
    /// </summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        Updates.Dispose();
        _speak.Stop();
        _speakPreview?.Stop();
        _controller.Dispose();
        _pipeline.Dispose();
        _hotkeys.Dispose();
        _clipboardCache.Dispose();
        _input.Dispose();
        _toolbar.Close();
        if (!History.FlushAsync().Wait(HistoryFlushTimeout)) Log.Write("history: the last save did not finish");
        Log.Write("exit");
        Log.Dispose();
    }
}

/// <summary>
/// A minimal diagnostics log, <c>popguy.log</c> under <see cref="AppPaths.CacheDirectory"/>: one time-stamped line per
/// event. Never write selected text, clipboard contents, results or keys to it, only lengths and reasons. At start, a
/// log over 1 MB moves to <c>popguy.old.log</c> (replacing the older one). Any thread; never throws.
/// </summary>
internal sealed class AppLog : IDisposable
{
    private const long MaxBytes = 1024 * 1024;

    private readonly Lock _gate = new();
    private StreamWriter? _writer;

    private AppLog(StreamWriter? writer) => _writer = writer;

    public static AppLog Open(AppPaths paths)
    {
        try
        {
            Directory.CreateDirectory(paths.CacheDirectory);
            var path = Path.Combine(paths.CacheDirectory, "popguy.log");
            var file = new FileInfo(path);
            if (file.Exists && file.Length > MaxBytes) file.MoveTo(Path.Combine(paths.CacheDirectory, "popguy.old.log"), overwrite: true);
            return new AppLog(new StreamWriter(path, append: true) { AutoFlush = true });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Debug.WriteLine($"PopGuy log not opened: {e.Message}");
            return new AppLog(null);
        }
    }

    public void Write(string message)
    {
        var line = $"{DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz", CultureInfo.InvariantCulture)} {message}";
        lock (_gate)
        {
            try
            {
                _writer?.WriteLine(line);
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException)
            {
                System.Diagnostics.Debug.WriteLine($"PopGuy log write failed: {e.Message}");
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _writer?.Dispose();
            _writer = null;
        }
    }
}
