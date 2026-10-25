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
/// metafile copy, so dispose it. A snapshot over 64 MB is <see cref="IsTooLarge"/>: it holds no data and is never restored.
/// </summary>
public sealed class ClipboardSnapshot : IDisposable
{
    private readonly IReadOnlyList<(uint Format, byte[] Data)> _formats;
    private readonly Lock _gate = new();
    private HENHMETAFILE _enhMetaFile;
    private bool _disposed;

    internal ClipboardSnapshot(uint sequenceNumber, IReadOnlyList<(uint Format, byte[] Data)> formats, HENHMETAFILE enhMetaFile, long totalBytes, bool isTooLarge)
    {
        SequenceNumber = sequenceNumber;
        _formats = formats;
        _enhMetaFile = enhMetaFile;
        TotalBytes = totalBytes;
        IsTooLarge = isTooLarge;
    }

    /// <summary>The clipboard sequence number the contents had (read while the clipboard was open).</summary>
    public uint SequenceNumber { get; }

    /// <summary>The bytes of the HGLOBAL formats (counted up to the 64 MB limit when <see cref="IsTooLarge"/>).</summary>
    public long TotalBytes { get; }

    /// <summary>The formats went over 64 MB in total: the snapshot holds no data and <see cref="ClipboardGuard.Restore"/> refuses it.</summary>
    public bool IsTooLarge { get; }

    /// <summary>The number of formats held.</summary>
    public int FormatCount => _formats.Count + (_enhMetaFile.IsNull ? 0 : 1);

