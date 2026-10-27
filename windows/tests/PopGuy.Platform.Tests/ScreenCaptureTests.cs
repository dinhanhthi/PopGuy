using System.Drawing;
using PopGuy.Platform.Ocr;
using Windows.Graphics.Imaging;

namespace PopGuy.Platform.Tests;

// The capture's size and format only: what the pixels hold (and what OCR reads in them) depends on the machine.
public sealed class ScreenCaptureTests
{
    [Fact]
    public void CapturesTheRegionAsOpaqueBgra8()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The screen capture needs Windows.");
        var screen = ScreenCapture.VirtualScreen();

        using var bitmap = ScreenCapture.Capture(new Rectangle(screen.X, screen.Y, 8, 6));

        Assert.NotNull(bitmap);
        Assert.Equal((8, 6), (bitmap.PixelWidth, bitmap.PixelHeight));
        Assert.Equal(BitmapPixelFormat.Bgra8, bitmap.BitmapPixelFormat);
    }

    [Fact]
    public void KeepsOnlyThePartOnTheVirtualScreen()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The screen capture needs Windows.");
        var screen = ScreenCapture.VirtualScreen();

        using var bitmap = ScreenCapture.Capture(new Rectangle(screen.Right - 4, screen.Bottom - 3, 10, 10));

        Assert.NotNull(bitmap);
        Assert.Equal((4, 3), (bitmap.PixelWidth, bitmap.PixelHeight));
    }

    [Fact]
    public void RefusesAnEmptyRegionOrOneOffTheScreen()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The screen capture needs Windows.");
        var screen = ScreenCapture.VirtualScreen();

        Assert.Null(ScreenCapture.Capture(new Rectangle(screen.X, screen.Y, 0, 5)));
        Assert.Null(ScreenCapture.Capture(new Rectangle(screen.Right, screen.Y, 10, 10)));
    }
}
