using System.Reflection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PopGuy.Onboarding;
using PopGuy.Services;
using PopGuy.Settings;
#if DEBUG
using System.Runtime.InteropServices;
using System.Text.Json;
#endif

namespace PopGuy;

public partial class App : Application
{
    /// <summary>Settings and history root, the real %APPDATA%\PopGuy (unpackaged: no file system virtualization).</summary>
    internal static string DataRoot { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PopGuy");

    /// <summary>The assembly informational version (the csproj Version, or CI's 0.0.run number, plus any +commit suffix).</summary>
    internal static string Version { get; } =
        typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";

    /// <summary>The app icon, copied next to PopGuy.exe: the tray icon and the windows' title bar icon.</summary>
    internal static string IconPath { get; } = Path.Combine(AppContext.BaseDirectory, "Assets", "PopGuy.ico");

    private SettingsWindow? _settingsWindow;
    private OnboardingWindow? _onboardingWindow;
    private AppServices? _services;
    private TrayIcon? _tray;
    private DispatcherQueue? _dispatcher;
    private bool _shutDown;

    public App()
    {
        InitializeComponent();
        // A tray app: closing Settings (the last window) must not end it; only Exit does (Quit PopGuy).
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
#if DEBUG
        WriteLaunchProbe();
        // DEBUG harnesses (--spike, --probe-uia, --import-key, --seed-settings): no tray icon, exit when done.
        if (PopGuy.Debug.Probes.TryStart(Exit)) return;
        // --selftest-toolbar: Paste back goes to the app that was in front at launch.
        var selfTestSource = PopGuy.Debug.Probes.SelfTestToolbarRequested
            ? PopGuy.Platform.SystemServices.ForegroundApp.Snapshot()
            : null;
#endif
        // PopGuy starts in the tray only: no window until Settings opens, except the wizard on a first launch.
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        try
        {
            _services = AppServices.Start(_dispatcher);
            UnhandledException += OnUnhandledException;
            _services.SettingsRequested += ShowSettings;
            _services.SetupGuideRequested += ShowOnboarding;
            _services.Updates.ExitRequested += Shutdown;
#if DEBUG
            if (selfTestSource is not null) _services.ShowCannedToolbar(PopGuy.Debug.Probes.SelfTestText, selfTestSource);
#endif
        }
        catch (Exception e)
        {
            // Logged by AppServices. Without the triggers, and with no tray icon or window to quit from, PopGuy exits
            // rather than linger unseen (a later launch would only be redirected to it).
            System.Diagnostics.Debug.WriteLine($"PopGuy services did not start: {e.GetType().Name}");
            _dispatcher.TryEnqueue(Exit);
            return;
        }

        try
        {
            _tray = new TrayIcon(
                _services.Settings, _services.Updates, _dispatcher, ShowSettings, ShowSettingsSection, CaptureScreenText,
                ShowOnboarding, Shutdown, _services.Log.Write);
            _tray.SessionEnding += OnSessionEnding;
        }
        catch (System.ComponentModel.Win32Exception e)
        {
            // Without the icon, Settings is the only way to see PopGuy and to quit it: it opens now, and closing it quits.
            _services.Log.Write($"tray: not created, error {e.NativeErrorCode}");
            ShowSettings();
        }

        if (!_services.Settings.Current.HasOnboarded) ShowOnboarding();
    }

    /// <summary>A later launch redirected here (any thread, see Program): Settings comes to the front.</summary>
    internal void OnRelaunched()
    {
        // Window members are UI thread only; the dispatcher queue may be used from any thread.
        _dispatcher?.TryEnqueue(ShowSettings);
    }

    /// <summary>
    /// The tray icon, its Settings… item, a later launch and the toolbar's Settings button: the one Settings window comes
    /// to the front, made first when none is open. UI thread.
    /// </summary>
    private void ShowSettings()
    {
        if (_shutDown || _services is null) return;
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow(_services);
            _settingsWindow.Closed += OnSettingsClosed;
        }
        _settingsWindow.Show();
    }

    /// <summary>
    /// The first-launch wizard, and Setup Guide… (tray, Settings → General): the one wizard comes to the front, made first
    /// when none is open. UI thread.
    /// </summary>
    private void ShowOnboarding()
    {
        if (_shutDown || _services is null) return;
        if (_onboardingWindow is null)
        {
            _onboardingWindow = new OnboardingWindow(_services, ShowSettings);
            _onboardingWindow.Closed += OnOnboardingClosed;
        }
        _onboardingWindow.Show();
    }