    /// <summary>Deletes the metafile copy; a later restore returns false. Any thread.</summary>
    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            if (!_enhMetaFile.IsNull) PInvoke.DeleteEnhMetaFile(_enhMetaFile);
            _enhMetaFile = default;
        }
    }

    /// <summary>Sets every held format on the clipboard, which the caller has opened and emptied.</summary>
    internal unsafe bool SetFormats()
    {
        lock (_gate)
        {
            if (_disposed || IsTooLarge) return false;
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
}

/// <summary>
/// The clipboard around a synthetic copy or paste: take a <see cref="Snapshot"/>, change the clipboard, then
/// <see cref="Restore"/> it, so the user's clipboard is never left clobbered. Opening the clipboard tries 10 times,
/// 10 ms apart, since other apps hold it briefly. Any thread; every call opens and closes the clipboard itself.
/// </summary>
public static class ClipboardGuard
{
    /// <summary>A snapshot whose HGLOBAL formats exceed this in total is stored as too large.</summary>
    internal const long MaxSnapshotBytes = 64L * 1024 * 1024;

    private const int OpenAttempts = 10;
    private static readonly TimeSpan OpenRetryDelay = TimeSpan.FromMilliseconds(10);
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(10);
    private static readonly TimeSpan DefaultWaitTimeout = TimeSpan.FromMilliseconds(500);

    /// <summary>The clipboard's sequence number, which every change increments.</summary>
    public static uint SequenceNumber => PInvoke.GetClipboardSequenceNumber();

    /// <summary>
    /// Copies the clipboard's contents. Skips CF_BITMAP (Windows synthesizes it from CF_DIB), CF_METAFILEPICT
    /// (synthesized from CF_ENHMETAFILE), CF_PALETTE, owner-display, private and GDI-object formats (none are HGLOBAL
    /// data). Null if the clipboard could not be opened. The clipboard stays open only while the bytes are copied.
    /// </summary>
    public static unsafe ClipboardSnapshot? Snapshot()
    {
        if (!Open()) return null;
        var formats = new List<(uint, byte[])>();
        HENHMETAFILE enhMetaFile = default;
        long total = 0;
        var tooLarge = false;
        uint sequenceNumber;
        try
        {
            sequenceNumber = PInvoke.GetClipboardSequenceNumber();
            for (var format = PInvoke.EnumClipboardFormats(0); format != 0; format = PInvoke.EnumClipboardFormats(format))
            {
                if (format == (uint)CLIPBOARD_FORMAT.CF_ENHMETAFILE)
                {
                    var metafile = PInvoke.GetClipboardData(format);
                    if (!metafile.IsNull) enhMetaFile = PInvoke.CopyEnhMetaFile(new HENHMETAFILE(metafile.Value), default(PCWSTR));
                    continue;
                }
                if (IsSkipped(format)) continue;

                // Null: a delayed render the owner refused.
                var handle = PInvoke.GetClipboardData(format);
                if (handle.IsNull) continue;
                var memory = new HGLOBAL(handle.Value);
                var size = (long)PInvoke.GlobalSize(memory);
                total += size;
                if (total > MaxSnapshotBytes)
                {
                    tooLarge = true;
                    break;
                }
                var source = PInvoke.GlobalLock(memory);
                if (source is null) continue;
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
        finally
        {
            PInvoke.CloseClipboard();
        }

        if (tooLarge)
        {
            formats.Clear();
            if (!enhMetaFile.IsNull) PInvoke.DeleteEnhMetaFile(enhMetaFile);
            enhMetaFile = default;
        }
        return new ClipboardSnapshot(sequenceNumber, formats, enhMetaFile, total, tooLarge);
    }

    /// <summary>
    /// Replaces the clipboard's contents with <paramref name="snapshot"/>. False if the clipboard could not be opened,
    /// the snapshot is too large or disposed, or a format was refused.
    /// </summary>
    public static bool Restore(ClipboardSnapshot snapshot)
    {
        if (snapshot.IsTooLarge || !Open()) return false;
        try
        {
            return PInvoke.EmptyClipboard() && snapshot.SetFormats();
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
    /// could not be opened or a format was refused.
    /// </summary>
    public static bool WriteText(string text, bool excludeFromHistory)
    {
        if (!Open()) return false;
        try
        {
            if (!PInvoke.EmptyClipboard()) return false;
            // Two zero bytes more: the terminating null character.
            var ok = SetBytes((uint)CLIPBOARD_FORMAT.CF_UNICODETEXT, MemoryMarshal.AsBytes(text.AsSpan()), extraZeroBytes: sizeof(char));
            if (excludeFromHistory)
            {
                // A real allocation even where the data does not matter: a null handle would mean a delayed render.
                ReadOnlySpan<byte> zero = [0, 0, 0, 0];
                ok &= SetBytes(RegisteredFormats.ExcludeFromMonitorProcessing, zero);
                ok &= SetBytes(RegisteredFormats.CanIncludeInClipboardHistory, zero);
                ok &= SetBytes(RegisteredFormats.CanUploadToCloudClipboard, zero);
            }
            return ok;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>The clipboard's text (CF_UNICODETEXT), or null if there is none or the clipboard could not be opened.</summary>
    public static unsafe string? ReadText()
    {
        if (!Open()) return null;
        try
        {
            var handle = PInvoke.GetClipboardData((uint)CLIPBOARD_FORMAT.CF_UNICODETEXT);
            if (handle.IsNull) return null;
            var memory = new HGLOBAL(handle.Value);
            var source = (char*)PInvoke.GlobalLock(memory);
            if (source is null) return null;
            try
            {
                var chars = new ReadOnlySpan<char>(source, checked((int)(PInvoke.GlobalSize(memory) / sizeof(char))));
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

    /// <summary>Formats that are not HGLOBAL data, or that Windows synthesizes from another format.</summary>
    private static bool IsSkipped(uint format) =>
        format is (uint)CLIPBOARD_FORMAT.CF_BITMAP or (uint)CLIPBOARD_FORMAT.CF_METAFILEPICT or (uint)CLIPBOARD_FORMAT.CF_PALETTE
        || format is >= (uint)CLIPBOARD_FORMAT.CF_OWNERDISPLAY and <= (uint)CLIPBOARD_FORMAT.CF_DSPENHMETAFILE
        || format is >= (uint)CLIPBOARD_FORMAT.CF_PRIVATEFIRST and <= (uint)CLIPBOARD_FORMAT.CF_GDIOBJLAST;

    /// <summary>The registered formats that keep text out of clipboard history and monitors.</summary>
    private static class RegisteredFormats
    {
        internal static readonly uint ExcludeFromMonitorProcessing = PInvoke.RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        internal static readonly uint CanIncludeInClipboardHistory = PInvoke.RegisterClipboardFormat("CanIncludeInClipboardHistory");
        internal static readonly uint CanUploadToCloudClipboard = PInvoke.RegisterClipboardFormat("CanUploadToCloudClipboard");
    }
}

/// <summary>
/// Recent clipboard snapshots by sequence number, so the Ctrl+C+C chord can restore the user's clipboard from before the
/// app copied the selection. The low-level hook never opens the clipboard: it only records the sequence number on the
/// arming Ctrl+C key-down, which the caller passes to <see cref="MarkArming"/> and later <see cref="TryGetBefore"/>.
/// <para>
/// A clipboard format listener on its own message-only window and dedicated thread (never the hook thread, so a slow
/// or delayed-render snapshot cannot stall the hooks) posts each update's sequence number to a worker, which takes a
/// full snapshot. One snapshot is taken at creation, so the first chord after launch can restore. A snapshot whose
/// sequence number changed by the time the clipboard was closed is torn and dropped. An entry is evicted 5 s after a
/// newer one replaced it, except the newest entry from before the latest arming tap, which stays until the next one.
/// </para>
/// </summary>
public sealed class ClipboardHistoryCache : IDisposable
{
    private static readonly TimeSpan MaxAge = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan WorkerStopTimeout = TimeSpan.FromSeconds(2);

    private readonly Action<string>? _log;
    private readonly Channel<uint> _updates = Channel.CreateUnbounded<uint>(new UnboundedChannelOptions { SingleReader = true });

    /// <summary>Oldest first, so the last is the clipboard's current contents. Guarded by itself.</summary>
    private readonly List<Entry> _entries = [];
    private readonly Task _worker;
    private readonly MessageWindow _window;

    /// <summary>The latest arming sequence number, or -1 before the first.</summary>
    private long _arming = -1;
    private bool _disposed;

    /// <summary>
    /// Starts the listener thread and the worker, and queues the first snapshot. Throws
    /// <see cref="Win32Exception"/> if Windows refuses the window or the listener.
    /// </summary>
    /// <param name="log">Gets failures and notable drops (torn, too large, clipboard busy).</param>
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
        _updates.Writer.TryWrite(PInvoke.GetClipboardSequenceNumber());
    }

    /// <summary>
    /// Records <paramref name="sequenceNumber"/>, read by the hook on the arming Ctrl+C key-down: the entry with it (or
    /// the newest before it) is kept regardless of age until the next arming tap. Any thread; never blocks.
    /// </summary>
    public void MarkArming(uint sequenceNumber) => Volatile.Write(ref _arming, sequenceNumber);

    /// <summary>
    /// Gets the snapshot taken at <paramref name="sequenceNumber"/> (the clipboard before the chord's copy). The cache
    /// owns it: do not dispose it; a restore after its eviction returns false. Check <see cref="ClipboardSnapshot.IsTooLarge"/>.
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
        await foreach (var sequenceNumber in _updates.Reader.ReadAllAsync().ConfigureAwait(false))
        {
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

        var snapshot = ClipboardGuard.Snapshot();
        if (snapshot is null)
        {
            _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} skipped, the clipboard is busy");
            return;
        }
        if (snapshot.SequenceNumber != sequenceNumber || PInvoke.GetClipboardSequenceNumber() != sequenceNumber)
        {
            snapshot.Dispose();
            _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} dropped as torn");
            return;
        }
        if (snapshot.IsTooLarge)
        {
            _log?.Invoke($"clipboard cache: snapshot {sequenceNumber} is too large ({snapshot.TotalBytes}+ bytes), never restored");
        }
        Add(sequenceNumber, snapshot);
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

            var arming = Volatile.Read(ref _arming);
            var keep = arming < 0 ? null : _entries.FindLast(e => e.Key <= arming);
            _entries.RemoveAll(e =>
            {
                if (e == keep || e.ReplacedAt is not { } replacedAt || Stopwatch.GetElapsedTime(replacedAt, now) <= MaxAge) return false;
                e.Snapshot.Dispose();
                return true;
            });
        }
    }

    private sealed class Entry(uint key, ClipboardSnapshot snapshot)
    {
        internal uint Key { get; } = key;
        internal ClipboardSnapshot Snapshot { get; } = snapshot;

        /// <summary>When a newer entry replaced this one as the clipboard's contents (Stopwatch timestamp).</summary>
        internal long? ReplacedAt { get; set; }
    }
}
