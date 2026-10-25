using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Accessibility;

namespace PopGuy.Platform.Capture;

/// <summary>How a UI Automation read of the focused selection ended.</summary>
public enum UiaCaptureStatus
{
    /// <summary>The focused element has a non-empty text selection.</summary>
    Captured,

    /// <summary>The focused element supports text selection, but nothing (or only white space) is selected.</summary>
    Empty,

    /// <summary>
    /// No text pattern, or the read failed outright (<see cref="UiaSelection.ReadFailed"/>: no focused element, a UI
    /// Automation error, or no answer within the timeout).
    /// </summary>
    Unavailable,

    /// <summary>
    /// The focused element is a password field (UI Automation IsPassword): nothing was read, and no fallback may copy
    /// from it (<see cref="CaptureFallbackPolicy"/>).
    /// </summary>
    PasswordField,
}

/// <summary>The focused element's selection, read through UI Automation.</summary>
/// <param name="Status">How the read ended; <paramref name="Text"/> is empty unless <see cref="UiaCaptureStatus.Captured"/>.</param>
/// <param name="Text">The selected text (ranges joined with new lines).</param>
/// <param name="IsEditable">The element takes typing, so a paste can replace the selection.</param>
/// <param name="SelectionRects">The selection's bounding rectangles in screen pixels (one per line), possibly empty.</param>
/// <param name="FocusedElementHint">
/// The focused element's AutomationId and ClassName (never its text), joined with a space, for
/// <see cref="CaptureFallbackPolicy"/> (an xterm.js terminal shows "xterm" there); null when unknown (both empty, or
/// the read failed before it), and kept on every result read after it, a failed one too.
/// </param>
/// <param name="IsTruncated">The selection was longer than 1,000,000 characters: <paramref name="Text"/> holds the first million.</param>
/// <param name="ReadFailed">
/// The read failed outright (always with <see cref="UiaCaptureStatus.Unavailable"/>): no focused element, a UI
/// Automation error (the hint lookup or the selection read included), or no answer within the timeout. Unlike a
/// missing text pattern, nothing is known about the focused element, so <see cref="CaptureFallbackPolicy"/> refuses.
/// </param>
public sealed record UiaSelection(
    UiaCaptureStatus Status,
    string Text,
    bool IsEditable,
    IReadOnlyList<Rectangle> SelectionRects,
    string? FocusedElementHint = null,
    bool IsTruncated = false,
    bool ReadFailed = false)
{
    internal static readonly UiaSelection Unavailable = new(UiaCaptureStatus.Unavailable, "", false, []);
    internal static readonly UiaSelection Failed = Unavailable with { ReadFailed = true };
    internal static readonly UiaSelection PasswordField = new(UiaCaptureStatus.PasswordField, "", false, []);
}

/// <summary>
/// Reads the focused element's text selection through UI Automation (CUIAutomation8 → focused element → text pattern).
/// The primary capture path; the Ctrl+C fallback (<see cref="ClipboardTransaction"/>) covers apps without a text
/// pattern, when <see cref="CaptureFallbackPolicy"/> allows it. Password fields are never read.
/// </summary>
public static class UiaSelectionReader
{
    /// <summary>UI Automation blocks while the target app is hung; the read gives up after this.</summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromMilliseconds(1500);

    /// <summary>The most text a read returns (all ranges together); a longer selection is cut and marked truncated.</summary>
    internal const int MaxTextLength = 1_000_000;

    /// <summary>A first read that comes back unavailable is tried once more after this.</summary>
    private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(150);