    /// <summary>The wizard closed, by Get Started or any other way: it is not shown at launch again (macOS hasOnboarded).</summary>
    private void OnOnboardingClosed(object sender, WindowEventArgs args)
    {
        if (_onboardingWindow is not null) _onboardingWindow.Closed -= OnOnboardingClosed;
        _onboardingWindow = null;
        if (_services is null || _services.Settings.Current.HasOnboarded) return;
        try
        {
            _services.Settings.Update(s => s with { HasOnboarded = true });
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _services.Log.Write($"settings: hasOnboarded not saved, {e.GetType().Name}");
        }
    }

    /// <summary>
    /// The tray's History…, About PopGuy… and Capture Screen Text… (OCR off): Settings comes to the front on
    /// <paramref name="tag"/>'s page (see <see cref="SettingsWindow.SelectSection"/>). UI thread.
    /// </summary>
    private void ShowSettingsSection(string tag, bool focusOcrSection)
    {
        ShowSettings();
        _settingsWindow?.SelectSection(tag, focusOcrSection);
    }

    /// <summary>The tray's Capture Screen Text… with OCR on. UI thread.</summary>
    private void CaptureScreenText()
    {
        if (!_shutDown) _services?.CaptureScreenText();
    }

    /// <summary>Settings closed: PopGuy runs on in the tray (it quits only from Quit PopGuy, or here without a tray icon).</summary>
    private void OnSettingsClosed(object sender, WindowEventArgs args)
    {
        if (_settingsWindow is not null) _settingsWindow.Closed -= OnSettingsClosed;
        _settingsWindow = null;
        if (_tray is null) Shutdown();
    }

    /// <summary>
    /// Quit PopGuy (tray), or closing Settings without a tray icon: closes Settings (its frame is saved), removes the
    /// tray icon, stops the services (history flushed), then exits. UI thread, never inside the tray icon's window
    /// procedure; once.
    /// </summary>
    private void Shutdown()
    {
        if (_shutDown) return;
        _shutDown = true;
        if (_settingsWindow is not null)
        {
            _settingsWindow.Closed -= OnSettingsClosed;
            _settingsWindow.Close();
            _settingsWindow = null;
        }
        // Quitting is not finishing: a first-launch wizard closed this way shows again at the next launch (macOS).
        if (_onboardingWindow is not null)
        {
            _onboardingWindow.Closed -= OnOnboardingClosed;
            _onboardingWindow.Close();
            _onboardingWindow = null;
        }
        if (_services is not null)
        {
            _services.SettingsRequested -= ShowSettings;
            _services.SetupGuideRequested -= ShowOnboarding;
            _services.Updates.ExitRequested -= Shutdown;
        }
        UnhandledException -= OnUnhandledException;
        if (_tray is not null) _tray.SessionEnding -= OnSessionEnding;
        _tray?.Dispose();
        _tray = null;
        _services?.Dispose();
        _services = null;
        // Explicit shutdown mode: nothing else ends the process.
        Exit();
    }

    /// <summary>Sign-out, shutdown or restart: the process may end once this returns, so the services stop now.</summary>
    private void OnSessionEnding()
    {
        _services?.Dispose();
        _services = null;
        // A sign-out ends the process before this runs; an installer closing the app (Restart Manager) does not, and
        // PopGuy must then exit instead of staying in the tray with no services.
        _dispatcher?.TryEnqueue(Shutdown);
    }

    // The framework's message and the stack: an error raised inside the XAML framework names only a parameter.
    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e) =>
        _services?.Log.Write(
            $"unhandled: {e.Exception.GetType().Name} 0x{e.Exception.HResult:X8} {e.Exception.Message} | {e.Message}\n{e.Exception.StackTrace}");

#if DEBUG
    // Phase 2 gate: the VM reads this file to check the process architecture of the installed build.
    private static void WriteLaunchProbe()
    {
        try
        {
            var probes = Path.Combine(DataRoot, "Probes");
            Directory.CreateDirectory(probes);
            var probe = new Dictionary<string, string>
            {
                ["processArchitecture"] = RuntimeInformation.ProcessArchitecture.ToString(),
                ["osVersion"] = Environment.OSVersion.VersionString,
                ["version"] = Version,
            };
            File.WriteAllText(
                Path.Combine(probes, "hello.json"),
                JsonSerializer.Serialize(probe, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Debug.WriteLine($"Launch probe failed: {ex.Message}");
        }
    }
#endif
}
