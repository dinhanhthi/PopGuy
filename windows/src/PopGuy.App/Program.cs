using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using PopGuy.Platform.Windowing;

namespace PopGuy;

/// <summary>
/// The entry point (the csproj defines DISABLE_XAML_GENERATED_MAIN): what the generated Main does, plus single
/// instance. A second launch hands its activation to the running instance (which brings Settings to the front) and
/// exits, so there is only ever one set of hooks and hotkeys.
/// <para>
/// DEBUG harness runs (any argument starting with "--", e.g. <c>--spike</c>, <c>--probe-uia</c>, <c>--import-key</c>)
/// skip the single-instance check: they must run even while PopGuy is running (an <c>--import-key</c> that redirected
/// would exit without importing). Such a run may then coexist with the resident instance: a harness that registers
/// hotkeys (<c>--spike</c>) finds them in use, so stop PopGuy before those.
/// </para>
/// </summary>
public static class Program
{
    private const string InstanceKey = "PopGuy";

    /// <summary>How long a second launch waits for the running instance to take its activation.</summary>
    private static readonly TimeSpan RedirectTimeout = TimeSpan.FromSeconds(5);

    /// <summary>The application, for later launches (their activation arrives on a background thread).</summary>
    private static volatile App? _app;

    [STAThread]
    private static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        if (!IsHarnessRun(args) && RedirectedToRunningInstance()) return;

        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _app = new App();
        });
    }

    private static bool IsHarnessRun(string[] args)
    {
#if DEBUG
        return args.Any(a => a.StartsWith("--", StringComparison.Ordinal));
#else
        return false;
#endif
    }

    /// <summary>
    /// True when another PopGuy owns the key: the activation went to it and this process should exit. Otherwise this
    /// process owns the key and listens for later launches.
    /// </summary>
    private static bool RedirectedToRunningInstance()
    {
        var owner = AppInstance.FindOrRegisterForKey(InstanceKey);
        if (owner.IsCurrent)
        {
            owner.Activated += OnRedirectedActivation;
            return false;
        }

        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        try
        {
            // Off the STA main thread (the cross-process call must not wait on it); the managed wait here pumps COM.
            Task.Run(() => owner.RedirectActivationToAsync(activation).AsTask()).Wait(RedirectTimeout);
        }
        catch (AggregateException)
        {
            // The running instance did not take it: exit anyway, a second resident PopGuy would double every hook.
        }
        // This process was launched by the user, so it may give the foreground away: the running instance activates its
        // Settings window (OnRelaunched). Never SetForegroundWindow on its MainWindowHandle, which can be the topmost
        // toolbar and would take the foreground from the source app.
        ToolbarWindowStyle.AllowForegroundFor(owner.ProcessId);
        return true;
    }

    /// <summary>A later launch redirected here (on a background thread): show Settings.</summary>
    private static void OnRedirectedActivation(object? sender, AppActivationArguments args) =>
        _app?.OnRelaunched();
}
