using System.ComponentModel;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using PopGuy.Platform.Input;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.System.Memory;
using Windows.Win32.System.Ole;

namespace PopGuy.Platform.Capture;

/// <summary>
/// A copy of the clipboard's contents: every HGLOBAL format's bytes, plus a copy of the enhanced metafile. Owns that
/// metafile copy and the bytes, so dispose it (which also zeroes the bytes). Only a snapshot that is
/// <see cref="IsComplete"/> is ever restored: one over 64 MB (<see cref="IsTooLarge"/>, which holds no data), with a
/// format left out, or with its data omitted would bring the clipboard back only partly.
/// </summary>
public sealed class ClipboardSnapshot : IDisposable
{
    private readonly IReadOnlyList<(uint Format, byte[] Data)> _formats;
    private readonly Lock _gate = new();
    private HENHMETAFILE _enhMetaFile;
    private bool _disposed;

    internal ClipboardSnapshot(
        uint sequenceNumber,
        IReadOnlyList<(uint Format, byte[] Data)> formats,
        HENHMETAFILE enhMetaFile,
        long totalBytes,
        bool isTooLarge,
        int skippedFormatCount,
        bool isExcludedFromMonitoring,
        bool isDataOmitted)
    {
        SequenceNumber = sequenceNumber;
        _formats = formats;
        _enhMetaFile = enhMetaFile;
        TotalBytes = totalBytes;
        IsTooLarge = isTooLarge;
        SkippedFormatCount = skippedFormatCount;
        IsExcludedFromMonitoring = isExcludedFromMonitoring;
        IsDataOmitted = isDataOmitted;
    }

    /// <summary>The clipboard sequence number the contents had (read while the clipboard was open).</summary>
    public uint SequenceNumber { get; }

    /// <summary>The bytes of the HGLOBAL formats (counted up to the 64 MB limit when <see cref="IsTooLarge"/>).</summary>
    public long TotalBytes { get; }

    /// <summary>The formats went over 64 MB in total: the snapshot holds no data and is never restored.</summary>
    public bool IsTooLarge { get; }

    /// <summary>
    /// Formats with data that the snapshot left out: over 16 MB, or unreadable (the memory could not be locked). A
    /// restore would lose them, so a snapshot with any is never restored. Not counted: the formats Windows synthesizes
    /// and OLE's own (never needed back).
    /// </summary>
    public int SkippedFormatCount { get; }

    /// <summary>
    /// The clipboard's owner asked clipboard monitors to leave it alone: ExcludeClipboardContentFromMonitorProcessing
    /// was present, or CanIncludeInClipboardHistory was 0 (password managers set these on secrets).
    /// </summary>
    public bool IsExcludedFromMonitoring { get; }

    /// <summary>The data was not copied, because the contents are <see cref="IsExcludedFromMonitoring"/> (cache snapshots only).</summary>
    public bool IsDataOmitted { get; }

    /// <summary>A restore brings back everything the clipboard held: not too large, no format left out, data kept.</summary>
    public bool IsComplete => !IsTooLarge && SkippedFormatCount == 0 && !IsDataOmitted;

    /// <summary>The number of formats held.</summary>
    public int FormatCount => _formats.Count + (_enhMetaFile.IsNull ? 0 : 1);

    /// <summary>Zeroes the bytes and deletes the metafile copy; a later restore returns false. Any thread.</summary>
    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            foreach (var (_, data) in _formats) Array.Clear(data);
            if (!_enhMetaFile.IsNull) PInvoke.DeleteEnhMetaFile(_enhMetaFile);
            _enhMetaFile = default;
        }
    }

    /// <summary>
    /// Empties the clipboard (which the caller has opened) and sets every held format, but only once it is sure it
    /// can: a snapshot disposed meanwhile (an eviction racing a restore) or not <see cref="IsComplete"/> leaves the
    /// clipboard untouched. False then, or if a format was refused; the clipboard is then emptied again, never left
    /// half-restored (matching <see cref="ClipboardGuard.WriteText(string, bool, ClipboardSnapshot?)"/>).
    /// </summary>
    internal bool EmptyAndSetFormats()
    {
        lock (_gate)
        {
            if (_disposed || !IsComplete) return false;
            if (!PInvoke.EmptyClipboard()) return false;
            if (SetFormatsLocked()) return true;
            // Still open: nobody saw the partial restore.
            PInvoke.EmptyClipboard();
            return false;
        }
    }

    /// <summary>Sets every held format on the clipboard, which the caller has opened and emptied (only if <see cref="IsComplete"/>).</summary>
    internal bool SetFormats()
    {
        lock (_gate)
        {
            if (_disposed || !IsComplete) return false;
            return SetFormatsLocked();
        }
    }

    private unsafe bool SetFormatsLocked()
    {
        var ok = true;
        foreach (var (format, data) in _formats) ok &= ClipboardGuard.SetBytes(format, data);
        if (!_enhMetaFile.IsNull)
        {
            // The clipboard takes ownership of what it is given: hand it a fresh copy, keep ours for later restores.
            var copy = PInvoke.CopyEnhMetaFile(_enhMetaFile, default(PCWSTR));
            if (copy.IsNull || PInvoke.SetClipboardData((uint)CLIPBOARD_FORMAT.CF_ENHMETAFILE, new HANDLE(copy.Value)).IsNull)
            {
                if (!copy.IsNull) PInvoke.DeleteEnhMetaFile(copy);
                ok = false;
            }
        }
        return ok;
    }
}

