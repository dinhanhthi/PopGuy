using System.Drawing;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.WindowsAndMessaging;

namespace PopGuy.Platform.Ocr;

/// <summary>
/// A screenshot of a screen region for OCR (macOS ScreenshotCapturer): GDI copies the desktop's pixels into a DIB
/// section, then into a <see cref="SoftwareBitmap"/>. Any thread; the copy blocks for a few milliseconds.
/// </summary>
public static class ScreenCapture
{
    /// <summary>
    /// The virtual screen (every monitor) in physical pixels; its origin is the top-left of the leftmost and topmost
    /// monitor, so it is negative when a monitor sits left of or above the primary one.
    /// </summary>
    public static Rectangle VirtualScreen() => new(
        PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_XVIRTUALSCREEN),
        PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_YVIRTUALSCREEN),
        PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CXVIRTUALSCREEN),
        PInvoke.GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CYVIRTUALSCREEN));

    /// <summary>
    /// The pixels of <paramref name="rectPx"/> (physical virtual-screen pixels, as a per-monitor DPI aware process sees
    /// them; it may span monitors) as an opaque BGRA8 bitmap the caller disposes. Only the part on the virtual screen is
    /// captured, which also caps the size; null when that part is empty or GDI refuses. Layered windows are included,
    /// so hide PopGuy's own overlay first.
    /// </summary>
    public static unsafe SoftwareBitmap? Capture(Rectangle rectPx)
    {
        var rect = Rectangle.Intersect(rectPx, VirtualScreen());
        if (rect.Width <= 0 || rect.Height <= 0) return null;
        var (width, height) = (rect.Width, rect.Height);

        var screen = PInvoke.GetDC(HWND.Null);
        if (screen.IsNull) return null;
        var memory = default(HDC);
        var bitmap = default(HBITMAP);
        var previous = default(HGDIOBJ);
        try
        {
            memory = PInvoke.CreateCompatibleDC(screen);
            if (memory.IsNull) return null;
            var info = new BITMAPINFO
            {
                bmiHeader = new BITMAPINFOHEADER
                {
                    biSize = (uint)sizeof(BITMAPINFOHEADER),
                    biWidth = width,
                    biHeight = -height, // top-down rows
                    biPlanes = 1,
                    biBitCount = 32,
                    biCompression = 0, // BI_RGB: 32 bpp rows have no padding
                },
            };
            void* bits;
            bitmap = PInvoke.CreateDIBSection(screen, &info, DIB_USAGE.DIB_RGB_COLORS, &bits, default, 0);
            if (bitmap.IsNull) return null;
            previous = PInvoke.SelectObject(memory, bitmap);
            if (previous.IsNull) return null;
            if (!PInvoke.BitBlt(memory, 0, 0, width, height, screen, rect.X, rect.Y, ROP_CODE.SRCCOPY)) return null;
            // GDI may batch the copy: flush it before reading the DIB's memory.
            PInvoke.GdiFlush();

            // The screen copy leaves alpha undefined (usually 0): made opaque, so the bitmap shows as is when premultiplied.
            var pixels = new byte[checked(width * height * 4)];
            var source = new ReadOnlySpan<uint>(bits, width * height);
            var target = MemoryMarshal.Cast<byte, uint>(pixels.AsSpan());
            for (var i = 0; i < source.Length; i++) target[i] = source[i] | 0xFF000000;
            return SoftwareBitmap.CreateCopyFromBuffer(
                pixels.AsBuffer(), BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Premultiplied);
        }
        finally
        {
            if (!previous.IsNull) PInvoke.SelectObject(memory, previous);
            if (!bitmap.IsNull) PInvoke.DeleteObject(bitmap);
            if (!memory.IsNull) PInvoke.DeleteDC(memory);
            PInvoke.ReleaseDC(HWND.Null, screen);
        }
    }

    /// <summary>
    /// The pixels of each of <paramref name="rectsPx"/> (relative to the top-left of <paramref name="source"/>, a BGRA8
    /// bitmap such as <see cref="Capture"/>'s) as new bitmaps the caller disposes, in the same order: the region
    /// overlay's freeze-frame is cut into per-monitor backgrounds and the selected region without a second capture. The
    /// source's pixels are read once for all of them. Only the part of a rect inside the source is copied; null for a
    /// rect whose part is empty, every one null when the source is not BGRA8. Any thread.
    /// </summary>
    public static SoftwareBitmap?[] Crop(SoftwareBitmap source, IReadOnlyList<Rectangle> rectsPx)
    {
        var crops = new SoftwareBitmap?[rectsPx.Count];
        if (source.BitmapPixelFormat != BitmapPixelFormat.Bgra8) return crops;
        var bounds = new Rectangle(0, 0, source.PixelWidth, source.PixelHeight);

        // BGRA8 rows have no padding: the stride is the width times 4.
        var sourceStride = source.PixelWidth * 4;
        var pixels = new byte[checked(sourceStride * source.PixelHeight)];
        source.CopyToBuffer(pixels.AsBuffer());
        for (var i = 0; i < crops.Length; i++)
        {
            var rect = Rectangle.Intersect(rectsPx[i], bounds);
            if (rect.Width <= 0 || rect.Height <= 0) continue;
            var stride = rect.Width * 4;
            var cropped = new byte[checked(stride * rect.Height)];
            for (var row = 0; row < rect.Height; row++)
            {
                Buffer.BlockCopy(pixels, (rect.Y + row) * sourceStride + rect.X * 4, cropped, row * stride, stride);
            }
            crops[i] = SoftwareBitmap.CreateCopyFromBuffer(
                cropped.AsBuffer(), BitmapPixelFormat.Bgra8, rect.Width, rect.Height, source.BitmapAlphaMode);
        }
        return crops;
    }
}
