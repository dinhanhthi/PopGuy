using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Dispatching;
using PopGuy.Core;
using PopGuy.Core.Actions;
using PopGuy.Core.History;
using PopGuy.Core.Providers;
using PopGuy.Core.Secrets;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using PopGuy.Platform.SystemServices;
using PopGuy.Toolbar;

namespace PopGuy.Services;

/// <summary>
/// The composition root: every long-lived service, built once on the UI thread at launch and disposed at exit. API
/// keys come from Credential Manager (<see cref="CredentialStore"/>) by <see cref="SecretIds.Provider"/>; settings and
/// history live under <see cref="AppPaths"/>.
/// </summary>
internal sealed class AppServices : IDisposable
{
    private static readonly TimeSpan HistoryFlushTimeout = TimeSpan.FromSeconds(2);

    private readonly GlobalInput _input;
    private readonly ClipboardHistoryCache _clipboardCache;
    private readonly HotkeyService _hotkeys;
    private readonly ToolbarWindow _toolbar;
    private readonly ToolbarController _controller;
    private int _disposed;

    private AppServices(AppLog log, AppPaths paths, DispatcherQueue dispatcher)
    {
        Log = log;
        Settings = new SettingsStore(paths);
        History = new HistoryStore(paths);
        Credentials = new CredentialStore();
        var providers = new ProviderFactory();
        var engine = new ActionEngine(providers, ApiKey);
        var session = new ToolbarSession(engine, History, () => Settings.Current);

        _input = new GlobalInput(log.Write);
        try
        {
            _clipboardCache = new ClipboardHistoryCache(log.Write);
            var chord = new ChordMonitor(_input, _clipboardCache, log.Write);
            _hotkeys = new HotkeyService(_input, log.Write);
            _toolbar = new ToolbarWindow(session);
            _controller = new ToolbarController(Settings, session, _toolbar, _input, chord, _hotkeys, dispatcher, log.Write);
        }
        catch
        {
            _toolbar?.Close();
            _hotkeys?.Dispose();
            _clipboardCache?.Dispose();
            _input.Dispose();
            throw;
        }
    }

    public AppLog Log { get; }

    public SettingsStore Settings { get; }

    public HistoryStore History { get; }

    public CredentialStore Credentials { get; }

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
            return services;
        }
        catch (Exception e)
        {
            log.Write($"start failed, {e.GetType().Name} {e.Message}");
            log.Dispose();
            throw;
        }
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

    /// <summary>Stops the triggers first, then the input they read, then the toolbar; flushes history last. UI thread.</summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _controller.Dispose();
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
