using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Input;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Ole;

namespace PopGuy.Platform.Tests;

/// <summary>The clipboard is one per session: its tests never run alongside each other.</summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class ClipboardCollection
{
    public const string Name = "Clipboard";
}

// Hard constraint: the user's clipboard is never left clobbered. A snapshot brings every format back byte for byte, a
// write excluded from history carries the three exclusion formats, and a clipboard that could not be brought back is
// refused before anything is written. These touch the real clipboard (it is left with test data).
[Collection(ClipboardCollection.Name)]
public sealed class ClipboardGuardTests
{
    private const uint UnicodeText = (uint)CLIPBOARD_FORMAT.CF_UNICODETEXT;

    [Fact]
    public void RestoreBringsBackTextHtmlAndCustomFormatByteForByte()
    {
        RequireClipboard();
        uint[] formats = [UnicodeText, Register("HTML Format"), Register("PopGuy.Platform.Tests.Custom")];
        byte[][] payloads =
        [
            [.. Encoding.Unicode.GetBytes("original text"), 0, 0],
            Encoding.UTF8.GetBytes("Version:0.9\r\nStartHTML:-1\r\nEndHTML:-1\r\n<b>original</b>\0"),
            // An embedded zero, so a copy that stops at the first null shows.
            [1, 0, 2, 0xFF, 0, 3],
        ];
        Set(formats.Zip(payloads).ToArray());
        var before = Read(formats);
        for (var i = 0; i < formats.Length; i++)
        {
            Assert.NotNull(before[i]);
            Assert.Equal(payloads[i], before[i]![..payloads[i].Length]);
        }

        using var snapshot = ClipboardGuard.Snapshot();
        Assert.NotNull(snapshot);
        Assert.True(snapshot.IsComplete);

        Assert.True(ClipboardGuard.WriteText("replacement", excludeFromHistory: false));
        Assert.Equal("replacement", ClipboardGuard.ReadText());
        Assert.Null(Read(formats[2])[0]);

        Assert.True(ClipboardGuard.Restore(snapshot));
        var after = Read(formats);
        for (var i = 0; i < formats.Length; i++) Assert.Equal(before[i], after[i]);
    }

    [Fact]
    public void WriteTextExcludedFromHistorySetsTheThreeExclusionFormats()
    {
        RequireClipboard();

        Assert.True(ClipboardGuard.WriteText("secret", excludeFromHistory: true));

        Assert.Equal("secret", ClipboardGuard.ReadText());
        var markers = Read(
            Register("ExcludeClipboardContentFromMonitorProcessing"),
            Register("CanIncludeInClipboardHistory"),
            Register("CanUploadToCloudClipboard"));
        foreach (var data in markers)
        {
            Assert.NotNull(data);
            Assert.Equal(new byte[4], data[..4]);
        }
    }

    [Fact]
    public void TransactionRefusesTooLargeClipboardWithoutTouchingIt()
    {
        RequireClipboard();
        Set((Register("PopGuy.Platform.Tests.Large"), new byte[ClipboardGuard.MaxSnapshotBytes + 1]));
        var sequence = ClipboardGuard.SequenceNumber;

        Assert.False(ClipboardTransaction.TryBegin(out var transaction, out var refusal));

        Assert.Null(transaction);
        Assert.Equal("tooLarge", refusal);
        Assert.Equal(sequence, ClipboardGuard.SequenceNumber);
        // Frees the 64 MB.
        Set();
    }

