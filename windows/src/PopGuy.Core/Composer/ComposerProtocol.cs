// Terminal Composer wire protocol and file rules, shared by popguy-edit.exe (PopGuy.Edit links this file) and the
// app. Self-contained: no dependency on other Core files. Same contract as
// macos/PopGuy/Modules/TerminalComposer/ComposerProtocol.swift.
//
// Wire protocol: JSON lines over a same-user named pipe, UTF-8, one message per "\n".
//   client -> app: open, then written (after it wrote the "done" text to the file)
//   app -> client: done | cancel | busy | error
// Message text is LF-only and never logged.

using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PopGuy.Core.Composer;

public abstract record ComposerMessage
{
    /// <summary>Client -> app: edit <c>Text</c> (the file's display text) in the composer.</summary>
    public sealed record Open(string Text, string FileName, string Mode) : ComposerMessage;
    /// <summary>App -> client: the user finished; write <c>Text</c> back. <c>Submit</c> asks the caller to submit.</summary>
    public sealed record Done(string Text, bool Submit) : ComposerMessage;
    /// <summary>Client -> app: the "done" text was written to the file (sent just before exiting).</summary>
    public sealed record Written : ComposerMessage;
    /// <summary>App -> client: the user cancelled; leave the file untouched.</summary>
    public sealed record Cancel : ComposerMessage;
    /// <summary>App -> client: another composer session is already open.</summary>
    public sealed record Busy : ComposerMessage;
    /// <summary>App -> client: the app refused the request (e.g. the feature is off).</summary>
    public sealed record Error(string Reason) : ComposerMessage;

    /// <summary>Cap on the UTF-8 size of a message's text (and of the file the CLI reads).</summary>
    public const int MaxTextBytes = 1_048_576;
    /// <summary>Cap on one encoded line, without its "\n". JSON escaping inflates text, so it is larger than
    /// <see cref="MaxTextBytes"/> (worst case 6x: a control character becomes "\u00XX"; an emoji, which the encoder
    /// always escapes as a surrogate pair, 3x); framed reads stop at this many bytes.</summary>
    public const int MaxLineBytes = 8 * 1_048_576;

    // Source-generated (trim safe). The relaxed encoder writes non-ASCII BMP text as UTF-8 instead of "\uXXXX".
    private static readonly ComposerJsonContext Json = new(new JsonSerializerOptions
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    });

    /// <summary>Encodes one message as a JSON line terminated by "\n". The JSON writer escapes newlines inside
    /// strings, so the only raw "\n" is the terminator.</summary>
    public static byte[] EncodeLine(ComposerMessage message)
    {
        if (message.PayloadText is { } text && Encoding.UTF8.GetByteCount(text) > MaxTextBytes)
            throw new ComposerProtocolException(ComposerProtocolError.TextTooLarge);
        var json = JsonSerializer.SerializeToUtf8Bytes(message.ToWire(), Json.ComposerWire);
        if (json.Length > MaxLineBytes)
            throw new ComposerProtocolException(ComposerProtocolError.LineTooLarge);
        var line = new byte[json.Length + 1];
        json.CopyTo(line, 0);
        line[^1] = (byte)'\n';
        return line;
    }

    /// <summary>Decodes one line, with or without its terminating "\n".</summary>
    public static ComposerMessage DecodeLine(ReadOnlySpan<byte> line)
    {
        var body = line.Length > 0 && line[^1] == (byte)'\n' ? line[..^1] : line;
        if (body.Length > MaxLineBytes)
            throw new ComposerProtocolException(ComposerProtocolError.LineTooLarge);
        ComposerWire? wire;
        try
        {
            wire = JsonSerializer.Deserialize(body, Json.ComposerWire);
        }
        catch (JsonException e)
        {
            throw new ComposerProtocolException(ComposerProtocolError.Malformed, e);
        }
        var message = FromWire(wire) ?? throw new ComposerProtocolException(ComposerProtocolError.Malformed);
        if (message.PayloadText is { } text && Encoding.UTF8.GetByteCount(text) > MaxTextBytes)
            throw new ComposerProtocolException(ComposerProtocolError.TextTooLarge);
        return message;
    }

    private string? PayloadText => this switch
    {
        Open open => open.Text,
        Done done => done.Text,
        _ => null,
    };

    private ComposerWire ToWire() => this switch
    {
        Open m => new ComposerWire("open", Text: m.Text, FileName: m.FileName, Mode: m.Mode),
        Done m => new ComposerWire("done", Text: m.Text, Submit: m.Submit),
        Written => new ComposerWire("written"),
        Cancel => new ComposerWire("cancel"),
        Busy => new ComposerWire("busy"),
        Error m => new ComposerWire("error", Reason: m.Reason),
        _ => throw new InvalidOperationException("Unknown composer message"),
    };

    /// <summary>The message for <paramref name="wire"/>, or null for an unknown type or a missing field.</summary>
    private static ComposerMessage? FromWire(ComposerWire? wire) => wire switch
    {
        { Type: "open", Text: { } text, FileName: { } fileName, Mode: { } mode } => new Open(text, fileName, mode),
        { Type: "done", Text: { } text, Submit: { } submit } => new Done(text, submit),
        { Type: "written" } => new Written(),
        { Type: "cancel" } => new Cancel(),
        { Type: "busy" } => new Busy(),
        { Type: "error", Reason: { } reason } => new Error(reason),
        _ => null,
    };
}

