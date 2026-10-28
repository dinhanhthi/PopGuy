using System.Runtime.InteropServices;
using System.Security;
using Microsoft.Win32;
using PopGuy.Platform.Input;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.WindowsAndMessaging;

// Not PopGuy.Platform.System: that namespace would hide System for every System.-qualified name under PopGuy.Platform.
namespace PopGuy.Platform.SystemServices;

/// <summary>An item of <see cref="NotifyIcon"/>'s menu; <see cref="Text"/> null is a separator.</summary>
/// <param name="Text">The title; an "&amp;" shows as itself (no access key).</param>
/// <param name="Click">Runs after the menu closed, inside the icon's window procedure (see <see cref="NotifyIcon"/>).</param>
public sealed record NotifyIconMenuItem(string? Text, Action? Click = null, bool Enabled = true, bool Checked = false)
{
    public static NotifyIconMenuItem Separator { get; } = new((string?)null);
}

/// <summary>
/// A notification area (tray) icon on a hidden top-level <see cref="MessageWindow"/>: a left click or Enter raises
/// <see cref="Clicked"/>; a right click, Shift+F10 or the menu key opens a menu built by <see cref="MenuItems"/> at that
/// moment. The window also gets the session's end (sign-out, shutdown, restart, or an installer closing the app):
/// <see cref="SessionEnding"/>, and a change of the taskbar's light or dark theme: <see cref="TaskbarThemeChanged"/>.
/// The icon comes back when Explorer restarts ("TaskbarCreated"); an icon Explorer refuses (no taskbar yet early in a
/// logon) is logged and added then.
/// <para>
/// Threading: create, use and <see cref="Dispose"/> on the UI thread (it pumps the window's messages). Events, menu
/// builds and clicks run synchronously inside the window procedure: a handler must not dispose the icon (post that
/// work instead), and a handler that throws is logged.
/// </para>
/// </summary>
public sealed class NotifyIcon : IDisposable
{
    /// <summary>
    /// The icon's callback message (NOTIFYICON_VERSION_4: the event in LOWORD(lParam), the anchor in wParam). Clear of
    /// MessageWindow's own WM_APP + 1 and + 2: sharing + 1 with its queued-action message swallowed every click (VM QA).
    /// </summary>
    internal const uint CallbackMessage = PInvoke.WM_APP + 16;

    /// <summary>NIN_KEYSELECT: Enter or Space on the focused icon.</summary>
    internal const uint KeySelect = PInvoke.NIN_SELECT | PInvoke.NINF_KEY;

    /// <summary>Broadcast to top-level windows when a system setting changed; lParam names the section.</summary>
    private const uint WmSettingChange = 0x001A;

    /// <summary>The section a light/dark theme change names (taskbar and apps).</summary>
    private const string ImmersiveColorSet = "ImmersiveColorSet";

    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    /// <summary>The alpha a dimmed icon keeps, about Fluent's disabled text opacity.</summary>
    private const double DimmedOpacity = 0.4;

    private const uint IconId = 1;

    /// <summary>szTip holds 128 characters with the terminating null.</summary>
    private const int MaxTooltip = 127;

    private readonly MessageWindow _window;
    private readonly Action<string>? _log;
    private readonly uint _taskbarCreated;
    private readonly string _tooltip;
    private readonly int _size;
    private string _iconPath;
    private HICON _logo;

    /// <summary>The logo's pixels (see <see cref="DimmedPixels"/>), read on the first dim; empty if they cannot be read.</summary>
    private uint[]? _logoPixels;

    /// <summary>The dimmed logo shown now, destroyed when replaced; null while the logo shows.</summary>
    private HICON _drawn;

    private bool _dimmed;
    private bool _disposed;

