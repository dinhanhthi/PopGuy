using System.Reflection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PopGuy.Services;
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

    private Window? _window;
    private AppServices? _services;
    private DispatcherQueue? _dispatcher;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
#if DEBUG
        WriteLaunchProbe();
        // Phase 3 spike harnesses (--spike, --probe-uia): no main window, exit when done.
        if (PopGuy.Debug.Probes.TryStart(Exit)) return;
#endif
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        // The hello window is the "PopGuy is running" window until the tray arrives (Phase 12): closing it quits.
        _window = new MainWindow();
        _window.Closed += OnMainWindowClosed;
        _window.Activate();

        try
        {
            _services = AppServices.Start(_dispatcher);
            UnhandledException += OnUnhandledException;
        }
        catch (Exception e)
        {
            // Logged by AppServices; the window stays, without triggers.
            System.Diagnostics.Debug.WriteLine($"PopGuy services did not start: {e.GetType().Name}");
        }
    }

    /// <summary>A later launch redirected here (any thread, see Program): the main window comes to the front.</summary>
    internal void OnRelaunched()
    {
        // Window members are UI thread only; the dispatcher queue may be used from any thread.
        _dispatcher?.TryEnqueue(() => _window?.Activate());
    }

    private void OnMainWindowClosed(object sender, WindowEventArgs args)
    {
        _window!.Closed -= OnMainWindowClosed;
        UnhandledException -= OnUnhandledException;
        _services?.Dispose();
        _services = null;
        // The hidden toolbar window would keep the process alive.
        Exit();
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e) =>
        _services?.Log.Write($"unhandled: {e.Exception.GetType().Name} {e.Exception.Message}");

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
