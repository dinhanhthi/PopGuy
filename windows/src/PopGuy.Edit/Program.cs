// popguy-edit.exe: the Terminal Composer CLI, the $VISUAL editor that terminal programs call with a file path.
// It reads and validates the file, sends its text to the running PopGuy app over a same-user named pipe, then blocks
// until the composer replies: "done" writes the text back in place, tells the app "written" and exits 0; cancel, busy,
// error or a closed connection exit 1 and leave the file untouched; a failed write exits 1 without "written".
// The text itself is never printed. Same flow as macos/PopGuyEdit/main.swift.

using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;
using PopGuy.Core.Composer;

namespace PopGuy.Edit;

internal static partial class Program
{
    private const string NotRunning =
        "Terminal Composer is off or PopGuy is not running — enable it in PopGuy Settings → Composer.";

    private static int Main(string[] args)
    {
        if (args.Length != 1 || args[0].Length == 0)
            return Fail("usage: popguy-edit <file>", code: 2);
        var path = args[0];

        ComposerFileContent original;
        try
        {
            original = ComposerFileRules.Read(path);
        }
        catch (ComposerFileException e)
        {
            return Fail($"{path}: {Describe(e)}");
        }

        if (!OperatingSystem.IsWindows())
            return Fail("Terminal Composer needs Windows");
        return Run(path, original);
    }

    [SupportedOSPlatform("windows")]
    private static int Run(string path, ComposerFileContent original)
    {
        var pipeName = "PopGuy-Composer-" + WindowsIdentity.GetCurrent().User!.Value;

        var pipe = TryConnect(pipeName);
        if (pipe is null)
        {
            // Launch PopGuy only when it is not running at all; if it runs but does not listen, the feature is off
            // and launching again would not help.
            if (!IsPopGuyRunning())
                LaunchPopGuy();
            // Retry for about 5 s (25 x 200 ms) while the app starts its server.
            for (var i = 0; i < 25 && pipe is null; i++)
                pipe = TryConnect(pipeName);
        }
        if (pipe is null)
            return Fail(NotRunning);

        using (pipe)
        {
            AllowPopGuyForeground();

            byte[] request;
            try
            {
                request = ComposerMessage.EncodeLine(new ComposerMessage.Open(original.Text, Path.GetFileName(path), "edit"));
            }
            catch (ComposerProtocolException)
            {
                return Fail("file is too large to send to PopGuy");
            }
            if (!WriteAll(pipe, request))
                return Fail("PopGuy closed the connection");

            // Keep the pipe fully open while the composer is up: the app treats EOF as "client gone".
            ComposerMessage reply;
            switch (ReadReplyLine(pipe, out var line))
            {
                case ReplyStatus.Closed:
                    return Fail("PopGuy closed the connection");
                case ReplyStatus.Failed:
                    return Fail("invalid reply from PopGuy");
            }
            try
            {
                reply = ComposerMessage.DecodeLine(line);
            }
            catch (ComposerProtocolException)
            {
                return Fail("invalid reply from PopGuy");
            }

            switch (reply)
            {
                case ComposerMessage.Done done:
                    try
                    {
                        ComposerFileRules.Write(done.Text, path, original);
                    }
                    catch (ComposerFileException e)
                    {
                        return Fail($"{path}: {Describe(e)}");
                    }
                    // Best effort: without it the app keeps the draft and skips auto-submit.
                    WriteAll(pipe, ComposerMessage.EncodeLine(new ComposerMessage.Written()));
                    return 0;
                case ComposerMessage.Cancel:
                    return Fail("cancelled");
                case ComposerMessage.Busy:
                    return Fail("another composer is already open");
                case ComposerMessage.Error error:
                    return Fail(error.Reason);
                default:
                    return Fail("invalid reply from PopGuy");
            }
        }
    }

    /// <summary>Prints one "popguy-edit: ..." line on stderr and returns the exit code.</summary>
    private static int Fail(string message, int code = 1)
    {
        Console.Error.WriteLine($"popguy-edit: {message}");
        return code;
    }

    private static string Describe(ComposerFileException e) => e.Error switch
    {
        ComposerFileError.NotRegularFile => "not a regular file",
        ComposerFileError.TooLarge => "file is larger than 1 MiB",
        ComposerFileError.InvalidUtf8 => "file is not valid UTF-8",
        _ => e.InnerException?.Message ?? e.Message,
    };

    /// <summary>One connection attempt (up to 200 ms) on a fresh pipe stream; null if nobody of this user listens.</summary>
    private static NamedPipeClientStream? TryConnect(string pipeName)
    {
        // CurrentUserOnly refuses a pipe whose server runs as another user.
        var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.CurrentUserOnly);
        try
        {
            pipe.Connect(200);
            return pipe;
        }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            pipe.Dispose();
            return null;
        }
    }

    private static Process[] PopGuyProcesses() => Process.GetProcessesByName("PopGuy");

    private static bool IsPopGuyRunning()
    {
        var processes = PopGuyProcesses();
        foreach (var process in processes)
            process.Dispose();
        return processes.Length > 0;
    }

    /// <summary>Starts PopGuy.exe from the install folder: the CLI is published into &lt;install&gt;\bin.</summary>
    private static void LaunchPopGuy()
    {
        var exe = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "PopGuy.exe"));
        if (!File.Exists(exe))
            return;
        try
        {
            using var _ = Process.Start(new ProcessStartInfo(exe)
            {
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(exe),
            });
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException)
        {
            // Nothing to do: the retry loop reports the failure.
        }
    }

    /// <summary>
    /// Best effort: lets PopGuy bring the composer to the foreground. It usually fails (no foreground rights) when node
    /// or the shell under Windows Terminal starts the CLI, so the app must not rely on it.
    /// </summary>
    private static void AllowPopGuyForeground()
    {
        foreach (var process in PopGuyProcesses())
        {
            using (process)
                AllowSetForegroundWindow((uint)process.Id);
        }
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(uint processId);

    private static bool WriteAll(Stream pipe, byte[] data)
    {
        try
        {
            pipe.Write(data);
            pipe.Flush();
            return true;
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            return false;
        }
    }

    private enum ReplyStatus
    {
        Line,
        Closed,
        Failed,
    }

    /// <summary>Reads one "\n"-framed line, capped at <see cref="ComposerMessage.MaxLineBytes"/> (without the "\n").</summary>
    private static ReplyStatus ReadReplyLine(Stream pipe, out byte[] line)
    {
        line = [];
        using var received = new MemoryStream();
        var chunk = new byte[64 * 1024];
        while (true)
        {
            int count;
            try
            {
                count = pipe.Read(chunk);
            }
            catch (IOException)
            {
                // A broken pipe reads as the app having gone away.
                return ReplyStatus.Closed;
            }
            if (count == 0)
                return ReplyStatus.Closed;
            var newline = Array.IndexOf(chunk, (byte)'\n', 0, count);
            received.Write(chunk, 0, newline >= 0 ? newline : count);
            if (received.Length > ComposerMessage.MaxLineBytes)
                return ReplyStatus.Failed;
            if (newline >= 0)
            {
                line = received.ToArray();
                return ReplyStatus.Line;
            }
        }
    }
}