    /// <summary>Creates the window and adds the icon. Throws <see cref="System.ComponentModel.Win32Exception"/> only if the window cannot be created.</summary>
    /// <param name="iconPath">An .ico file; the frame for the small icon size is used.</param>
    /// <param name="dimmed">Show it dimmed (see <see cref="SetIcon"/>).</param>
    public NotifyIcon(string iconPath, bool dimmed, string tooltip, Action<string>? log = null)
    {
        _log = log;
        _tooltip = tooltip.Length > MaxTooltip ? tooltip[..MaxTooltip] : tooltip;
        _iconPath = iconPath;
        _window = new MessageWindow(log, topLevel: true);
        _size = IconSize();
        _logo = LoadIcon(iconPath);
        _dimmed = dimmed;
        if (dimmed) _drawn = CreateDimmedIcon();
        _window.AddHandler(CallbackMessage, OnCallback);
        _window.AddHandler(PInvoke.WM_QUERYENDSESSION, (_, _) => (LRESULT)1); // TRUE: never blocks the session's end
        _window.AddHandler(PInvoke.WM_ENDSESSION, OnEndSession);
        _window.AddHandler(WmSettingChange, OnSettingChange);
        _taskbarCreated = PInvoke.RegisterWindowMessage("TaskbarCreated");
        if (_taskbarCreated != 0) _window.AddHandler(_taskbarCreated, OnTaskbarCreated);
        else Log("RegisterWindowMessage");
        Add();
    }

    /// <summary>The icon was clicked, or Enter or Space pressed on it. UI thread, inside the window procedure.</summary>
    public event Action? Clicked;

    /// <summary>
    /// The session ends (WM_ENDSESSION, after every app agreed): the process may be ended as soon as the handler
    /// returns, so it must finish its work before (Windows waits about 5 s). UI thread, inside the window procedure.
    /// </summary>
    public event Action? SessionEnding;

    /// <summary>
    /// The light or dark theme changed (WM_SETTINGCHANGE "ImmersiveColorSet"); read <see cref="TaskbarUsesLightTheme"/>
    /// again. Also raised when only the apps' theme changed. UI thread, inside the window procedure.
    /// </summary>
    public event Action? TaskbarThemeChanged;

    /// <summary>Builds the menu each time it opens; null or no items: no menu.</summary>
    public Func<IReadOnlyList<NotifyIconMenuItem>>? MenuItems { get; set; }