    // The process-wide gate: a refusal releases it, a running transaction holds it, and a double dispose releases it once.
    [Fact]
    public void TransactionRefusesABusyClipboardAndReleasesTheGate()
    {
        RequireClipboard();
        Assert.True(ClipboardGuard.WriteText("gate", excludeFromHistory: false));
        using var opened = new ManualResetEventSlim();
        using var close = new ManualResetEventSlim();
        // Another thread holds it for a window: an OpenClipboard(NULL) from another thread of the same process still
        // succeeds (measured on windows-latest), so the holder needs a window of its own.
        var held = false;
        var holdError = "";
        var holder = new Thread(() =>
        {
            // No assert here: an exception on this thread would take the test host down.
            using var window = new MessageWindow();
            held = PInvoke.OpenClipboard(window.Handle);
            if (!held) holdError = $"error {Marshal.GetLastPInvokeError()}";
            opened.Set();
            if (!held) return;
            close.Wait();
            PInvoke.CloseClipboard();
        });
        holder.Start();
        ClipboardTransaction? busy = null;
        try
        {
            Assert.True(opened.Wait(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
            Assert.True(held, holdError);
            Assert.False(ClipboardTransaction.TryBegin(out busy, out var refusal));
            Assert.Equal("clipboardBusy", refusal);
        }
        finally
        {
            // A transaction that began anyway must not keep the gate from the tests after this one.
            busy?.Dispose();
            close.Set();
            holder.Join();
        }

        // A gate left held would make this wait 2 s and refuse "transactionInProgress".
        Assert.True(ClipboardTransaction.TryBegin(out var transaction, out var next), next);
        transaction.Dispose();
    }

    [Fact]
    public async Task ARunningTransactionHoldsTheGateUntilDisposedOnce()
    {
        RequireClipboard();
        Assert.True(ClipboardGuard.WriteText("gate", excludeFromHistory: false));
        Assert.True(ClipboardTransaction.TryBegin(out var first, out var refusal), refusal);
        try
        {
            var (began, other, otherRefusal) = await Task.Run(() => (ClipboardTransaction.TryBegin(out var t, out var r), t, r), TestContext.Current.CancellationToken);
            other?.Dispose();
            Assert.False(began);
            Assert.Equal("transactionInProgress", otherRefusal);
        }
        finally
        {
            first.Dispose();
        }
        // A second dispose must not release the gate again (SemaphoreSlim would throw over its maximum).
        first.Dispose();
        Assert.True(ClipboardTransaction.TryBegin(out var third, out refusal), refusal);
        third.Dispose();
    }

    /// <summary>Skips the test when there is no Win32 clipboard to open (not Windows, or no session clipboard).</summary>
    private static void RequireClipboard()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The clipboard tests need Windows.");
        if (!TryOpen(out var error)) Assert.Skip($"OpenClipboard failed: {error}");
        PInvoke.CloseClipboard();
    }

    /// <summary>Opens the clipboard, retrying for about 1 s since other processes hold it briefly.</summary>
    private static bool TryOpen(out string error)
    {
        for (var attempt = 1; ; attempt++)
        {
            if (PInvoke.OpenClipboard(HWND.Null))
            {
                error = "";
                return true;
            }
            var code = Marshal.GetLastPInvokeError();
            if (attempt == 50)
            {
                error = $"{new Win32Exception(code).Message} (error {code})";
                return false;
            }
            Thread.Sleep(20);
        }
    }

    private static void Open()
    {
        if (!TryOpen(out var error)) Assert.Fail($"OpenClipboard failed: {error}");
    }

    private static uint Register(string name) => PInvoke.RegisterClipboardFormat(name);

    /// <summary>Empties the clipboard and sets each format's bytes.</summary>
    private static void Set(params (uint Format, byte[] Data)[] formats)
    {
        Open();
        try
        {
            Assert.True(PInvoke.EmptyClipboard());
            foreach (var (format, data) in formats) Assert.True(ClipboardGuard.SetBytes(format, data));
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }

    /// <summary>Each format's bytes (the whole memory block), or null when the clipboard does not hold it.</summary>
    private static unsafe byte[]?[] Read(params uint[] formats)
    {
        Open();
        try
        {
            var result = new byte[]?[formats.Length];
            for (var i = 0; i < formats.Length; i++)
            {
                var handle = PInvoke.GetClipboardData(formats[i]);
                if (handle.IsNull) continue;
                var memory = new HGLOBAL(handle.Value);
                var size = checked((int)PInvoke.GlobalSize(memory));
                var source = PInvoke.GlobalLock(memory);
                Assert.True(source is not null, $"GlobalLock failed for format {formats[i]}");
                try
                {
                    result[i] = new ReadOnlySpan<byte>(source, size).ToArray();
                }
                finally
                {
                    PInvoke.GlobalUnlock(memory);
                }
            }
            return result;
        }
        finally
        {
            PInvoke.CloseClipboard();
        }
    }
}
