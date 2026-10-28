using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using PopGuy.Platform.Windowing;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.WindowsAndMessaging;

// Not PopGuy.Platform.System: that namespace would hide System for every System.-qualified name under PopGuy.Platform.
namespace PopGuy.Platform.SystemServices;

/// <summary>An app for Settings → Ignore.</summary>
/// <param name="Exe">The executable's file name in lowercase ("notepad.exe"), as the ignored apps store it.</param>
/// <param name="Path">The executable's full path, or null when it is not known (the app is not running).</param>
/// <param name="DisplayName">The executable's FileDescription ("Notepad"), else <paramref name="Exe"/>.</param>
public sealed record AppInfo(string Exe, string? Path, string DisplayName);

/// <summary>An icon's pixels, rows top-down; each pixel 0xAARRGGBB with straight alpha (a 32 bpp DIB's B, G, R, A bytes).</summary>
public sealed record AppIconPixels(int Width, int Height, uint[] Pixels);

/// <summary>
/// The apps and icons of Settings → Ignore (macOS AppsView's NSWorkspace lookups): the running apps with a window, an
/// ignored exe name resolved to its running executable, and an executable's small shell icon as pixels (the App makes
/// the image). Every method may block on other processes or the disk: call them off the UI thread. Any thread.
/// </summary>
public static class AppIcons
{
    private const uint ShgfiIcon = 0x100;
    private const uint ShgfiSmallIcon = 0x1;

    /// <summary>
    /// The apps of the visible top-level windows with a title, one per executable, by display name. A Store (UWP) app
    /// is its hosted process (<see cref="ForegroundApp.Snapshot"/>'s rule); a frame whose app is suspended, a process
    /// Windows does not let PopGuy read, and PopGuy itself are left out.
    /// </summary>
    public static IReadOnlyList<AppInfo> RunningApps()
    {
        var windows = new List<nint>();
        var ownProcess = (uint)Environment.ProcessId;
        WNDENUMPROC collect = (hwnd, _) =>
        {
            // PopGuy's own windows first: reading their title from this thread would wait for the UI thread.
            if (ToolbarWindowStyle.ProcessIdOf(hwnd) != ownProcess && PInvoke.IsWindowVisible(hwnd) && HasTitle(hwnd))
            {
                windows.Add(hwnd);
            }
            return true;
        };
        PInvoke.EnumWindows(collect, default);
        GC.KeepAlive(collect);

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var apps = new List<AppInfo>();
        foreach (var hwnd in windows)
        {
            var (app, path) = ForegroundApp.OfWindow(hwnd);
            if (app.IsOwnProcess || app.Exe is not { } exe || exe == ForegroundApp.FrameHostExe || !seen.Add(exe)) continue;
            apps.Add(new AppInfo(exe, path, app.DisplayName));
        }
        return [.. apps.OrderBy(a => a.DisplayName, StringComparer.CurrentCultureIgnoreCase)];
    }

    /// <summary>
    /// An ignored exe name with its path and display name: <paramref name="knownPath"/> when that file still exists,
    /// else a running process of that executable, else no path and the exe name.
    /// </summary>
    public static AppInfo Resolve(string exe, string? knownPath = null)
    {
        var path = knownPath is not null && File.Exists(knownPath) ? knownPath : RunningPath(exe);
        return new AppInfo(exe, path, ForegroundApp.DescriptionOf(path) ?? exe);
    }

    /// <summary>A picked executable (Browse…): its lowercase file name and display name.</summary>
    public static AppInfo Describe(string path)
    {
        var exe = Path.GetFileName(path).ToLowerInvariant();
        return new AppInfo(exe, path, ForegroundApp.DescriptionOf(path) ?? exe);
    }

    /// <summary>
    /// The small icon the shell shows for <paramref name="path"/> (its own icon, or the generic one of its type); null
    /// when the shell or GDI refuses.
    /// </summary>
    public static unsafe AppIconPixels? Load(string path)
    {
        var info = default(ShFileInfo);
        nuint found;
        fixed (char* name = path)
        {
            found = SHGetFileInfoW(name, 0, &info, (uint)sizeof(ShFileInfo), ShgfiIcon | ShgfiSmallIcon);
        }
        if (found == 0 || info.hIcon.IsNull) return null;
        try
        {
            return ReadPixels(info.hIcon);
        }
        finally
        {
            PInvoke.DestroyIcon(info.hIcon);
        }
    }

    private static bool HasTitle(HWND hwnd)
    {
        Span<char> buffer = stackalloc char[2];
        return PInvoke.GetWindowText(hwnd, buffer) > 0;
    }