/// <summary>How a conditional clipboard restore ended.</summary>
public enum ClipboardRestoreResult
{
    /// <summary>The snapshot is back on the clipboard.</summary>
    Restored,

    /// <summary>Nothing to do: the clipboard still holds the snapshot's contents (nobody changed it).</summary>
    Unchanged,

    /// <summary>
    /// Not restored: someone else changed the clipboard after PopGuy's own change (the user copied something new), and
    /// their contents are never overwritten.
    /// </summary>
    SkippedClipboardChanged,

    /// <summary>
    /// The snapshot cannot be restored: not <see cref="ClipboardSnapshot.IsComplete"/> (too large, a format left out,
    /// data omitted), so a restore would bring the clipboard back only partly.
    /// </summary>
    NotRestorable,

    /// <summary>The clipboard could not be opened or a format was refused.</summary>
    Failed,
}

/// <summary>
/// The clipboard around a synthetic copy or paste, so the user's clipboard is never left clobbered. Use
/// <see cref="ClipboardTransaction"/>: it takes the <see cref="Snapshot"/> first and refuses to start when the
/// clipboard could not be saved completely, writes, and restores only what PopGuy itself changed. Opening the
/// clipboard tries 10 times, 10 ms apart, since other apps hold it briefly. Any thread; every call opens and closes
/// the clipboard itself.
/// </summary>
public static class ClipboardGuard
{
    /// <summary>A snapshot whose HGLOBAL formats exceed this in total is stored as too large.</summary>
    internal const long MaxSnapshotBytes = 64L * 1024 * 1024;

    /// <summary>A single HGLOBAL format over this is left out of the snapshot (never copied), and <see cref="ReadText"/> refuses text over it.</summary>
    internal const long MaxFormatBytes = 16L * 1024 * 1024;

    /// <summary>
    /// The registered formats OLE puts on the clipboard for its own bookkeeping. "DataObject" and "Ole Private Data"
    /// point at the owner's IDataObject: copied back after that owner is gone, they make OLE readers (OleGetClipboard,
    /// so WinForms, WPF, WinUI and Office apps) talk to a dead object and see an empty clipboard or hang. Left out, OLE
    /// builds its data object from the plain Win32 formats instead.
    /// </summary>
    private static readonly string[] OleInternalFormatNames = ["DataObject", "Ole Private Data", "OleClipboardPersistOnFlush"];

    /// <summary>Registered format ids are fixed for the session: the verdict per id, so a snapshot looks each name up once.</summary>
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<uint, bool> OleInternalFormats = new();

    /// <summary>Registered format ids start here (lower ids are the standard and private formats).</summary>
    private const uint FirstRegisteredFormat = 0xC000;

    /// <summary>Longer than any name in <see cref="OleInternalFormatNames"/>, so a longer name never matches.</summary>
    private const int FormatNameCapacity = 64;

    private const int OpenAttempts = 10;
    private static readonly TimeSpan OpenRetryDelay = TimeSpan.FromMilliseconds(10);
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(10);
    private static readonly TimeSpan DefaultWaitTimeout = TimeSpan.FromMilliseconds(500);

    /// <summary>The clipboard's sequence number, which every change increments.</summary>
    public static uint SequenceNumber => PInvoke.GetClipboardSequenceNumber();

    /// <summary>
    /// Copies the clipboard's contents. Skips CF_BITMAP (Windows synthesizes it from CF_DIB), CF_METAFILEPICT
    /// (synthesized from CF_ENHMETAFILE), CF_PALETTE, owner-display, private and GDI-object formats (none are HGLOBAL
    /// data), OLE's own registered formats (<see cref="IsOleInternal"/>), and any format over 16 MB (counted in
    /// <see cref="ClipboardSnapshot.SkippedFormatCount"/>). Each format's size is checked before its bytes are copied;
    /// one that would take the total over 64 MB stops the copy and makes the snapshot
    /// <see cref="ClipboardSnapshot.IsTooLarge"/>. Null if the clipboard could not be opened. The clipboard stays open
    /// only while the formats are read and copied.
    /// <para>
    /// The rule for every caller: a null snapshot, or one that is not <see cref="ClipboardSnapshot.IsComplete"/>
    /// (too large, formats left out), cannot bring the user's clipboard back. Stop BEFORE anything writes to the
    /// clipboard: no <see cref="WriteText"/>, no synthetic copy (Ctrl+Insert). <see cref="ClipboardTransaction.TryBegin"/> enforces
    /// this order; use it rather than calling this directly.
    /// </para>
    /// </summary>
    public static ClipboardSnapshot? Snapshot() => Snapshot(omitExcludedData: false);