    /// <summary>
    /// Reads the focused selection on a dedicated MTA thread and waits for it up to 1.5 s (then
    /// <see cref="UiaCaptureStatus.Unavailable"/> with <see cref="UiaSelection.ReadFailed"/>; the abandoned thread ends
    /// whenever UI Automation returns). A first read that is <see cref="UiaCaptureStatus.Unavailable"/> (failed or not)
    /// is tried once more 150 ms later, within the same 1.5 s:
    /// Chromium apps (Chrome, Edge, Electron) turn their accessibility tree on only when a UI Automation client first
    /// asks, so the first read after launch finds no text pattern. Blocks the caller for 1.5 s at most: call it off the
    /// UI thread.
    /// </summary>
    public static UiaSelection ReadFocused()
    {
        UiaSelection? result = null;
        var watch = Stopwatch.StartNew();
        var thread = new Thread(() =>
        {
            var first = ReadCore();
            if (first.Status != UiaCaptureStatus.Unavailable || watch.Elapsed + RetryDelay >= Timeout)
            {
                result = first;
                return;
            }
            Thread.Sleep(RetryDelay);
            result = ReadCore();
        }) { IsBackground = true, Name = "PopGuy UIA read" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        return thread.Join(Timeout) ? result ?? UiaSelection.Failed : UiaSelection.Failed;
    }

    private static UiaSelection ReadCore()
    {
        IUIAutomation? automation = null;
        IUIAutomationElement? element = null;
        IUIAutomationTextPattern? textPattern = null;
        IUIAutomationTextRangeArray? ranges = null;
        // Read before the selection, and kept on every result after it (the failed ones too): the hint is what tells an
        // editor's integrated terminal apart (CaptureFallbackPolicy).
        string? hint = null;
        try
        {
            automation = (IUIAutomation)new CUIAutomation8();
            element = automation.GetFocusedElement();
            if (element is null) return UiaSelection.Failed;
            // Before any text is read: a password field's text never leaves it.
            if (element.CurrentIsPassword) return UiaSelection.PasswordField;
            hint = FocusedElementHintOf(element);
            textPattern = element.GetCurrentPattern(UIA_PATTERN_ID.UIA_TextPatternId) as IUIAutomationTextPattern;
            if (textPattern is null) return UiaSelection.Unavailable with { FocusedElementHint = hint };

            ranges = textPattern.GetSelection();
            var count = ranges?.Length ?? 0;
            var texts = new List<string>(count);
            var rects = new List<Rectangle>();
            bool? rangeReadOnly = null;
            var remaining = MaxTextLength;
            var truncated = false;
            for (var i = 0; i < count; i++)
            {
                if (remaining <= 0)
                {
                    truncated = true;
                    break;
                }
                var range = ranges!.GetElement(i);
                try
                {
                    // One character more than the budget: tells a selection of exactly the budget from a longer one.
                    var rangeText = ReadText(range, remaining + 1);
                    if (rangeText.Length > remaining)
                    {
                        rangeText = rangeText[..remaining];
                        truncated = true;
                    }
                    remaining -= rangeText.Length;
                    texts.Add(rangeText);
                    ReadRects(range, rects);
                    rangeReadOnly ??= IsReadOnly(range);
                }
                finally
                {
                    Release(range);
                }
            }

            var text = string.Join("\n", texts);
            var isEditable = IsEditable(element, rangeReadOnly ?? false);
            return string.IsNullOrWhiteSpace(text)
                ? new UiaSelection(UiaCaptureStatus.Empty, "", isEditable, rects, hint)
                : new UiaSelection(UiaCaptureStatus.Captured, text, isEditable, rects, hint, truncated);
        }
        catch (Exception)
        {
            // COM errors map to many exception types (COMException, UnauthorizedAccessException, ...), and an
            // exception escaping this background thread would end the process. A failed read, not a missing pattern.
            return UiaSelection.Failed with { FocusedElementHint = hint };
        }
        finally
        {
            Release(ranges);
            Release(textPattern);
            Release(element);
            Release(automation);
        }
    }

    /// <summary>
    /// A value pattern that is not read-only, or an Edit or Document control that is focusable and not read-only.
    /// False if UI Automation fails here: the selection read already succeeded.
    /// </summary>
    private static bool IsEditable(IUIAutomationElement element, bool rangeReadOnly)
    {
        try
        {
            return IsEditableCore(element, rangeReadOnly);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool IsEditableCore(IUIAutomationElement element, bool rangeReadOnly)
    {
        if (element.GetCurrentPattern(UIA_PATTERN_ID.UIA_ValuePatternId) is IUIAutomationValuePattern valuePattern)
        {
            try
            {
                if (!valuePattern.CurrentIsReadOnly) return true;
            }
            finally
            {
                Release(valuePattern);
            }
        }
        var controlType = element.CurrentControlType;
        return controlType is UIA_CONTROLTYPE_ID.UIA_EditControlTypeId or UIA_CONTROLTYPE_ID.UIA_DocumentControlTypeId
            && element.CurrentIsKeyboardFocusable
            && !rangeReadOnly;
    }

    /// <summary>
    /// Only an explicit true counts: not-supported and mixed values come back as sentinel objects. False if UI
    /// Automation fails here.
    /// </summary>
    private static bool IsReadOnly(IUIAutomationTextRange range)
    {
        try
        {
            return range.GetAttributeValue(UIA_TEXTATTRIBUTE_ID.UIA_IsReadOnlyAttributeId) is true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// The focused element's AutomationId and ClassName joined with a space (identifiers, never text), or null when
    /// both are empty. A UI Automation error here fails the whole read (<see cref="UiaSelection.ReadFailed"/>): without
    /// the hint, an integrated terminal cannot be told apart.
    /// </summary>
    private static string? FocusedElementHintOf(IUIAutomationElement element)
    {
        var hint = $"{ReadBstr(element.CurrentAutomationId)} {ReadBstr(element.CurrentClassName)}".Trim();
        return hint.Length > 0 ? hint : null;
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

    /// <summary>The range's text, at most <paramref name="maxLength"/> characters.</summary>
    private static string ReadText(IUIAutomationTextRange range, int maxLength) => ReadBstr(range.GetText(maxLength));

    /// <summary>Appends the range's rectangles: a SAFEARRAY of doubles, four per rectangle (left, top, width, height).</summary>
    private static unsafe void ReadRects(IUIAutomationTextRange range, List<Rectangle> rects)
    {
        var array = range.GetBoundingRectangles();
        if (array is null) return;
        try
        {
            if (array->cDims != 1 || array->cbElements != sizeof(double)) return;
            var values = new ReadOnlySpan<double>(array->pvData, (int)array->rgsabound[0].cElements);
            for (var i = 0; i + 3 < values.Length; i += 4)
            {
                rects.Add(new Rectangle(
                    (int)Math.Round(values[i]), (int)Math.Round(values[i + 1]),
                    (int)Math.Round(values[i + 2]), (int)Math.Round(values[i + 3])));
            }
        }
        finally
        {
            PInvoke.SafeArrayDestroy(array);
        }
    }

    private static void Release(object? comObject)
    {
        if (comObject is not null && Marshal.IsComObject(comObject)) Marshal.ReleaseComObject(comObject);
    }
}
