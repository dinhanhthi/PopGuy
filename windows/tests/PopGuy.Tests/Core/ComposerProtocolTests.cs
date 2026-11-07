using System.Text;
using System.Text.Json.Nodes;
using PopGuy.Core.Composer;

namespace PopGuy.Tests.Core;

// Contract: the Terminal Composer wire protocol (JSON lines shared with the macOS app and CLI) and the CLI's file
// rules. Same behaviors as macos/PopGuyTests/Unit/ComposerProtocolTests.swift; the FIFO case is macOS-only (.NET
// cannot classify a FIFO, and opening one blocks for a writer).
public sealed class ComposerProtocolTests
{
    // ASCII-only, no "/" (Swift's JSON encoder writes "\/"), shared with the macOS tests.
    public static TheoryData<string, ComposerMessage> GoldenLines => new()
    {
        { """{"type":"open","text":"Hello\nworld","fileName":"COMMIT_EDITMSG","mode":"edit"}""",
          new ComposerMessage.Open("Hello\nworld", "COMMIT_EDITMSG", "edit") },
        { """{"type":"done","text":"Fixed \"it\"","submit":true}""", new ComposerMessage.Done("Fixed \"it\"", true) },
        { """{"type":"done","text":"","submit":false}""", new ComposerMessage.Done("", false) },
        { """{"type":"cancel"}""", new ComposerMessage.Cancel() },
        { """{"type":"busy"}""", new ComposerMessage.Busy() },
        { """{"type":"written"}""", new ComposerMessage.Written() },
        { """{"type":"error","reason":"Terminal Composer is off"}""", new ComposerMessage.Error("Terminal Composer is off") },
    };

    [Theory]
    [MemberData(nameof(GoldenLines))]
    public void GoldenLinesDecodeAndRoundTripAsOneLine(string golden, ComposerMessage expected)
    {
        // Decoding accepts the line with or without its terminating newline.
        Assert.Equal(expected, ComposerMessage.DecodeLine(Encoding.UTF8.GetBytes(golden)));
        Assert.Equal(expected, ComposerMessage.DecodeLine(Encoding.UTF8.GetBytes(golden + "\n")));

        var line = ComposerMessage.EncodeLine(expected);
        Assert.Equal((byte)'\n', line[^1]);
        Assert.DoesNotContain((byte)'\n', line[..^1]);
        Assert.Equal(expected, ComposerMessage.DecodeLine(line));

        // Same wire keys and values as the golden line (key order is free).
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(golden), JsonNode.Parse(line.AsSpan(0, line.Length - 1))));
    }

    [Fact]
    public void ReadsSwiftEscapesAndWritesNonAsciiUnescaped()
    {
        Assert.Equal(new ComposerMessage.Error("a/b"), ComposerMessage.DecodeLine("""{"type":"error","reason":"a\/b"}"""u8.ToArray()));

        // The relaxed encoder keeps non-ASCII BMP text as UTF-8 (not "\uXXXX"), so lines stay close to the text's
        // size; an emoji is still written as an escaped surrogate pair, which decodes back.
        var message = new ComposerMessage.Done("Café 🎉", false);
        var line = ComposerMessage.EncodeLine(message);
        Assert.Contains("Café", Encoding.UTF8.GetString(line));
        Assert.Equal(message, ComposerMessage.DecodeLine(line));
    }

    [Fact]
    public void UnknownTypeAndOversizedLinesAndTextAreRejected()
    {
        var unknown = Assert.Throws<ComposerProtocolException>(
            () => ComposerMessage.DecodeLine("""{"type":"save","text":"x"}"""u8.ToArray()));
        Assert.Equal(ComposerProtocolError.Malformed, unknown.Error);

        var longLine = Enumerable.Repeat((byte)'a', ComposerMessage.MaxLineBytes + 1).ToArray();
        Assert.Equal(ComposerProtocolError.LineTooLarge,
            Assert.Throws<ComposerProtocolException>(() => ComposerMessage.DecodeLine(longLine)).Error);

        var bigText = new string('a', ComposerMessage.MaxTextBytes + 1);
        Assert.Equal(ComposerProtocolError.TextTooLarge,
            Assert.Throws<ComposerProtocolException>(() => ComposerMessage.EncodeLine(new ComposerMessage.Done(bigText, false))).Error);
        var bigLine = Encoding.UTF8.GetBytes("{\"type\":\"done\",\"submit\":false,\"text\":\"" + bigText + "\"}");
        Assert.Equal(ComposerProtocolError.TextTooLarge,
            Assert.Throws<ComposerProtocolException>(() => ComposerMessage.DecodeLine(bigLine)).Error);
    }

    [Fact]
    public void DirectoriesOversizedAndNonUtf8FilesAreRefused()
    {
        var dir = MakeTempDir();
        try
        {
            Assert.Equal(ComposerFileError.NotRegularFile, ReadError(dir));

            var big = Path.Combine(dir, "big.txt");
            File.WriteAllBytes(big, Enumerable.Repeat((byte)'a', ComposerFileRules.MaxFileBytes + 1).ToArray());
            Assert.Equal(ComposerFileError.TooLarge, ReadError(big));

            var binary = Path.Combine(dir, "binary.txt");
            File.WriteAllBytes(binary, [0x41, 0xFF, 0xFE, 0x42]);
            Assert.Equal(ComposerFileError.InvalidUtf8, ReadError(binary));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void LfAndCrLfFilesRoundTripWithTheirTrailingNewlineAndAMissingFileIsEmpty()
    {
        var dir = MakeTempDir();
        try
        {
            var lf = Path.Combine(dir, "lf.md");
            File.WriteAllText(lf, "one\ntwo\n");
            var lfInfo = ComposerFileRules.Read(lf);
            Assert.Equal(new ComposerFileContent("one\ntwo", true, ComposerLineEnding.Lf), lfInfo);
            ComposerFileRules.Write("one\nthree", lf, lfInfo);
            Assert.Equal("one\nthree\n"u8.ToArray(), File.ReadAllBytes(lf));

            var crlf = Path.Combine(dir, "crlf.md");
            File.WriteAllText(crlf, "one\r\ntwo\r\n");
            var crlfInfo = ComposerFileRules.Read(crlf);
            Assert.Equal(new ComposerFileContent("one\ntwo", true, ComposerLineEnding.CrLf), crlfInfo);
            ComposerFileRules.Write("one\nthree", crlf, crlfInfo);
            Assert.Equal("one\r\nthree\r\n"u8.ToArray(), File.ReadAllBytes(crlf));

            // No trailing newline in the original: none is added on write.
            var bare = Path.Combine(dir, "bare.md");
            File.WriteAllText(bare, "one");
            var bareInfo = ComposerFileRules.Read(bare);
            Assert.False(bareInfo.HadTrailingNewline);
            ComposerFileRules.Write("two", bare, bareInfo);
            Assert.Equal("two"u8.ToArray(), File.ReadAllBytes(bare));

            Assert.Equal(new ComposerFileContent("", false, ComposerLineEnding.Lf),
                ComposerFileRules.Read(Path.Combine(dir, "missing.md")));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    private static ComposerFileError ReadError(string path) =>
        Assert.Throws<ComposerFileException>(() => ComposerFileRules.Read(path)).Error;

    private static string MakeTempDir() =>
        Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "ComposerProtocolTests-" + Guid.NewGuid())).FullName;
}
