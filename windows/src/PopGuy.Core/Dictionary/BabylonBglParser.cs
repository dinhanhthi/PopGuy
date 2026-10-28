using System.Buffers;
using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Unicode;

namespace PopGuy.Core.Dictionaries;

/// <summary>One BGL entry: the headword, its plain-text definition and the alternates (other forms) found with it.</summary>
public sealed record BabylonBglEntry(string Headword, string Definition, IReadOnlyList<string> Alternates);

/// <summary>
/// Reader of the Babylon .bgl container (macOS BabylonBGLParser.swift, spec-4 §3.6): a header, then one gzip member
/// holding a stream of typed blocks. Short (1, 7, 10, 13) and long (11) entry blocks become entries; the others
/// (metadata, resources) are skipped. Charset metadata is not consulted: text is UTF-8, else Windows-1252, else Latin-1.
/// <para>
/// UNTRUSTED DATA: every length, offset and count is checked before it is used, and the input is bounded:
/// <list type="bullet">
/// <item>the file: <see cref="MaxFileBytes"/> (macOS);</item>
/// <item>the inflated stream: <see cref="MaxDecompressedBytes"/> (macOS), counted while inflating, so a zip bomb or a
/// trailer that lies about the size is refused; the stream is read block by block, never held whole;</item>
/// <item>a block: <see cref="MaxBlockBytes"/> (macOS);</item>
/// <item>Windows only, to bound the index on disk: <see cref="MaxEntries"/> entries, <see cref="MaxTerms"/> headwords
/// and alternates, the first <see cref="MaxAlternatesPerEntry"/> alternates of an entry (real dictionaries have well
/// under a million entries, with a few alternates each).</item>
/// </list>
/// Anything malformed is a Decoding <see cref="DictionaryLookupException"/>; nothing from the file is put in an error.
/// </para>
/// </summary>
public sealed class BabylonBglParser
{
    public const long MaxFileBytes = 200L * 1024 * 1024;
    public const long MaxDecompressedBytes = 512L * 1024 * 1024;
    public const int MaxBlockBytes = 16 * 1024 * 1024;
    public const int MaxEntries = 5_000_000;
    public const int MaxTerms = 20_000_000;
    public const int MaxAlternatesPerEntry = 1024;

    private const RegexOptions HtmlOptions =
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking;

