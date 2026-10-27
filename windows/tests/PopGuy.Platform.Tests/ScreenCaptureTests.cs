using System.Drawing;
using System.Runtime.InteropServices.WindowsRuntime;
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

    // Crop works on a made-up bitmap: each pixel encodes its own position (B = x, G = y), so a crop's pixels show where
    // they were cut from.
    [Fact]
    public void CropsEachRectFromTheSourcesPixels()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("SoftwareBitmap needs Windows.");
        const int width = 10, height = 7;
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var i = (y * width + x) * 4;
                (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = ((byte)x, (byte)y, 0x7F, 0xFF);
            }
        }
        using var source = SoftwareBitmap.CreateCopyFromBuffer(
            pixels.AsBuffer(), BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Premultiplied);

        // Inside; partly outside on the left and top, and on the right and bottom (only the part inside is copied); fully
        // outside.
        var crops = ScreenCapture.Crop(source, [
            new Rectangle(3, 2, 4, 3), new Rectangle(-2, -1, 5, 4), new Rectangle(8, 5, 6, 6), new Rectangle(width, 0, 3, 3),
        ]);

        AssertCrop(crops[0], new Rectangle(3, 2, 4, 3));
        AssertCrop(crops[1], new Rectangle(0, 0, 3, 3));
        AssertCrop(crops[2], new Rectangle(8, 5, 2, 2));
        Assert.Null(crops[3]);
        foreach (var crop in crops) crop?.Dispose();
    }

    /// <summary>The crop is <paramref name="expected"/>'s size, BGRA8, and every pixel is the source's at its position.</summary>
    private static void AssertCrop(SoftwareBitmap? crop, Rectangle expected)
    {
        Assert.NotNull(crop);
        Assert.Equal((expected.Width, expected.Height), (crop.PixelWidth, crop.PixelHeight));
        Assert.Equal(BitmapPixelFormat.Bgra8, crop.BitmapPixelFormat);
        var pixels = new byte[expected.Width * expected.Height * 4];
        crop.CopyToBuffer(pixels.AsBuffer());
        for (var y = 0; y < expected.Height; y++)
        {
            for (var x = 0; x < expected.Width; x++)
            {
                var i = (y * expected.Width + x) * 4;
                Assert.Equal(((byte)(expected.X + x), (byte)(expected.Y + y), (byte)0x7F, (byte)0xFF),
                    (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]));
            }
        }
    }
}