    /// <summary>
    /// <see cref="Snapshot()"/>; with <paramref name="omitExcludedData"/>, contents whose owner excluded them from
    /// clipboard monitors are not copied at all (<see cref="ClipboardSnapshot.IsDataOmitted"/>).
    /// </summary>
    internal static unsafe ClipboardSnapshot? Snapshot(bool omitExcludedData)
    {
        if (!Open()) return null;
        var formats = new List<(uint Format, byte[] Data)>();
        HENHMETAFILE enhMetaFile = default;
        long total = 0;
        var tooLarge = false;
        var skipped = 0;
        var excluded = false;
        uint sequenceNumber;
        try
        {
            sequenceNumber = PInvoke.GetClipboardSequenceNumber();
            // First the format list only (no data copied): the exclusion markers may come after the data.
            var available = new List<uint>();
            for (var format = PInvoke.EnumClipboardFormats(0); format != 0; format = PInvoke.EnumClipboardFormats(format))
            {
                available.Add(format);
            }
            excluded = IsExcludedFromMonitoring(available);
            if (excluded && omitExcludedData)
            {
                return new ClipboardSnapshot(sequenceNumber, [], default, 0, isTooLarge: false, 0, isExcludedFromMonitoring: true, isDataOmitted: true);
            }

            foreach (var format in available)
            {
                if (format == (uint)CLIPBOARD_FORMAT.CF_ENHMETAFILE)
                {
                    var metafile = PInvoke.GetClipboardData(format);
                    if (!metafile.IsNull) enhMetaFile = PInvoke.CopyEnhMetaFile(new HENHMETAFILE(metafile.Value), default(PCWSTR));
                    if (!metafile.IsNull && enhMetaFile.IsNull) skipped++;
                    continue;
                }
                if (IsSkipped(format) || IsOleInternal(format)) continue;

                // Null: a delayed render the owner refused (there is no data to lose).
                var handle = PInvoke.GetClipboardData(format);
                if (handle.IsNull) continue;
                var memory = new HGLOBAL(handle.Value);
                var size = (long)PInvoke.GlobalSize(memory);
                if (size > MaxFormatBytes)
                {
                    skipped++;
                    continue;
                }
                if (total + size > MaxSnapshotBytes)
                {
                    total += size;
                    tooLarge = true;
                    break;
                }
                total += size;
                var source = PInvoke.GlobalLock(memory);
                if (source is null)
                {
                    skipped++;
                    continue;
                }
                try
                {
                    formats.Add((format, new ReadOnlySpan<byte>(source, checked((int)size)).ToArray()));
                }
                finally
                {
                    PInvoke.GlobalUnlock(memory);
                }
            }
        }
        catch
        {
            Discard(formats, enhMetaFile);
            throw;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }

        if (tooLarge)
        {
            Discard(formats, enhMetaFile);
            formats.Clear();
            enhMetaFile = default;
        }
        return new ClipboardSnapshot(sequenceNumber, formats, enhMetaFile, total, tooLarge, skipped, excluded, isDataOmitted: false);
    }