/// <summary>The JSON shape of every message: <c>type</c> plus the fields that type uses.</summary>
internal sealed record ComposerWire(
    [property: JsonPropertyName("type")] string? Type,
    [property: JsonPropertyName("text")] string? Text = null,
    [property: JsonPropertyName("fileName")] string? FileName = null,
    [property: JsonPropertyName("mode")] string? Mode = null,
    [property: JsonPropertyName("submit")] bool? Submit = null,
    [property: JsonPropertyName("reason")] string? Reason = null);

[JsonSerializable(typeof(ComposerWire))]
internal sealed partial class ComposerJsonContext : JsonSerializerContext;

public enum ComposerProtocolError
{
    LineTooLarge,
    TextTooLarge,
    /// <summary>Not JSON, an unknown type, or a missing field.</summary>
    Malformed,
}

public sealed class ComposerProtocolException(ComposerProtocolError error, Exception? inner = null)
    : Exception($"Composer message rejected: {error}", inner)
{
    public ComposerProtocolError Error { get; } = error;
}

// File rules

public enum ComposerLineEnding
{
    Lf,
    CrLf,
}

/// <summary>What the CLI read from the file: the display text plus what it needs to write it back.</summary>
/// <param name="Text">LF-only text without the file's one trailing newline.</param>
public readonly record struct ComposerFileContent(string Text, bool HadTrailingNewline, ComposerLineEnding LineEnding);

public enum ComposerFileError
{
    NotRegularFile,
    TooLarge,
    InvalidUtf8,
    Io,
}

public sealed class ComposerFileException(ComposerFileError error, Exception? inner = null)
    : Exception($"Composer file refused: {error}", inner)
{
    public ComposerFileError Error { get; } = error;
}

public static class ComposerFileRules
{
    public const int MaxFileBytes = ComposerMessage.MaxTextBytes;

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>
    /// Reads the file the editor was given. A missing file is empty text. Only regular files (a symlink is judged by
    /// its target) up to <see cref="MaxFileBytes"/> of valid UTF-8 are accepted; directories and devices are refused.
    /// A UTF-8 BOM is dropped, as on macOS, and not written back.
    /// </summary>
    public static ComposerFileContent Read(string path)
    {
        try
        {
            // Directory.Exists follows a symlink, so a link to a directory is refused too.
            if (Directory.Exists(path))
                throw new ComposerFileException(ComposerFileError.NotRegularFile);

            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            // A regular file is seekable; a device (NUL, CON) or a pipe is not.
            if (!stream.CanSeek)
                throw new ComposerFileException(ComposerFileError.NotRegularFile);
            // Bounded read rather than trusting the reported length.
            var buffer = new byte[MaxFileBytes + 1];
            var count = stream.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
            if (count > MaxFileBytes)
                throw new ComposerFileException(ComposerFileError.TooLarge);

            var bytes = buffer.AsSpan(0, count);
            if (bytes.StartsWith(StrictUtf8.Preamble))
                bytes = bytes[StrictUtf8.Preamble.Length..];
            string raw;
            try
            {
                raw = StrictUtf8.GetString(bytes);
            }
            catch (DecoderFallbackException e)
            {
                throw new ComposerFileException(ComposerFileError.InvalidUtf8, e);
            }

            var lineEnding = raw.Contains("\r\n", StringComparison.Ordinal) ? ComposerLineEnding.CrLf : ComposerLineEnding.Lf;
            var text = NormalizeLineEndings(raw);
            var hadTrailingNewline = text.EndsWith('\n');
            if (hadTrailingNewline)
                text = text[..^1];
            return new ComposerFileContent(text, hadTrailingNewline, lineEnding);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            // Missing file (or a dangling symlink), as ENOENT on macOS: empty text, created on write.
            return new ComposerFileContent("", false, ComposerLineEnding.Lf);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw MappedError(e);
        }
    }

    /// <summary>Converts CRLF and bare CR to LF. The wire text is LF-only.</summary>
    public static string NormalizeLineEndings(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');

    /// <summary>
    /// Writes the composer's LF text back: one trailing newline only if the original had one, CRLF only if the
    /// original used CRLF. Written in place (truncate + write, not an atomic replace) so links, ACLs and the file's
    /// identity stay as they are; a missing file is created. The caller waits for the editor to exit, so nobody
    /// reads a half-written file.
    /// </summary>
    public static void Write(string text, string path, ComposerFileContent original)
    {
        var output = NormalizeLineEndings(text);
        if (original.HadTrailingNewline)
            output += "\n";
        if (original.LineEnding == ComposerLineEnding.CrLf)
            output = output.Replace("\n", "\r\n");

        try
        {
            using var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            if (!stream.CanSeek || (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.Device)) != 0)
                throw new ComposerFileException(ComposerFileError.NotRegularFile);
            stream.SetLength(0);
            stream.Write(Encoding.UTF8.GetBytes(output));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            throw MappedError(e);
        }
    }

    // FileStream throws NotSupportedException when a path opens a device rather than a file.
    private static ComposerFileException MappedError(Exception e) =>
        new(e is NotSupportedException ? ComposerFileError.NotRegularFile : ComposerFileError.Io, e);
}