    /// <summary>The path of a running process of <paramref name="exe"/>; null when none runs or none can be read.</summary>
    private static string? RunningPath(string exe)
    {
        var name = Path.GetFileNameWithoutExtension(exe);
        if (name.Length == 0) return null;
        Process[] processes;
        try
        {
            processes = Process.GetProcessesByName(name);
        }
        catch (Exception e) when (e is InvalidOperationException or Win32Exception)
        {
            return null;
        }
        try
        {
            foreach (var process in processes)
            {
                var (path, _) = ForegroundApp.Inspect((uint)process.Id);
                if (path is not null && Path.GetFileName(path).Equals(exe, StringComparison.OrdinalIgnoreCase)) return path;
            }
            return null;
        }
        finally
        {
            foreach (var process in processes) process.Dispose();
        }
    }

    /// <summary>
    /// The icon's colour bitmap as 32 bpp pixels (NotifyIcon's reading): a colour bitmap without alpha (all zero) takes
    /// it from the mask. Null for a monochrome icon or when GDI refuses.
    /// </summary>
    private static unsafe AppIconPixels? ReadPixels(HICON icon)
    {
        ICONINFO iconInfo;
        if (GetIconInfo(icon, &iconInfo) == 0) return null;
        var screen = GetDC(HWND.Null);
        try
        {
            if (screen.IsNull || iconInfo.hbmColor.IsNull || SizeOf(screen, iconInfo.hbmColor) is not { } size) return null;
            var (width, height) = size;
            var color = ReadBitmap(screen, iconInfo.hbmColor, width, height);
            if (color is null) return null;
            if (color.Any(pixel => pixel >> 24 != 0)) return new(width, height, color);
            // GetDIBits turns the monochrome mask into black (opaque) and white (transparent) pixels.
            var mask = ReadBitmap(screen, iconInfo.hbmMask, width, height);
            if (mask is null) return null;
            for (var i = 0; i < color.Length; i++) color[i] = (mask[i] & 0xFFFFFF) == 0 ? color[i] | 0xFF000000 : 0;
            return new(width, height, color);
        }
        finally
        {
            // GetIconInfo made copies of both bitmaps.
            if (!screen.IsNull) ReleaseDC(HWND.Null, screen);
            if (!iconInfo.hbmColor.IsNull) PInvoke.DeleteObject(iconInfo.hbmColor);
            if (!iconInfo.hbmMask.IsNull) PInvoke.DeleteObject(iconInfo.hbmMask);
        }
    }

    /// <summary>The bitmap's size (GetDIBits with no bits and no bit count fills in the header); null when GDI refuses.</summary>
    private static unsafe (int Width, int Height)? SizeOf(HDC screen, HBITMAP bitmap)
    {
        var info = new BITMAPINFO { bmiHeader = new BITMAPINFOHEADER { biSize = (uint)sizeof(BITMAPINFOHEADER) } };
        if (GetDIBits(screen, bitmap, 0, 0, null, &info, DIB_USAGE.DIB_RGB_COLORS) == 0) return null;
        var (width, height) = (info.bmiHeader.biWidth, Math.Abs(info.bmiHeader.biHeight));
        return width > 0 && height > 0 ? (width, height) : null;
    }

    /// <summary>The first <paramref name="height"/> rows of <paramref name="bitmap"/> as 32 bpp, top-down pixels; null if GDI refuses.</summary>
    private static unsafe uint[]? ReadBitmap(HDC screen, HBITMAP bitmap, int width, int height)
    {
        if (bitmap.IsNull) return null;
        var info = new BITMAPINFO
        {
            bmiHeader = new BITMAPINFOHEADER
            {
                biSize = (uint)sizeof(BITMAPINFOHEADER),
                biWidth = width,
                biHeight = -height, // top-down rows
                biPlanes = 1,
                biBitCount = 32,
                biCompression = 0, // BI_RGB
            },
        };
        var pixels = new uint[width * height];
        fixed (uint* bits = pixels)
        {
            if (GetDIBits(screen, bitmap, 0, (uint)height, bits, &info, DIB_USAGE.DIB_RGB_COLORS) != height) return null;
        }
        return pixels;
    }

    /// <summary>
    /// SHFILEINFOW, 64-bit layout (696 bytes; the app ships x64 and ARM64 only). Declared here: CsWin32 generates it and
    /// SHGetFileInfoW only for a fixed CPU architecture, and Platform builds as AnyCPU.
    /// </summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private unsafe struct ShFileInfo
    {
        public HICON hIcon;
        public int iIcon;
        public uint dwAttributes;
        public fixed char szDisplayName[260];
        public fixed char szTypeName[80];
    }

    [DllImport("shell32.dll", ExactSpelling = true)]
    private static extern unsafe nuint SHGetFileInfoW(char* path, uint fileAttributes, ShFileInfo* info, uint size, uint flags);

    // Hand-declared, not in NativeMethods.txt (closed this phase): reading the icon's pixels, as NotifyIcon does.

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
