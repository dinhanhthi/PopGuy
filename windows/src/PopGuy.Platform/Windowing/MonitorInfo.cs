using System.Drawing;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.HiDpi;

namespace PopGuy.Platform.Windowing;

/// <summary>
/// The monitor under a point, in physical screen pixels (the toolbar's positioning space, <c>PanelPositioning</c>).
/// The monitor nearest to the point when no monitor holds it. Any thread.
/// </summary>
public static class MonitorInfo
{
    /// <summary>The work area (the monitor without the taskbar) of the monitor under <paramref name="point"/>; empty when unreadable.</summary>
    public static Rectangle WorkArea(Point point)
    {
        var monitor = PInvoke.MonitorFromPoint(point, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        if (monitor.IsNull) return Rectangle.Empty;
        var info = new MONITORINFO { cbSize = (uint)Marshal.SizeOf<MONITORINFO>() };
        if (!PInvoke.GetMonitorInfo(monitor, ref info)) return Rectangle.Empty;
        var work = info.rcWork;
        return Rectangle.FromLTRB(work.left, work.top, work.right, work.bottom);
    }

    /// <summary>The effective DPI of the monitor under <paramref name="point"/>; 96 when unreadable.</summary>
    public static uint Dpi(Point point)
    {
        var monitor = PInvoke.MonitorFromPoint(point, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        if (monitor.IsNull) return 96;
        return PInvoke.GetDpiForMonitor(monitor, MONITOR_DPI_TYPE.MDT_EFFECTIVE_DPI, out var dpi, out _).Succeeded && dpi > 0
            ? dpi
            : 96;
    }

    /// <summary>The scale of the monitor under <paramref name="point"/> (physical pixels per DIP: 1.0 at 96 DPI).</summary>
    public static double Scale(Point point) => Dpi(point) / 96.0;
}