    /// <summary>
    /// The taskbar is light (HKCU Personalize <c>SystemUsesLightTheme</c> 1, not the apps' <c>AppsUseLightTheme</c>).
    /// False when the value is missing or cannot be read: the taskbar was dark before Windows 11. Any thread.
    /// </summary>
    public static bool TaskbarUsesLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
        }
        catch (Exception e) when (e is SecurityException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// Shows the .ico file <paramref name="iconPath"/>, <paramref name="dimmed"/> to its alpha times 0.4 (macOS dims the
    /// status icon while PopGuy is disabled). A file that cannot be loaded leaves an empty icon (logged).
    /// </summary>
    public void SetIcon(string iconPath, bool dimmed)
    {
        _window.CheckThread();
        if (_disposed || (iconPath == _iconPath && dimmed == _dimmed)) return;
        var previousLogo = default(HICON);
        if (iconPath != _iconPath)
        {
            previousLogo = _logo;
            _iconPath = iconPath;
            _logo = LoadIcon(iconPath);
            _logoPixels = null;
        }
        _dimmed = dimmed;
        var previous = _drawn;
        _drawn = dimmed ? CreateDimmedIcon() : default;
        if (IsAdded && !Notify(NOTIFY_ICON_MESSAGE.NIM_MODIFY)) Log("Shell_NotifyIcon(NIM_MODIFY)");
        // After the modify: the shell may still draw the icon it had until then.
        if (!previous.IsNull) PInvoke.DestroyIcon(previous);
        if (!previousLogo.IsNull) PInvoke.DestroyIcon(previousLogo);
    }

    /// <summary>Removes the icon and destroys the window. UI thread only, never from one of its own handlers.</summary>
    public void Dispose()
    {
        _window.CheckThread();
        if (_disposed) return;
        _disposed = true;
        if (IsAdded && !Notify(NOTIFY_ICON_MESSAGE.NIM_DELETE)) Log("Shell_NotifyIcon(NIM_DELETE)");
        IsAdded = false;
        if (!_drawn.IsNull) PInvoke.DestroyIcon(_drawn);
        if (!_logo.IsNull) PInvoke.DestroyIcon(_logo);
        _drawn = default;
        _logo = default;
        _window.Dispose();
    }

    /// <summary>Explorer took the icon.</summary>
    private bool IsAdded { get; set; }

    /// <summary>
    /// <paramref name="logo"/> with every pixel's alpha times <paramref name="opacity"/>. Pixels are 0xAARRGGBB with
    /// straight alpha (a 32 bpp DIB's B, G, R, A bytes), so the colour channels stay as they are.
    /// </summary>
    internal static uint[] DimmedPixels(ReadOnlySpan<uint> logo, double opacity)
    {
        var pixels = new uint[logo.Length];
        for (var i = 0; i < logo.Length; i++)
        {
            var alpha = (uint)Math.Round((logo[i] >> 24) * opacity);
            pixels[i] = alpha << 24 | logo[i] & 0xFFFFFF;
        }
        return pixels;
    }

    /// <summary>The small icon size, which the notification area shows.</summary>
    private static int IconSize() => Math.Max(16, PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CXSMICON));

    private unsafe HICON LoadIcon(string path)
    {
        HANDLE handle;
        fixed (char* name = path)
        {
            handle = PInvoke.LoadImage(HINSTANCE.Null, name, GDI_IMAGE_TYPE.IMAGE_ICON, _size, _size, IMAGE_FLAGS.LR_LOADFROMFILE);
        }
        if (handle.IsNull) Log($"LoadImage({Path.GetFileName(path)})");
        return new HICON(handle.Value);
    }

    /// <summary>A 32 bpp, top-down, <see cref="_size"/> square DIB header.</summary>
    private unsafe BITMAPINFO DibInfo() => new()
    {
        bmiHeader = new BITMAPINFOHEADER
        {
            biSize = (uint)sizeof(BITMAPINFOHEADER),
            biWidth = _size,
            biHeight = -_size, // top-down rows
            biPlanes = 1,
            biBitCount = 32,
            biCompression = 0, // BI_RGB
        },
    };

    /// <summary>
    /// The logo's pixels as <see cref="DimmedPixels"/> takes them; empty (a transparent logo) if there is no logo or GDI
    /// refuses. A .ico frame's 32 bpp colour bitmap holds straight alpha; one without alpha (all zero) takes it from the mask.
    /// </summary>
    private unsafe uint[] ReadLogoPixels()
    {
        if (_logo.IsNull) return [];
        ICONINFO iconInfo;
        if (GetIconInfo(_logo, &iconInfo) == 0)
        {
            Log("GetIconInfo");
            return [];
        }
        var screen = GetDC(HWND.Null);
        try
        {
            var color = ReadBitmap(screen, iconInfo.hbmColor);
            if (color.Length == 0 || color.Any(pixel => pixel >> 24 != 0)) return color;
            // GetDIBits turns the monochrome mask into black (opaque) and white (transparent) pixels.
            var mask = ReadBitmap(screen, iconInfo.hbmMask);
            if (mask.Length != color.Length) return [];
            for (var i = 0; i < color.Length; i++) color[i] = (mask[i] & 0xFFFFFF) == 0 ? color[i] | 0xFF000000 : 0;
            return color;
        }
        finally
        {
            // GetIconInfo made copies of both bitmaps.
            if (!screen.IsNull) ReleaseDC(HWND.Null, screen);
            if (!iconInfo.hbmColor.IsNull) PInvoke.DeleteObject(iconInfo.hbmColor);
            if (!iconInfo.hbmMask.IsNull) PInvoke.DeleteObject(iconInfo.hbmMask);
        }
    }

    /// <summary>The first <see cref="_size"/> rows of <paramref name="bitmap"/> as 32 bpp pixels; empty if GDI refuses.</summary>
    private unsafe uint[] ReadBitmap(HDC screen, HBITMAP bitmap)
    {
        if (screen.IsNull || bitmap.IsNull) return [];
        var info = DibInfo();
        var pixels = new uint[_size * _size];
        fixed (uint* bits = pixels)
        {
            if (GetDIBits(screen, bitmap, 0, (uint)_size, bits, &info, DIB_USAGE.DIB_RGB_COLORS) != _size)
            {
                Log("GetDIBits");
                return [];
            }
        }
        return pixels;
    }

    /// <summary>A 32 bpp icon from <see cref="DimmedPixels"/>; null (the logo shows undimmed) if GDI refuses.</summary>
    private unsafe HICON CreateDimmedIcon()
    {
        var size = _size;
        var info = DibInfo();
        void* bits;
        var color = PInvoke.CreateDIBSection(default, &info, DIB_USAGE.DIB_RGB_COLORS, &bits, default, 0);
        if (color.IsNull)
        {
            Log("CreateDIBSection");
            return default;
        }
        // The mask is unused with per-pixel alpha, but must exist: all zero (monochrome rows are WORD-aligned).
        HBITMAP mask;
        fixed (byte* zero = new byte[(size + 15) / 16 * 2 * size]) mask = PInvoke.CreateBitmap(size, size, 1, 1, zero);
        try
        {
            if (mask.IsNull)
            {
                Log("CreateBitmap");
                return default;
            }
            _logoPixels ??= ReadLogoPixels();
            if (_logoPixels.Length != size * size) return default;
            DimmedPixels(_logoPixels, DimmedOpacity).AsSpan().CopyTo(new Span<uint>(bits, size * size));
            var iconInfo = new ICONINFO { fIcon = true, hbmMask = mask, hbmColor = color };
            var icon = PInvoke.CreateIconIndirect(&iconInfo);
            if (icon.IsNull) Log("CreateIconIndirect");
            return icon;
        }
        finally
        {
            // CreateIconIndirect copied both bitmaps.
            PInvoke.DeleteObject(color);
            if (!mask.IsNull) PInvoke.DeleteObject(mask);
        }
    }

    private void Add()
    {
        // An icon still there (TaskbarCreated also comes when the taskbar only changed) refuses NIM_ADD: updated instead.
        IsAdded = Notify(NOTIFY_ICON_MESSAGE.NIM_ADD) || Notify(NOTIFY_ICON_MESSAGE.NIM_MODIFY);
        if (!IsAdded)
        {
            Log("Shell_NotifyIcon(NIM_ADD)");
            return;
        }
        if (!Notify(NOTIFY_ICON_MESSAGE.NIM_SETVERSION)) Log("Shell_NotifyIcon(NIM_SETVERSION)");
    }

    private unsafe bool Notify(NOTIFY_ICON_MESSAGE message)
    {
        var data = new NotifyIconData
        {
            cbSize = (uint)sizeof(NotifyIconData),
            hWnd = _window.Handle,
            uID = IconId,
            // NIF_SHOWTIP: version 4 shows the standard tooltip only with it.
            uFlags = (uint)(NOTIFY_ICON_DATA_FLAGS.NIF_MESSAGE | NOTIFY_ICON_DATA_FLAGS.NIF_ICON | NOTIFY_ICON_DATA_FLAGS.NIF_TIP
                | NOTIFY_ICON_DATA_FLAGS.NIF_SHOWTIP),
            uCallbackMessage = CallbackMessage,
            hIcon = _drawn.IsNull ? _logo : _drawn,
            uVersion = message == NOTIFY_ICON_MESSAGE.NIM_SETVERSION ? PInvoke.NOTIFYICON_VERSION_4 : 0,
        };
        _tooltip.AsSpan().CopyTo(new Span<char>(data.szTip, MaxTooltip + 1));
        return Shell_NotifyIconW((uint)message, &data) != 0;
    }

    private LRESULT? OnCallback(WPARAM wParam, LPARAM lParam)
    {
        var notification = (uint)(lParam.Value & 0xFFFF);
        if (notification is PInvoke.NIN_SELECT or KeySelect)
        {
            // Now, while the shell's foreground right from the click lasts (as ShowMenu): a window the handler shows
            // later (posted) can then come in front, since the process owns the foreground.
            PInvoke.SetForegroundWindow(_window.Handle);
            Clicked?.Invoke();
        }
        else if (notification == PInvoke.WM_CONTEXTMENU)
        {
            // The anchor in screen coordinates: GET_X_LPARAM / GET_Y_LPARAM of wParam.
            var anchor = (nint)wParam.Value;
            ShowMenu((short)(anchor & 0xFFFF), (short)((anchor >> 16) & 0xFFFF));
        }
        return (LRESULT)0;
    }

    private LRESULT? OnEndSession(WPARAM wParam, LPARAM lParam)
    {
        // wParam FALSE: an app or the user cancelled the end.
        if (wParam.Value != 0) SessionEnding?.Invoke();
        return (LRESULT)0;
    }

    private LRESULT? OnSettingChange(WPARAM wParam, LPARAM lParam)
    {
        // lParam: the changed section's name, or null.
        if (!_disposed && lParam.Value != 0 && Marshal.PtrToStringUni(lParam.Value) == ImmersiveColorSet)
        {
            TaskbarThemeChanged?.Invoke();
        }
        return null; // DefWindowProc too
    }

    private LRESULT? OnTaskbarCreated(WPARAM wParam, LPARAM lParam)
    {
        if (!_disposed) Add();
        return null;
    }

    /// <summary>The menu at (<paramref name="x"/>, <paramref name="y"/>), modal until it closes; then the picked item's click.</summary>
    private void ShowMenu(int x, int y)
    {
        if (MenuItems?.Invoke() is not { Count: > 0 } items) return;
        var clicks = new List<Action?>();
        var menu = BuildMenu(items, clicks);
        if (menu.IsNull) return;
        int picked;
        try
        {
            // The menu closes on a click elsewhere only while its window is the foreground window, and the posted
            // WM_NULL makes the next click on the icon open it again (KB135788).
            PInvoke.SetForegroundWindow(_window.Handle);
            var flags = TRACK_POPUP_MENU_FLAGS.TPM_RETURNCMD | TRACK_POPUP_MENU_FLAGS.TPM_NONOTIFY | TRACK_POPUP_MENU_FLAGS.TPM_RIGHTBUTTON
                | TRACK_POPUP_MENU_FLAGS.TPM_BOTTOMALIGN
                | (PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_MENUDROPALIGNMENT) != 0
                    ? TRACK_POPUP_MENU_FLAGS.TPM_RIGHTALIGN : TRACK_POPUP_MENU_FLAGS.TPM_LEFTALIGN);
            unsafe
            {
                picked = PInvoke.TrackPopupMenuEx(menu, (uint)flags, x, y, _window.Handle, null).Value;
            }
            PInvoke.PostMessage(_window.Handle, PInvoke.WM_NULL, 0, 0);
        }
        finally
        {
            PInvoke.DestroyMenu(menu);
        }
        // Ids are 1-based: 0 means closed without a pick.
        if (picked > 0 && picked <= clicks.Count) clicks[picked - 1]?.Invoke();
    }

    /// <summary>A popup menu of <paramref name="items"/>; each item's id is its index in <paramref name="clicks"/> plus 1.</summary>
    private unsafe HMENU BuildMenu(IReadOnlyList<NotifyIconMenuItem> items, List<Action?> clicks)
    {
        var menu = PInvoke.CreatePopupMenu();
        if (menu.IsNull)
        {
            Log("CreatePopupMenu");
            return menu;
        }
        foreach (var item in items)
        {
            if (item.Text is null)
            {
                PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, default(PCWSTR));
                continue;
            }
            var flags = item.Enabled ? MENU_ITEM_FLAGS.MF_STRING : MENU_ITEM_FLAGS.MF_STRING | MENU_ITEM_FLAGS.MF_GRAYED;
            if (item.Checked) flags |= MENU_ITEM_FLAGS.MF_CHECKED;
            clicks.Add(item.Click);
            // "&" marks an access key: a title with "&" keeps it.
            fixed (char* text = item.Text.Replace("&", "&&"))
            {
                if (!PInvoke.AppendMenu(menu, flags, (nuint)clicks.Count, text)) Log("AppendMenu");
            }
        }
        return menu;
    }

    private void Log(string call) => _log?.Invoke($"notify icon: {call} failed, {Marshal.GetLastPInvokeError()}");

    /// <summary>
    /// NOTIFYICONDATAW, 64-bit layout (976 bytes; the app ships x64 and ARM64 only). Declared here: CsWin32 generates it
    /// and Shell_NotifyIconW only for a fixed CPU architecture, and Platform builds as AnyCPU.
    /// </summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private unsafe struct NotifyIconData
    {
        public uint cbSize;
        public HWND hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public HICON hIcon;
        public fixed char szTip[128];
        public uint dwState;
        public uint dwStateMask;
        public fixed char szInfo[256];
        public uint uVersion; // union with uTimeout
        public fixed char szInfoTitle[64];
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }

    [DllImport("shell32.dll", ExactSpelling = true)]
    private static extern unsafe int Shell_NotifyIconW(uint message, NotifyIconData* data);

    // Hand-declared, not in NativeMethods.txt (Phase 12 keeps that file closed): reading the logo's pixels to dim it.

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern unsafe int GetIconInfo(HICON icon, ICONINFO* info);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern HDC GetDC(HWND window);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern int ReleaseDC(HWND window, HDC dc);

    [DllImport("gdi32.dll", ExactSpelling = true)]
    private static extern unsafe int GetDIBits(
        HDC dc, HBITMAP bitmap, uint start, uint lines, void* bits, BITMAPINFO* info, DIB_USAGE usage);
}
