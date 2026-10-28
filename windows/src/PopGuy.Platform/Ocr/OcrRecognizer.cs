using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace PopGuy.Platform.Ocr;

/// <summary>Why <see cref="OcrRecognizer"/> could not read a bitmap.</summary>
public enum OcrFailure
{
    /// <summary>No installed language has text recognition.</summary>
    NoLanguage,

    /// <summary>The engine (or the downscale before it) threw.</summary>
    Failed,
}

/// <summary>
/// A recognition result: <see cref="Text"/> (empty when the region has no text, which the caller reports), or a
/// <see cref="Failure"/> with a user-facing <see cref="Message"/>.
/// </summary>
public sealed record OcrOutcome(string Text, OcrFailure? Failure = null, string? Message = null)
{
    public bool Succeeded => Failure is null;
}

/// <summary>
/// Text recognition on a captured region (macOS OCRTextRecognizer) through the Windows OCR engine (WinRT). The engine
/// uses the user's profile languages. Expected failures come back as an <see cref="OcrOutcome"/>, never thrown.
/// UNTRUSTED DATA: the recognized text is never logged or put in an error.
/// </summary>
public static class OcrRecognizer
{
    internal const string NoLanguageMessage =
        "No OCR language is installed. Add a language with text recognition in Windows Settings → Time & language → Language & region.";

    internal const string FailedMessage = "Text recognition failed.";

    /// <summary>
    /// Recognizes the text of <paramref name="bitmap"/> on the thread pool, the lines joined by "\n" top-to-bottom then
    /// left-to-right, trimmed. The caller still owns (and disposes) the bitmap.
    /// </summary>
    public static Task<OcrOutcome> RecognizeAsync(SoftwareBitmap bitmap) => Task.Run(() => RecognizeOffThreadAsync(bitmap));

    private static async Task<OcrOutcome> RecognizeOffThreadAsync(SoftwareBitmap bitmap)
    {
        // A language pack with OCR that is not a profile language still beats "none installed".
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? (OcrEngine.AvailableRecognizerLanguages.FirstOrDefault() is { } language
                ? OcrEngine.TryCreateFromLanguage(language)
                : null);
        if (engine is null) return new("", OcrFailure.NoLanguage, NoLanguageMessage);
        try
        {
            using var fitted = await FitAsync(bitmap);
            var result = await engine.RecognizeAsync(fitted ?? bitmap);
            return new(JoinLines(result.Lines));
        }
        catch (Exception)
        {
            return new("", OcrFailure.Failed, FailedMessage);
        }
    }

    /// <summary>
    /// The engine refuses an image wider or taller than <see cref="OcrEngine.MaxImageDimension"/>, larger than one
    /// monitor today, so this is defensive for a region spanning several. Scaled down keeping the aspect ratio rather
    /// than cropped: every line of the region stays, only smaller. A new bitmap (the caller's keeps its size for the
    /// thumbnail); null when the bitmap already fits.
    /// </summary>
    private static async Task<SoftwareBitmap?> FitAsync(SoftwareBitmap bitmap)
    {
        var max = OcrEngine.MaxImageDimension;
        var (width, height) = ((uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight);
        if (width <= max && height <= max) return null;
        var scale = Math.Min((double)max / width, (double)max / height);

        // The WinRT imaging API scales only while encoding or decoding: round-trip through an in-memory PNG.
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var transform = new BitmapTransform
        {
            ScaledWidth = Math.Clamp((uint)(width * scale), 1, max),
            ScaledHeight = Math.Clamp((uint)(height * scale), 1, max),
            InterpolationMode = BitmapInterpolationMode.Fant,
        };
        return await decoder.GetSoftwareBitmapAsync(
            BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
            ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
    }

    /// <summary>
    /// macOS's order: by the line's bottom edge (Vision sorts its bottom-left-origin boxes by descending y), then by its
    /// left edge. The engine mostly returns reading order already; this keeps the two platforms' text the same.
    /// </summary>
    private static string JoinLines(IReadOnlyList<OcrLine> lines)
    {
        var ordered = lines
            .Where(line => line.Words.Count > 0)
            .Select(line => (line.Text, Bottom: line.Words.Max(w => w.BoundingRect.Y + w.BoundingRect.Height),
                Left: line.Words.Min(w => w.BoundingRect.X)))
            .OrderBy(line => line.Bottom)
            .ThenBy(line => line.Left)
            .Select(line => line.Text);
        return string.Join("\n", ordered).Trim();
    }
}