    // Linear-time matching: definitions are untrusted and up to a block long.
    private static readonly Regex LineBreakTag = new(@"<br\s*/?>", HtmlOptions);
    private static readonly Regex BlockOpenTag = new("<(table|tr|td|p|div|blockquote|dd|dt)[^>]*>", HtmlOptions);
    private static readonly Regex BlockCloseTag = new("</(p|div|li|tr|td|table|blockquote|dd|dt)>", HtmlOptions);
    private static readonly Regex ListItemTag = new("<li[^>]*>", HtmlOptions);
    private static readonly Regex AnyTag = new("<[^>]+>", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex StyleArtifact =
        new(@"#[A-Za-z0-9_]+\{[^}]*\}", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex InlinePhonetics =
        new(@"^(\[[^\]\n]+\])\s*(\S)", RegexOptions.Multiline | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    // Swift's newline set.
    private static readonly char[] Newlines = ['\n', '\v', '\f', '\r', '\u0085', '\u2028', '\u2029'];

    // The bytes Windows-1252 leaves undefined: text holding one is read as Latin-1.
    private static readonly SearchValues<byte> Cp1252Undefined = SearchValues.Create([0x81, 0x8D, 0x8F, 0x90, 0x9D]);
    private static readonly Encoding Windows1252 = CodePagesEncodingProvider.Instance.GetEncoding(1252)!;

    private readonly long _maxDecompressedBytes;

    public BabylonBglParser() : this(MaxDecompressedBytes) { }

    /// <summary>A lower inflate cap than <see cref="MaxDecompressedBytes"/>.</summary>
    internal BabylonBglParser(long maxDecompressedBytes) => _maxDecompressedBytes = maxDecompressedBytes;

    /// <summary>The entries of the .bgl file at <paramref name="path"/>, read as they are enumerated.</summary>
    public IEnumerable<BabylonBglEntry> ReadFile(string path)
    {
        using var file = File.OpenRead(path);
        if (file.Length > MaxFileBytes)
            throw Error("BGL file is too large to index.");
        var bytes = new byte[file.Length];
        file.ReadExactly(bytes);
        return Read(bytes);
    }

    /// <summary>The entries of a whole .bgl file, read as they are enumerated; the header is checked at once.</summary>
    public IEnumerable<BabylonBglEntry> Read(byte[] bytes)
    {
        var (start, length) = DeflateRange(bytes);
        return ReadEntries(bytes, start, length);
    }

    /// <summary>Where the raw deflate data of the gzip member sits (the header fields are skipped by hand, as on macOS;
    /// the CRC is not verified).</summary>
    private (int Start, int Length) DeflateRange(byte[] bytes)
    {
        if (bytes.Length < 18)
            throw Error("BGL file is too short.");
        if (bytes[0] != 0x12 || bytes[1] != 0x34 || bytes[2] != 0x00 || bytes[3] is not (0x01 or 0x02))
            throw Error("Invalid BGL header.");
        var gzipOffset = bytes[4] << 8 | bytes[5];
        if (gzipOffset < 6 || gzipOffset >= bytes.Length)
            throw Error("Invalid BGL gzip offset.");

        var member = bytes.AsSpan(gzipOffset);
        if (member.Length < 18 || member[0] != 0x1f || member[1] != 0x8b || member[2] != 0x08)
            throw Error("BGL payload is not a gzip deflate stream.");
        var flags = member[3];
        long cursor = 10;
        if ((flags & 0x04) != 0) // FEXTRA
        {
            if (cursor + 2 > member.Length)
                throw Error("Invalid gzip extra field.");
            cursor += 2 + BinaryPrimitives.ReadUInt16LittleEndian(member[(int)cursor..]);
        }
        if ((flags & 0x08) != 0) // FNAME
            cursor = SkipZeroTerminated(member, cursor);
        if ((flags & 0x10) != 0) // FCOMMENT
            cursor = SkipZeroTerminated(member, cursor);
        if ((flags & 0x02) != 0) // FHCRC
            cursor += 2;

        var trailer = member.Length - 8;
        if (cursor >= trailer)
            throw Error("Invalid gzip member layout.");
        // ISIZE: an early refusal only; the inflated bytes are counted anyway.
        if (BinaryPrimitives.ReadUInt32LittleEndian(member[(trailer + 4)..]) > _maxDecompressedBytes)
            throw Error("BGL index is too large to load.");
        return (gzipOffset + (int)cursor, trailer - (int)cursor);
    }

    private static long SkipZeroTerminated(ReadOnlySpan<byte> member, long cursor)
    {
        for (var i = cursor; i < member.Length; i++)
        {
            if (member[(int)i] == 0)
                return i + 1;
        }
        throw Error("Invalid gzip string field.");
    }

    private IEnumerable<BabylonBglEntry> ReadEntries(byte[] bytes, int start, int length)
    {
        using var blocks = new BlockReader(
            new DeflateStream(new MemoryStream(bytes, start, length, writable: false), CompressionMode.Decompress),
            _maxDecompressedBytes);
        int entries = 0;
        long terms = 0;
        while (blocks.Next() is var (type, payload))
        {
            if (payload.Length == 0)
                continue;
            var entry = type switch
            {
                1 or 7 or 10 or 13 => ShortEntry(payload),
                11 => LongEntry(payload),
                _ => null,
            };
            if (entry is null)
                continue;
            terms += 1 + entry.Alternates.Count;
            if (++entries > MaxEntries || terms > MaxTerms)
                throw Error("BGL file has too many entries.");
            yield return entry;
        }
    }

    /// <summary>Blocks of the inflated stream: a header byte (type in the low nibble; the high nibble is the length
    /// minus 4, or below 4 the width minus 1 of a big-endian length that follows), then the payload.</summary>
    private sealed class BlockReader(Stream stream, long maxBytes) : IDisposable
    {
        private long _read;

        public (int Type, byte[] Payload)? Next()
        {
            Span<byte> header = stackalloc byte[1];
            if (Fill(header) == 0)
                return null;
            var type = header[0] & 0x0f;
            var marker = header[0] >> 4;
            long length = marker - 4;
            if (marker < 4)
            {
                Span<byte> size = stackalloc byte[marker + 1];
                if (Fill(size) < size.Length)
                    throw Error("BGL integer exceeds stream size.");
                length = BigEndian(size);
            }
            if (length > MaxBlockBytes)
                throw Error("BGL block is too large.");
            var payload = new byte[length];
            if (Fill(payload) < payload.Length)
                throw Error("BGL block length exceeds stream size.");
            return (type, payload);
        }

        public void Dispose() => stream.Dispose();

        /// <summary>Reads until <paramref name="buffer"/> is full or the stream ends; returns the bytes read.</summary>
        private int Fill(Span<byte> buffer)
        {
            var total = 0;
            try
            {
                while (total < buffer.Length && stream.Read(buffer[total..]) is var read and > 0)
                    total += read;
            }
            catch (InvalidDataException)
            {
                throw Error("Could not decompress BGL data.");
            }
            _read += total;
            if (_read > maxBytes)
                throw Error("BGL data inflates past the size limit.");
            return total;
        }
    }

    // MARK: - Entries

    /// <summary>1-byte word length, 2-byte definition length, then 1-byte-length alternates to the end.</summary>
    private static BabylonBglEntry? ShortEntry(byte[] payload)
    {
        var cursor = 0;
        var word = Field(payload, ref cursor, 1);
        var definition = Field(payload, ref cursor, 2);
        var alternates = new List<string>();
        while (cursor < payload.Length)
            AddAlternate(alternates, Field(payload, ref cursor, 1));
        return MakeEntry(word, definition, alternates);
    }

    /// <summary>5-byte word length, a 4-byte alternate count, 4-byte-length alternates (an empty one ends them), then a
    /// 4-byte definition length. Each alternate takes at least 4 bytes, so a huge count ends at the payload's end.</summary>
    private static BabylonBglEntry? LongEntry(byte[] payload)
    {
        var cursor = 0;
        var word = Field(payload, ref cursor, 5);
        var count = UInt(payload, ref cursor, 4);
        var alternates = new List<string>();
        for (long i = 0; i < count; i++)
        {
            var alternate = Field(payload, ref cursor, 4);
            if (alternate.IsEmpty)
                break;
            AddAlternate(alternates, alternate);
        }
        var definition = Field(payload, ref cursor, 4);
        return MakeEntry(word, definition, alternates);
    }

    private static void AddAlternate(List<string> alternates, ReadOnlySpan<byte> bytes)
    {
        if (alternates.Count < MaxAlternatesPerEntry && Decode(bytes).Trim() is { Length: > 0 } alternate)
            alternates.Add(alternate);
    }

    /// <summary>Null when the headword or the cleaned definition is empty. Alternates: without the headword, distinct,
    /// sorted.</summary>
    private static BabylonBglEntry? MakeEntry(ReadOnlySpan<byte> word, ReadOnlySpan<byte> definition, List<string> alternates)
    {
        var headword = Decode(word).Trim();
        if (headword.Length == 0)
            return null;
        var text = CleanDefinition(definition);
        if (text.Length == 0)
            return null;
        return new BabylonBglEntry(headword, text,
            alternates.Where(a => a != headword).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList());
    }

    private static ReadOnlySpan<byte> Field(byte[] payload, ref int cursor, int width)
    {
        var length = UInt(payload, ref cursor, width);
        if (length > payload.Length - cursor)
            throw Error("BGL entry length exceeds block size.");
        var field = payload.AsSpan(cursor, (int)length);
        cursor += (int)length;
        return field;
    }

    private static long UInt(byte[] payload, ref int cursor, int width)
    {
        if (width > payload.Length - cursor)
            throw Error("BGL integer exceeds stream size.");
        var value = BigEndian(payload.AsSpan(cursor, width));
        cursor += width;
        return value;
    }

    /// <summary>An unsigned big-endian integer of 1 to 5 bytes.</summary>
    private static long BigEndian(ReadOnlySpan<byte> bytes)
    {
        long value = 0;
        foreach (var b in bytes)
            value = value << 8 | b;
        return value;
    }

    // MARK: - Text

    private static string Decode(ReadOnlySpan<byte> bytes)
    {
        if (Utf8.IsValid(bytes))
            return Encoding.UTF8.GetString(bytes);
        return bytes.ContainsAny(Cp1252Undefined) ? Encoding.Latin1.GetString(bytes) : Windows1252.GetString(bytes);
    }

    /// <summary>The definition as plain text: the trailing field section dropped, HTML layout turned into line breaks,
    /// the other tags removed, common entities decoded, Babylon style and sound lines removed, a leading [phonetics] on
    /// its own line, then trimmed non-empty lines.</summary>
    private static string CleanDefinition(ReadOnlySpan<byte> bytes)
    {
        // The field section starts at 0x14 followed by anything but a space.
        for (var i = 0; i + 1 < bytes.Length; i++)
        {
            if (bytes[i] == 0x14 && bytes[i + 1] != 0x20)
            {
                bytes = bytes[..i];
                break;
            }
        }

        var text = Decode(bytes);
        text = LineBreakTag.Replace(text, "\n");
        text = BlockOpenTag.Replace(text, "\n");
        text = BlockCloseTag.Replace(text, "\n");
        text = ListItemTag.Replace(text, "\n- ");
        // One pass removes every tag: removing a tag never forms a new one.
        text = AnyTag.Replace(text, "");
        text = text.Replace("&nbsp;", " ").Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">")
            .Replace("&quot;", "\"").Replace("&#39;", "'");
        // Removing one can form another ("#a#b{x}{y}"): repeat, a bounded number of times.
        for (var pass = 0; pass < 8 && StyleArtifact.IsMatch(text); pass++)
            text = StyleArtifact.Replace(text, "");
        text = string.Join('\n', text.Split(Newlines).Where(line => !IsSoundLine(line)));
        text = InlinePhonetics.Replace(text, "$1\n$2");
        return string.Join('\n', text.Split(Newlines).Select(line => line.Trim()).Where(line => line.Length > 0));
    }

    private static bool IsSoundLine(string line)
    {
        var lowered = line.Trim().ToLowerInvariant();
        return lowered.StartsWith("sound\\", StringComparison.Ordinal)
            || lowered.StartsWith("sound/", StringComparison.Ordinal)
            || lowered.StartsWith("sound ", StringComparison.Ordinal)
            || lowered.StartsWith("sound:", StringComparison.Ordinal);
    }

    private static DictionaryLookupException Error(string detail) => DictionaryLookupException.Decoding(detail);
}