    /// <summary>
    /// Replaces the clipboard's contents with <paramref name="snapshot"/>, whatever the clipboard holds now. False if
    /// the clipboard could not be opened, the snapshot is not <see cref="ClipboardSnapshot.IsComplete"/> or is
    /// disposed, or a format was refused (the clipboard is then left empty, never half-restored).
    /// After a delay, prefer <see cref="RestoreIfUnchanged"/> (or <see cref="ClipboardTransaction.Restore"/>): a change
    /// made meanwhile by someone else must not be overwritten.
    /// </summary>
    public static bool Restore(ClipboardSnapshot snapshot)
    {
        if (!snapshot.IsComplete || !Open()) return false;
        try
        {
            return snapshot.EmptyAndSetFormats();
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>
    /// Restores <paramref name="snapshot"/> only if the clipboard's sequence number is still
    /// <paramref name="expectedSequence"/> (the contents PopGuy caused), checked with the clipboard open so nobody can
    /// change it in between. Otherwise <see cref="ClipboardRestoreResult.SkippedClipboardChanged"/>, or
    /// <see cref="ClipboardRestoreResult.Unchanged"/> when the clipboard holds the snapshot's own contents.
    /// <see cref="ClipboardRestoreResult.NotRestorable"/> (clipboard untouched) when the snapshot is not
    /// <see cref="ClipboardSnapshot.IsComplete"/>; <see cref="ClipboardRestoreResult.Failed"/> when a format was
    /// refused (the clipboard is then left empty, never half-restored).
    /// </summary>
    public static ClipboardRestoreResult RestoreIfUnchanged(ClipboardSnapshot snapshot, uint expectedSequence)
    {
        if (!snapshot.IsComplete) return ClipboardRestoreResult.NotRestorable;
        if (!Open()) return ClipboardRestoreResult.Failed;
        try
        {
            var current = PInvoke.GetClipboardSequenceNumber();
            if (current == snapshot.SequenceNumber) return ClipboardRestoreResult.Unchanged;
            if (current != expectedSequence) return ClipboardRestoreResult.SkippedClipboardChanged;
            return snapshot.EmptyAndSetFormats() ? ClipboardRestoreResult.Restored : ClipboardRestoreResult.Failed;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>
    /// Puts <paramref name="text"/> on the clipboard as CF_UNICODETEXT. With <paramref name="excludeFromHistory"/>, also
    /// sets ExcludeClipboardContentFromMonitorProcessing, CanIncludeInClipboardHistory and CanUploadToCloudClipboard
    /// (each a DWORD 0), so clipboard history (Win+V), cloud sync and clipboard monitors skip it. False if the clipboard
    /// could not be opened or a format was refused; then it is never left half-written (text without its markers):
    /// it is emptied and, with <paramref name="restoreOnFailure"/>, given that snapshot back, else left empty.
    /// </summary>
    public static bool WriteText(string text, bool excludeFromHistory, ClipboardSnapshot? restoreOnFailure = null) =>
        WriteText(text, excludeFromHistory, restoreOnFailure, out _);

    /// <summary><see cref="WriteText(string, bool, ClipboardSnapshot?)"/>, plus the sequence number right after the write.</summary>
    internal static bool WriteText(string text, bool excludeFromHistory, ClipboardSnapshot? restoreOnFailure, out uint sequenceAfter)
    {
        sequenceAfter = 0;
        if (!Open()) return false;
        bool ok;
        try
        {
            ok = PInvoke.EmptyClipboard();
            // Two zero bytes more: the terminating null character.
            ok = ok && SetBytes((uint)CLIPBOARD_FORMAT.CF_UNICODETEXT, MemoryMarshal.AsBytes(text.AsSpan()), extraZeroBytes: sizeof(char));
            if (ok && excludeFromHistory)
            {
                // A real allocation even where the data does not matter: a null handle would mean a delayed render.
                ReadOnlySpan<byte> zero = [0, 0, 0, 0];
                ok &= SetBytes(RegisteredFormats.ExcludeFromMonitorProcessing, zero);
                ok &= SetBytes(RegisteredFormats.CanIncludeInClipboardHistory, zero);
                ok &= SetBytes(RegisteredFormats.CanUploadToCloudClipboard, zero);
            }
            if (!ok)
            {
                // Still open: nobody saw the partial write. Clipboard history reads it only once it is closed.
                PInvoke.EmptyClipboard();
                restoreOnFailure?.SetFormats();
            }
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
        // Read after closing: the write is complete then. Another app's change in between would be taken for ours.
        sequenceAfter = PInvoke.GetClipboardSequenceNumber();
        return ok;
    }

    /// <summary>
    /// The clipboard's text (CF_UNICODETEXT), or null if there is none, it is over 16 MB, or the clipboard could not be
    /// opened.
    /// </summary>
    public static unsafe string? ReadText()
    {
        if (!Open()) return null;
        try
        {
            var handle = PInvoke.GetClipboardData((uint)CLIPBOARD_FORMAT.CF_UNICODETEXT);
            if (handle.IsNull) return null;
            var memory = new HGLOBAL(handle.Value);
            var size = (long)PInvoke.GlobalSize(memory);
            if (size > MaxFormatBytes) return null;
            var source = (char*)PInvoke.GlobalLock(memory);
            if (source is null) return null;
            try
            {
                var chars = new ReadOnlySpan<char>(source, (int)(size / sizeof(char)));
                var end = chars.IndexOf('\0');
                return new string(end < 0 ? chars : chars[..end]);
            }
            finally
            {
                PInvoke.GlobalUnlock(memory);
            }
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>
    /// Waits until the clipboard's sequence number differs from <paramref name="sequenceBefore"/>, polling every 10 ms
    /// for up to <paramref name="timeout"/> (500 ms by default). True if it changed. Blocks the caller.
    /// </summary>
    public static bool WaitForChange(uint sequenceBefore, TimeSpan? timeout = null)
    {
        var limit = timeout ?? DefaultWaitTimeout;
        var watch = Stopwatch.StartNew();
        while (true)
        {
            if (PInvoke.GetClipboardSequenceNumber() != sequenceBefore) return true;
            if (watch.Elapsed >= limit) return false;
            Thread.Sleep(PollInterval);
        }
    }

    /// <summary>
    /// Copies <paramref name="data"/> (plus <paramref name="extraZeroBytes"/>) into a new HGLOBAL and sets it as
    /// <paramref name="format"/> on the open clipboard, which then owns it. False if refused.
    /// </summary>
    internal static unsafe bool SetBytes(uint format, ReadOnlySpan<byte> data, int extraZeroBytes = 0)
    {
        // At least one byte: a zero-byte moveable block is a discarded one, which cannot be locked.
        var size = Math.Max(data.Length + extraZeroBytes, 1);
        var memory = PInvoke.GlobalAlloc(GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE | GLOBAL_ALLOC_FLAGS.GMEM_ZEROINIT, (nuint)size);
        if (memory.IsNull) return false;
        var target = PInvoke.GlobalLock(memory);
        if (target is null)
        {
            PInvoke.GlobalFree(memory);
            return false;
        }
        data.CopyTo(new Span<byte>(target, size));
        PInvoke.GlobalUnlock(memory);
        if (PInvoke.SetClipboardData(format, new HANDLE(memory.Value)).IsNull)
        {
            PInvoke.GlobalFree(memory);
            return false;
        }
        return true;
    }

    /// <summary>Opens the clipboard (no owner window), trying 10 times, 10 ms apart.</summary>
    private static bool Open()
    {
        for (var attempt = 1; ; attempt++)
        {
            if (PInvoke.OpenClipboard(HWND.Null)) return true;
            if (attempt == OpenAttempts) return false;
            Thread.Sleep(OpenRetryDelay);
        }
    }

    /// <summary>Zeroes copied bytes and deletes a metafile copy that will not be handed to a snapshot.</summary>
    private static void Discard(List<(uint Format, byte[] Data)> formats, HENHMETAFILE enhMetaFile)
    {
        foreach (var (_, data) in formats) Array.Clear(data);
        if (!enhMetaFile.IsNull) PInvoke.DeleteEnhMetaFile(enhMetaFile);
    }

    /// <summary>
    /// ExcludeClipboardContentFromMonitorProcessing is present (any data), or CanIncludeInClipboardHistory holds a
    /// DWORD 0. The clipboard is open.
    /// </summary>
    private static unsafe bool IsExcludedFromMonitoring(List<uint> formats)
    {
        if (formats.Contains(RegisteredFormats.ExcludeFromMonitorProcessing)) return true;
        if (!formats.Contains(RegisteredFormats.CanIncludeInClipboardHistory)) return false;
        var handle = PInvoke.GetClipboardData(RegisteredFormats.CanIncludeInClipboardHistory);
        if (handle.IsNull) return false;
        var memory = new HGLOBAL(handle.Value);
        if (PInvoke.GlobalSize(memory) < sizeof(uint)) return false;
        var value = (uint*)PInvoke.GlobalLock(memory);
        if (value is null) return false;
        try
        {
            return *value == 0;
        }
        finally
        {
            PInvoke.GlobalUnlock(memory);
        }
    }

    /// <summary>Formats that are not HGLOBAL data, or that Windows synthesizes from another format.</summary>
    private static bool IsSkipped(uint format) =>
        format is (uint)CLIPBOARD_FORMAT.CF_BITMAP or (uint)CLIPBOARD_FORMAT.CF_METAFILEPICT or (uint)CLIPBOARD_FORMAT.CF_PALETTE
        || format is >= (uint)CLIPBOARD_FORMAT.CF_OWNERDISPLAY and <= (uint)CLIPBOARD_FORMAT.CF_DSPENHMETAFILE
        || format is >= (uint)CLIPBOARD_FORMAT.CF_PRIVATEFIRST and <= (uint)CLIPBOARD_FORMAT.CF_GDIOBJLAST;

    /// <summary>A registered format of OLE's own (<see cref="OleInternalFormatNames"/>), never part of a snapshot.</summary>
    private static bool IsOleInternal(uint format) =>
        format >= FirstRegisteredFormat && OleInternalFormats.GetOrAdd(format, static id =>
        {
            Span<char> buffer = stackalloc char[FormatNameCapacity];
            var length = PInvoke.GetClipboardFormatName(id, buffer);
            if (length <= 0) return false;
            var name = buffer[..length];
            foreach (var oleName in OleInternalFormatNames)
            {
                if (name.Equals(oleName, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        });

    /// <summary>The registered formats that keep text out of clipboard history and monitors.</summary>
    private static class RegisteredFormats
    {
        internal static readonly uint ExcludeFromMonitorProcessing = PInvoke.RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        internal static readonly uint CanIncludeInClipboardHistory = PInvoke.RegisterClipboardFormat("CanIncludeInClipboardHistory");
        internal static readonly uint CanUploadToCloudClipboard = PInvoke.RegisterClipboardFormat("CanUploadToCloudClipboard");
    }
}

/// <summary>
/// The safe order for any PopGuy change to the clipboard (a paste through it, a synthetic Ctrl+Insert copy):
/// <list type="number">
/// <item><see cref="TryBegin"/> takes the snapshot and refuses (nothing touched yet) when it is missing or not
/// <see cref="ClipboardSnapshot.IsComplete"/>: then do not write and do not send the synthetic copy.</item>
/// <item>Change the clipboard: <see cref="WriteText"/> (which records PopGuy's own write and, on failure, puts the
/// snapshot back at once), or a synthetic copy (Ctrl+Insert) followed by <see cref="MarkCurrentAsOwn"/> once the copy landed.</item>
/// <item><see cref="Restore"/> after the delay: it puts the snapshot back only if the clipboard still holds PopGuy's
/// change, never over a newer copy by the user.</item>
/// </list>
/// Dispose zeroes the snapshot; it never restores by itself. Any thread, one at a time.
/// </summary>
public sealed class ClipboardTransaction : IDisposable
{
    private readonly ClipboardSnapshot _snapshot;
    private uint? _ownSequence;

    private ClipboardTransaction(ClipboardSnapshot snapshot) => _snapshot = snapshot;

    /// <summary>The clipboard's sequence number when the transaction began.</summary>
    public uint SequenceBefore => _snapshot.SequenceNumber;

    /// <summary>The bytes saved (for logs).</summary>
    public long SavedBytes => _snapshot.TotalBytes;

    /// <summary>
    /// Snapshots the clipboard. False, with <paramref name="refusal"/> "clipboardBusy" (it could not be opened),
    /// "tooLarge" (over 64 MB) or "formatsSkipped" (a format over 16 MB or unreadable), when the user's clipboard
    /// could not be brought back: the caller must then leave the clipboard alone (no write, no synthetic Ctrl+Insert copy).
    /// </summary>
    public static bool TryBegin([NotNullWhen(true)] out ClipboardTransaction? transaction, [NotNullWhen(false)] out string? refusal)
    {
        transaction = null;
        var snapshot = ClipboardGuard.Snapshot();
        refusal = snapshot is null ? "clipboardBusy"
            : snapshot.IsTooLarge ? "tooLarge"
            : snapshot.SkippedFormatCount > 0 ? "formatsSkipped"
            : null;
        if (refusal is not null)
        {
            snapshot?.Dispose();
            return false;
        }
        transaction = new ClipboardTransaction(snapshot!);
        return true;
    }

    /// <summary>
    /// Writes <paramref name="text"/> (see <see cref="ClipboardGuard.WriteText(string, bool, ClipboardSnapshot?)"/>)
    /// and records the write as PopGuy's own. False if it failed; the snapshot is then already back (and
    /// <see cref="Restore"/> tries again if even that failed).
    /// </summary>
    public bool WriteText(string text, bool excludeFromHistory)
    {
        var ok = ClipboardGuard.WriteText(text, excludeFromHistory, _snapshot, out var sequenceAfter);
        _ownSequence = sequenceAfter;
        return ok;
    }

    /// <summary>
    /// Records the clipboard's current contents as PopGuy's own change (the copy its synthetic Ctrl+Insert asked the source
    /// app for), so <see cref="Restore"/> may replace them. Call it once the copy has settled: OLE apps write twice
    /// (their data object, then the flushed formats), and a restore after a later write would be skipped. A change by
    /// someone else before this call would be taken for PopGuy's.
    /// </summary>
    public void MarkCurrentAsOwn() => _ownSequence = ClipboardGuard.SequenceNumber;

    /// <summary>
    /// Puts the snapshot back if the clipboard still holds PopGuy's change: <see cref="ClipboardRestoreResult.Unchanged"/>
    /// when nothing changed, <see cref="ClipboardRestoreResult.SkippedClipboardChanged"/> when the clipboard changed
    /// but not (or no longer) by PopGuy.
    /// </summary>
    public ClipboardRestoreResult Restore()
    {
        if (_ownSequence is { } own) return ClipboardGuard.RestoreIfUnchanged(_snapshot, own);
        return ClipboardGuard.SequenceNumber == _snapshot.SequenceNumber
            ? ClipboardRestoreResult.Unchanged
            : ClipboardRestoreResult.SkippedClipboardChanged;
    }

    /// <summary>Zeroes and frees the snapshot. Does not restore.</summary>
    public void Dispose() => _snapshot.Dispose();
}

/// <summary>
/// Recent clipboard snapshots by sequence number, so the Ctrl+C+C chord can restore the user's clipboard from before the
/// app copied the selection. The low-level hook never opens the clipboard: it only records the sequence number on the
/// arming Ctrl+C key-down, which the caller passes to <see cref="MarkArming"/> and later <see cref="TryGetBefore"/>.
/// <para>
/// A clipboard format listener on its own message-only window and dedicated thread (never the hook thread, so a slow
/// or delayed-render snapshot cannot stall the hooks) posts each update's sequence number to a worker, which takes a
/// full snapshot once the burst is over: 150 ms after the last update (at most 1 s after the first), and only if the
/// sequence number is still the last one posted. Apps often change the clipboard twice in a row (an OLE app sets its
/// data object, then flushes it into real formats), and a snapshot in between would hold the clipboard open while the
/// app tries to open it again, which then fails. One snapshot is taken at creation, so the first chord after launch
/// can restore. A snapshot whose sequence number changed by the time the clipboard was closed is torn and dropped.
/// </para>
/// <para>
/// Retention (the cache holds what the user copied, so it keeps as little as the chord needs):
/// <list type="bullet">
/// <item>The clipboard's current contents: one entry, while they are current. The chord's arming tap can come any time
/// later, and the snapshot can only be taken when the clipboard changes.</item>
/// <item>Contents whose owner excluded them from clipboard monitors (ExcludeClipboardContentFromMonitorProcessing, or
/// CanIncludeInClipboardHistory 0: password managers) are never copied, and every other entry is dropped then (but the
/// one a pending arming needs). So a chord right after copying a password does not bring the password back: the user's
/// clipboard then holds the selection.</item>
/// <item>A replaced entry (no longer the clipboard's contents) is evicted 5 s after it was replaced, checked every
/// second, unless a pending arming needs it. An arming is pending from <see cref="MarkArming"/> until
/// <see cref="CompleteArming"/> (after the chord's restore) or for 5 s at most.</item>
/// <item>At most 4 entries. Evicted snapshots are disposed, which zeroes their bytes.</item>
/// </list>
/// </para>
/// </summary>
public sealed class ClipboardHistoryCache : IDisposable
{
    /// <summary>A replaced entry, and an arming, last this long.</summary>
    private static readonly TimeSpan MaxAge = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan EvictionInterval = TimeSpan.FromSeconds(1);
    private const int MaxEntries = 4;

    /// <summary>The snapshot waits until no update came for this long.</summary>
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(150);

    /// <summary>An app that changes the clipboard without a pause still gets snapshotted this long after the first update.</summary>
    private static readonly TimeSpan MaxDebounce = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan WorkerStopTimeout = TimeSpan.FromSeconds(2);

    private readonly Action<string>? _log;
    private readonly Channel<uint> _updates = Channel.CreateUnbounded<uint>(new UnboundedChannelOptions { SingleReader = true });

    /// <summary>Oldest first, so the last is the clipboard's current contents (unless replaced). Guarded by itself.</summary>
    private readonly List<Entry> _entries = [];
    private readonly Task _worker;
    private readonly MessageWindow _window;
    private readonly Timer _evictionTimer;

    /// <summary>The pending arming sequence number, or -1 when none. Guarded by <see cref="_entries"/>.</summary>
    private long _arming = -1;

    /// <summary>When <see cref="_arming"/> was marked (Stopwatch timestamp). Guarded by <see cref="_entries"/>.</summary>
    private long _armedAt;
    private bool _disposed;

    /// <summary>
    /// Starts the listener thread and the worker, and queues the first snapshot. Throws
    /// <see cref="Win32Exception"/> if Windows refuses the window or the listener.
    /// </summary>
    /// <param name="log">Gets failures and notable drops (torn, too large, excluded, clipboard busy).</param>
    public ClipboardHistoryCache(Action<string>? log = null)
    {
        _log = log;
        _worker = Task.Run(ProcessUpdatesAsync);
        try
        {
            _window = MessageWindow.StartOnNewThread("PopGuy clipboard listener", log, window =>
            {
                window.AddHandler(PInvoke.WM_CLIPBOARDUPDATE, OnClipboardUpdate);
                if (!PInvoke.AddClipboardFormatListener(window.Handle)) throw new Win32Exception();
            });
        }
        catch
        {
            _updates.Writer.TryComplete();
            throw;
        }
        _evictionTimer = new Timer(_ => Evict(), null, EvictionInterval, EvictionInterval);
        _updates.Writer.TryWrite(PInvoke.GetClipboardSequenceNumber());
    }

    /// <summary>
    /// Records <paramref name="sequenceNumber"/>, read by the hook on the arming Ctrl+C key-down: the entry with it (or
    /// the newest before it) is kept until <see cref="CompleteArming"/> or for 5 s, whichever comes first. Any thread;
    /// never blocks for long.
    /// </summary>
    public void MarkArming(uint sequenceNumber)
    {
        lock (_entries)
        {
            _arming = sequenceNumber;
            _armedAt = Stopwatch.GetTimestamp();
        }
    }

    /// <summary>Ends the arming <paramref name="sequenceNumber"/> (the chord restored or gave up): its entry may go.</summary>
    public void CompleteArming(uint sequenceNumber)
    {
        lock (_entries)
        {
            if (_arming == sequenceNumber) _arming = -1;
        }
        Evict();
    }

    /// <summary>
    /// Gets the snapshot taken at <paramref name="sequenceNumber"/> (the clipboard before the chord's copy). The cache
    /// owns it: do not dispose it; a restore after its eviction returns false. Restore it with
    /// <see cref="ClipboardGuard.RestoreIfUnchanged"/>, and check <see cref="ClipboardSnapshot.IsComplete"/> first: an
    /// incomplete snapshot (too large, a format left out) is never restored, and the clipboard keeps the chord's copy.
    /// </summary>
    public bool TryGetBefore(uint sequenceNumber, [NotNullWhen(true)] out ClipboardSnapshot? snapshot)
    {
        lock (_entries)
        {
            snapshot = _entries.Find(e => e.Key == sequenceNumber)?.Snapshot;
            return snapshot is not null;
        }
    }

    /// <summary>Stops the listener and the worker and disposes every snapshot. Any thread but the listener's.</summary>
    public void Dispose()
    {
        lock (_entries)
        {
            if (_disposed) return;
            _disposed = true;
        }
        _evictionTimer.Dispose();
        var window = _window;
        window.Post(() => PInvoke.RemoveClipboardFormatListener(window.Handle));
        window.Dispose();
        _updates.Writer.TryComplete();
        if (!_worker.Wait(WorkerStopTimeout)) _log?.Invoke("clipboard cache: the snapshot worker did not stop");
        lock (_entries)
        {
            foreach (var entry in _entries) entry.Snapshot.Dispose();
            _entries.Clear();
        }
    }

    private LRESULT? OnClipboardUpdate(WPARAM wParam, LPARAM lParam)
    {
        _updates.Writer.TryWrite(PInvoke.GetClipboardSequenceNumber());
        return new LRESULT(0);
    }

    private async Task ProcessUpdatesAsync()
    {
        var reader = _updates.Reader;
        while (await reader.WaitToReadAsync().ConfigureAwait(false))
        {
            // The burst: every update until none came for 150 ms (or 1 s passed); the last one is snapshotted.
            uint sequenceNumber = 0;
            while (reader.TryRead(out var update)) sequenceNumber = update;
            var burst = Stopwatch.StartNew();
            while (burst.Elapsed < MaxDebounce)
            {
                await Task.Delay(Debounce).ConfigureAwait(false);
                var more = false;
                while (reader.TryRead(out var update))
                {
                    sequenceNumber = update;
                    more = true;
                }
                if (!more) break;
            }
            try
            {
                Capture(sequenceNumber);
            }
            catch (Exception e)
            {
                _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} failed, {e.GetType().Name} {e.Message}");
            }
        }
    }

    private void Capture(uint sequenceNumber)
    {
        lock (_entries)
        {
            if (_disposed || _entries.Exists(e => e.Key == sequenceNumber)) return;
        }
        // Stale: a newer update is queued and will be snapshotted instead.
        if (PInvoke.GetClipboardSequenceNumber() != sequenceNumber) return;

        var snapshot = ClipboardGuard.Snapshot(omitExcludedData: true);
        if (snapshot is null)
        {
            _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} skipped, the clipboard is busy");
            Replaced(dropAll: false);
            return;
        }
        if (snapshot.SequenceNumber != sequenceNumber || PInvoke.GetClipboardSequenceNumber() != sequenceNumber)
        {
            snapshot.Dispose();
            _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} dropped as torn");
            Replaced(dropAll: false);
            return;
        }
        if (snapshot.IsExcludedFromMonitoring)
        {
            snapshot.Dispose();
            _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} skipped, its owner excluded it from clipboard monitors");
            Replaced(dropAll: true);
            return;
        }
        if (snapshot.IsTooLarge)
        {
            _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} is too large ({snapshot.TotalBytes}+ bytes), never restored");
        }
        else if (snapshot.SkippedFormatCount > 0)
        {
            _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} left out {snapshot.SkippedFormatCount} format(s), never restored");
        }
        Add(sequenceNumber, snapshot);
    }

    /// <summary>
    /// The clipboard changed but no entry was added: the newest entry is no longer current. With
    /// <paramref name="dropAll"/>, every entry goes now but the one a pending arming needs.
    /// </summary>
    private void Replaced(bool dropAll)
    {
        var now = Stopwatch.GetTimestamp();
        lock (_entries)
        {
            if (_entries.Count > 0) _entries[^1].ReplacedAt ??= now;
            EvictLocked(now, dropAll);
        }
    }

    private void Add(uint sequenceNumber, ClipboardSnapshot snapshot)
    {
        var now = Stopwatch.GetTimestamp();
        lock (_entries)
        {
            if (_disposed)
            {
                snapshot.Dispose();
                return;
            }
            if (_entries.Count > 0) _entries[^1].ReplacedAt ??= now;
            _entries.Add(new Entry(sequenceNumber, snapshot));
            EvictLocked(now, dropAll: false);
        }
    }

    private void Evict()
    {
        lock (_entries)
        {
            if (!_disposed) EvictLocked(Stopwatch.GetTimestamp(), dropAll: false);
        }
    }

    /// <summary>Applies the retention rules (see the class); <paramref name="dropAll"/> also drops current entries.</summary>
    private void EvictLocked(long now, bool dropAll)
    {
        if (_arming >= 0 && Stopwatch.GetElapsedTime(_armedAt, now) > MaxAge) _arming = -1;
        var keep = _arming < 0 ? null : _entries.FindLast(e => e.Key <= _arming);
        _entries.RemoveAll(e =>
        {
            if (e == keep) return false;
            var expired = dropAll || e.ReplacedAt is { } replacedAt && Stopwatch.GetElapsedTime(replacedAt, now) > MaxAge;
            if (!expired) return false;
            e.Snapshot.Dispose();
            return true;
        });
        // Over the cap: the oldest go first (never the kept one or the current contents).
        for (var i = 0; _entries.Count > MaxEntries && i < _entries.Count - 1;)
        {
            if (_entries[i] == keep)
            {
                i++;
                continue;
            }
            _entries[i].Snapshot.Dispose();
            _entries.RemoveAt(i);
        }
    }

    private sealed class Entry(uint key, ClipboardSnapshot snapshot)
    {
        internal uint Key { get; } = key;
        internal ClipboardSnapshot Snapshot { get; } = snapshot;

        /// <summary>When the clipboard's contents stopped being this entry's (Stopwatch timestamp).</summary>
        internal long? ReplacedAt { get; set; }
    }
}
