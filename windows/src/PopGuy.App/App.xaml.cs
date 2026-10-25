using System.Reflection;
using Microsoft.UI.Xaml;
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

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
#if DEBUG
        WriteLaunchProbe();
#endif
        _window = new MainWindow();
        _window.Activate();
    }

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
