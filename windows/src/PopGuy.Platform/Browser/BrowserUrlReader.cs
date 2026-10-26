using System.Runtime.InteropServices;
using PopGuy.Core.Toolbar;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Accessibility;

namespace PopGuy.Platform.Browser;

/// <summary>
/// Reads the host of the source browser window's current tab through UI Automation (macOS <c>BrowserURLReader</c>, which
/// uses Apple Events): the address bar's Edit in the window, found by the identifiers each browser gives it, and its
/// value pattern. Only the host leaves this class (<see cref="PresentationGate.NormalizeHost"/>), never the address.
/// Windows reads the address bar's text, not the tab's URL: while the user edits it, the host is whatever they typed
/// (a search has none). Every failure (no address bar, a UI Automation error, no answer in time) is "no host", which the
/// gate treats as not ignored.
/// </summary>
public static class BrowserUrlReader
{
    /// <summary>The read runs before the toolbar shows, so it gives up quickly (as the capture probes do).</summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromMilliseconds(300);

    /// <summary>Chromium browsers: the omnibox is a views control with this class name in every UI language.</summary>
    private static readonly string[] ChromiumExes = ["msedge.exe", "chrome.exe", "brave.exe"];

    private const string FirefoxExe = "firefox.exe";

    /// <summary>The omnibox's UI Automation ClassName (Chromium names a views element after its class).</summary>
    private const string ChromiumOmniboxClass = "OmniboxViewViews";

    /// <summary>The omnibox's English name, should a Chromium build not report the class name.</summary>
    private const string ChromiumOmniboxName = "Address and search bar";

    /// <summary>Firefox's address field: its DOM id, which Firefox's native UI Automation reports as the AutomationId.</summary>
    private const string FirefoxUrlBarId = "urlbar-input";

    /// <summary>Firefox's English names for the address field, for its accessibility bridge (no AutomationId there).</summary>
    private static readonly string[] FirefoxUrlBarNames = ["Search or enter address", "Search with Google or enter address"];

    /// <summary>Whether <paramref name="exe"/> (a lowercase file name, as <c>ForegroundApp.Exe</c>) is a browser the reader knows.</summary>
    public static bool IsSupportedBrowser(string? exe) => exe is not null && (ChromiumExes.Contains(exe) || exe == FirefoxExe);

    /// <summary>
    /// The normalized host of the current tab in <paramref name="hwnd"/> (the source's top-level window) of
    /// <paramref name="exe"/>'s browser, or null. Runs on a dedicated MTA thread and waits up to 300 ms (the abandoned
    /// thread ends whenever UI Automation returns). Blocks the caller for 300 ms at most: call it off the UI thread.
    /// </summary>
    public static string? ReadHost(nint hwnd, string? exe)
    {
        if (hwnd == 0 || !IsSupportedBrowser(exe)) return null;
        string? host = null;
        var thread = new Thread(() => host = ReadCore(hwnd, exe!)) { IsBackground = true, Name = "PopGuy UIA browser URL" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        return thread.Join(Timeout) ? host : null;
    }

    private static string? ReadCore(nint hwnd, string exe)
    {
        IUIAutomation? automation = null;
        IUIAutomationElement? window = null;
        IUIAutomationCondition? condition = null;
        IUIAutomationElement? addressBar = null;
        IUIAutomationValuePattern? valuePattern = null;
        try
        {
            automation = (IUIAutomation)new CUIAutomation8();
            window = automation.ElementFromHandle((HWND)hwnd);
            if (window is null) return null;
            condition = AddressBarCondition(automation, exe == FirefoxExe);
            addressBar = window.FindFirst(TreeScope.TreeScope_Descendants, condition);
            if (addressBar is null) return null;
            valuePattern = addressBar.GetCurrentPattern(UIA_PATTERN_ID.UIA_ValuePatternId) as IUIAutomationValuePattern;
            if (valuePattern is null) return null;
            return PresentationGate.NormalizeHost(ReadBstr(valuePattern.CurrentValue));
        }
        catch (Exception)
        {
            // COM errors map to many exception types, and an exception escaping this background thread would end the process.
            return null;
        }
        finally
        {
            Release(valuePattern);
            Release(addressBar);
            Release(condition);
            Release(window);
            Release(automation);
        }
    }

    /// <summary>An Edit control with the browser's address-bar identifier (Firefox: its id or name; Chromium: class or name).</summary>
    private static IUIAutomationCondition AddressBarCondition(IUIAutomation automation, bool firefox)
    {
        var identifiers = firefox
            ? [(UIA_PROPERTY_ID.UIA_AutomationIdPropertyId, FirefoxUrlBarId), .. FirefoxUrlBarNames.Select(n => (UIA_PROPERTY_ID.UIA_NamePropertyId, n))]
            : new[] { (UIA_PROPERTY_ID.UIA_ClassNamePropertyId, ChromiumOmniboxClass), (UIA_PROPERTY_ID.UIA_NamePropertyId, ChromiumOmniboxName) };
        var conditions = identifiers.Select(i => automation.CreatePropertyCondition(i.Item1, i.Item2)).ToArray();
        IUIAutomationCondition? any = null;
        IUIAutomationCondition? edit = null;
        try
        {
            any = automation.CreateOrConditionFromNativeArray(conditions, conditions.Length);
            edit = automation.CreatePropertyCondition(UIA_PROPERTY_ID.UIA_ControlTypePropertyId, (int)UIA_CONTROLTYPE_ID.UIA_EditControlTypeId);
            // The combined condition holds its own references to the parts.
            return automation.CreateAndCondition(edit, any);
        }
        finally
        {
            Release(edit);
            Release(any);
            foreach (var condition in conditions) Release(condition);
        }
    }

    private static string ReadBstr(BSTR value)
    {
        try
        {
            return value.ToString() ?? "";
        }
        finally
        {
            PInvoke.SysFreeString(value);
        }
    }

    private static void Release(object? comObject)
    {
        if (comObject is not null && Marshal.IsComObject(comObject)) Marshal.ReleaseComObject(comObject);
    }
}
