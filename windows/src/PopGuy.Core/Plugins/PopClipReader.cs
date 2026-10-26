using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
using YamlDotNet.Core;
using YamlDotNet.Core.Events;

namespace PopGuy.Core.Plugins;

/// <summary>Why a PopClip extension could not be read (macOS <c>PopClipReadError</c>).</summary>
public enum PopClipReadErrorKind
{
    ConfigNotFound,
    UnsupportedFormat,
    TooLarge,
    Malformed,
}

/// <summary>A refused PopClip extension; the message is the user-facing text of macOS <c>PopClipReadError</c>.</summary>
public sealed class PopClipReadException(PopClipReadErrorKind kind, string message) : Exception(message)
{
    public PopClipReadErrorKind Kind { get; } = kind;

    internal static PopClipReadException ConfigNotFound() => new(PopClipReadErrorKind.ConfigNotFound,
        "No Config.plist, Config.yaml, Config.yml, or Config.json found in the extension bundle.");

    internal static PopClipReadException UnsupportedFormat(string format) =>
        new(PopClipReadErrorKind.UnsupportedFormat, $"Unsupported config format: {format}.");

    internal static PopClipReadException TooLarge(string name) =>
        new(PopClipReadErrorKind.TooLarge, $"{name} exceeds the maximum allowed size.");

    internal static PopClipReadException Malformed(string detail) =>
        new(PopClipReadErrorKind.Malformed, $"Malformed extension config: {detail}");
}

/// <summary>
/// Reads a PopClip extension into a <see cref="PopClipConfig"/>: a <c>.popclipext</c> folder, a <c>.popclipextz</c>
/// zip, or a pasted snippet (port of macOS <c>PopClipExtensionReader.swift</c>, spec-4 §5.3). File-backed shell and
/// AppleScript sources are inlined. Nothing is executed and nothing is written to disk: YAML becomes plain
/// dictionaries, lists and strings (type tags and aliases are refused), and a zip is read in memory.
/// </summary>
public static class PopClipReader
{
    /// <summary>A config or script file (macOS <c>maxScriptBytes</c>), checked on the bytes actually read.</summary>
    public const int MaxFileBytes = 64 * 1024;

    /// <summary>A snippet, in UTF-8 bytes (macOS <c>maxSnippetBytes</c>).</summary>
    public const int MaxSnippetBytes = 256 * 1024;

    /// <summary>A <c>.popclipextz</c> file (Windows only: macOS reads no zips).</summary>
    public const int MaxArchiveBytes = 8 * 1024 * 1024;

    /// <summary>Entries in a <c>.popclipextz</c>, folders included.</summary>
    public const int MaxArchiveEntries = 256;

    /// <summary>The uncompressed sizes a <c>.popclipextz</c> declares, summed (a zip-bomb guard).</summary>
    public const long MaxArchiveUncompressedBytes = 16 * 1024 * 1024;

    /// <summary>Nesting of the config tree (JSON, YAML and plist alike).</summary>
    private const int MaxDepth = 64;

    /// <summary>The macOS search order; names match case-insensitively.</summary>
    private static readonly string[] ConfigCandidates = ["config.plist", "config.json", "config.yaml", "config.yml"];

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>Reads a <c>.popclipext</c> folder.</summary>
    public static PopClipConfig ReadFolder(string folderPath) =>
        ReadBundle(new FolderBundle(Path.TrimEndingDirectorySeparator(Path.GetFullPath(folderPath))));

    /// <summary>
    /// Reads a <c>.popclipextz</c> zip, with the config at its root or inside one top-level folder. The whole archive
    /// is refused when any entry name could escape the extension folder (zip-slip) or a cap is exceeded.
    /// </summary>
    public static PopClipConfig ReadArchive(Stream archive)
    {
        // A non-seekable stream would be buffered whole by the zip reader: buffer it here, bounded.
        if (!archive.CanSeek)
            archive = new MemoryStream(ReadBounded(archive, MaxArchiveBytes, "The archive"));
        else if (archive.Length - archive.Position > MaxArchiveBytes)
            throw PopClipReadException.TooLarge("The archive");

        ZipArchive zip;
        try
        {
            zip = new ZipArchive(archive, ZipArchiveMode.Read, leaveOpen: true);
        }
        catch (InvalidDataException)
        {
            throw PopClipReadException.Malformed("The archive is not a valid zip file.");
        }

        using (zip)
        {
            if (zip.Entries.Count > MaxArchiveEntries)
                throw PopClipReadException.TooLarge("The archive");

            var files = new Dictionary<string, ZipArchiveEntry>(StringComparer.Ordinal);
            long declared = 0;
            foreach (var entry in zip.Entries)
            {
                var name = entry.FullName.Replace('\\', '/');
                if (!IsSafeEntryName(name))
                    throw PopClipReadException.Malformed($"Archive entry '{entry.FullName}' escapes the extension folder.");
                declared += entry.Length;
                if (declared > MaxArchiveUncompressedBytes)
                    throw PopClipReadException.TooLarge("The archive");
                if (!name.EndsWith('/'))
                    files[name] = entry;
            }
            return ReadBundle(new ZipBundle(files, ArchiveRoot(files.Keys)));
        }
    }

    /// <summary>
    /// Reads a pasted snippet: an optional code fence and a <c>#popclip</c> / <c># PopClip</c> header line around
    /// YAML, or JSON when the payload starts with <c>{</c>.
    /// </summary>
    public static PopClipConfig ReadSnippet(string snippet)
    {
        if (Encoding.UTF8.GetByteCount(snippet) > MaxSnippetBytes)
            throw PopClipReadException.TooLarge("snippet");

        var payload = ExtractPayload(snippet);
        if (payload.Length == 0)
            throw PopClipReadException.Malformed("Snippet contains no decodable payload after stripping headers.");

        var trimmed = payload.Trim();
        return trimmed.StartsWith('{')
            ? PopClipConfig.FromTree(ParseJson(Encoding.UTF8.GetBytes(trimmed)))
            : PopClipConfig.FromTree(ParseYaml(payload));
    }

    // MARK: - Bundles

    /// <summary>The files of an extension folder or archive, every read size-capped and kept inside the bundle.</summary>
    private abstract class Bundle
    {
        /// <summary>Visible (not dot-prefixed) file names at the bundle root.</summary>
        public abstract IEnumerable<string> TopLevelFiles();

        public abstract byte[] ReadTopLevel(string name);

        /// <summary>A file the config names; refused when the path leaves the bundle.</summary>
        public abstract byte[] ReadContained(string relativePath, string label);
    }

    private sealed class FolderBundle(string root) : Bundle
    {
        public override IEnumerable<string> TopLevelFiles()
        {
            try
            {
                return new DirectoryInfo(root).EnumerateFiles()
                    .Where(file => (file.Attributes & FileAttributes.Hidden) == 0 && !file.Name.StartsWith('.'))
                    .Select(file => file.Name)
                    .ToList();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                throw PopClipReadException.Malformed($"Cannot read bundle directory: {e.Message}");
            }
        }

        public override byte[] ReadTopLevel(string name) => ReadFile(Path.Combine(root, name), name);

        public override byte[] ReadContained(string relativePath, string label)
        {
            // Stricter than macOS, which appends an absolute path as a component: it is refused outright.
            var escapes = PopClipReadException.Malformed($"{label} '{relativePath}' escapes the bundle directory.");
            if (Path.IsPathRooted(relativePath) || relativePath.Contains(':'))
                throw escapes;
            var full = Path.GetFullPath(Path.Combine(root, relativePath));
            if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                throw escapes;
            // A symbolic link or junction on the way could point outside the folder.
            for (var path = full; path.Length > root.Length; path = Path.GetDirectoryName(path)!)
            {
                if (IsLink(path))
                    throw escapes;
            }
            return ReadFile(full, relativePath);
        }

        private static byte[] ReadFile(string path, string label)
        {
            try
            {
                if (IsLink(path))
                    throw PopClipReadException.Malformed($"Cannot read '{label}': it is a link.");
                // Size-guard before reading, then again on the bytes read.
                if (new FileInfo(path).Length > MaxFileBytes)
                    throw PopClipReadException.TooLarge(label);
                using var stream = File.OpenRead(path);
                return ReadBounded(stream, MaxFileBytes, label);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                throw PopClipReadException.Malformed($"Cannot read '{label}': {e.Message}");
            }
        }

        private static bool IsLink(string path) =>
            (File.Exists(path) || Directory.Exists(path))
            && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    }

    private sealed class ZipBundle(IReadOnlyDictionary<string, ZipArchiveEntry> files, string root) : Bundle
    {
        public override IEnumerable<string> TopLevelFiles() => files.Keys
            .Where(name => name.StartsWith(root, StringComparison.Ordinal))
            .Select(name => name[root.Length..])
            .Where(name => !name.Contains('/') && !name.StartsWith('.'));

        public override byte[] ReadTopLevel(string name) => ReadEntry(files[root + name], name);

        public override byte[] ReadContained(string relativePath, string label)
        {
            if (NormalizeInside(root, relativePath) is not { } key)
                throw PopClipReadException.Malformed($"{label} '{relativePath}' escapes the bundle directory.");
            var entry = files.GetValueOrDefault(key)
                ?? files.FirstOrDefault(f => string.Equals(f.Key, key, StringComparison.OrdinalIgnoreCase)).Value
                ?? throw PopClipReadException.Malformed($"Cannot read '{relativePath}': not found in the archive.");
            return ReadEntry(entry, relativePath);
        }

        private static byte[] ReadEntry(ZipArchiveEntry entry, string label)
        {
            if (entry.Length > MaxFileBytes)
                throw PopClipReadException.TooLarge(label);
            try
            {
                using var stream = entry.Open();
                // The declared length is untrusted: the cap applies to the bytes inflated.
                return ReadBounded(stream, MaxFileBytes, label);
            }
            catch (InvalidDataException)
            {
                throw PopClipReadException.Malformed($"Cannot read '{label}' from the archive.");
            }
        }
    }

    private static PopClipConfig ReadBundle(Bundle bundle)
    {
        var byLowerName = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var name in bundle.TopLevelFiles())
            byLowerName[name.ToLowerInvariant()] = name;
        var configName = ConfigCandidates.Select(byLowerName.GetValueOrDefault).FirstOrDefault(n => n is not null)
            ?? throw PopClipReadException.ConfigNotFound();

        var bytes = bundle.ReadTopLevel(configName);
        var tree = Path.GetExtension(configName).ToLowerInvariant() switch
        {
            ".plist" => ParsePlist(bytes),
            ".json" => ParseJson(bytes),
            _ => ParseYaml(DecodeUtf8(bytes) ?? throw PopClipReadException.Malformed("Config YAML is not valid UTF-8.")),
        };
        return InlineFileScripts(PopClipConfig.FromTree(tree), bundle);
    }

    /// <summary>Shell and AppleScript files replace the inline source; <c>javascriptFile</c> is not inlined (macOS parity).</summary>
    private static PopClipConfig InlineFileScripts(PopClipConfig config, Bundle bundle)
    {
        string ReadScript(string path, string label) =>
            DecodeUtf8(bundle.ReadContained(path, label))
            ?? throw PopClipReadException.Malformed($"{label} '{path}' is not valid UTF-8.");

        var actions = config.Actions.Select(action =>
        {
            if (action.ShellScriptFile is { } shellFile)
                action = action with { ShellScript = ReadScript(shellFile, "shellScriptFile") };
            if (action.AppleScriptFile is { } appleFile)
                action = action with { AppleScript = ReadScript(appleFile, "appleScriptFile") };
            return action;
        }).ToList();
        return config with { Actions = actions };
    }

    // MARK: - Paths

    /// <summary>A relative, non-rooted entry name with no <c>..</c> segment (backslashes already turned into slashes).</summary>
    private static bool IsSafeEntryName(string name) =>
        name.Length > 0 && !name.StartsWith('/') && !name.Contains(':') && !name.Contains('\0')
        && !name.Split('/').Contains("..");

    /// <summary>
    /// The bundle folder inside an archive: the root when it holds a config, else its single top-level folder
    /// (ignoring the Finder <c>__MACOSX</c> folder).
    /// </summary>
    private static string ArchiveRoot(IEnumerable<string> names)
    {
        var visible = names.Where(n => !n.StartsWith("__MACOSX/", StringComparison.Ordinal)).ToList();
        if (visible.Any(n => ConfigCandidates.Contains(n.ToLowerInvariant())))
            return "";
        var folders = visible.Select(n => n.Split('/')[0]).Distinct().ToList();
        return folders.Count == 1 && visible.All(n => n.Contains('/')) ? folders[0] + "/" : "";
    }

    /// <summary><paramref name="root"/> + <paramref name="relativePath"/> with <c>.</c> and <c>..</c> resolved, or null when it leaves the root.</summary>
    private static string? NormalizeInside(string root, string relativePath)
    {
        if (relativePath.Length == 0 || relativePath[0] is '/' or '\\' || relativePath.Contains(':'))
            return null;
        var rootDepth = root.Split('/', StringSplitOptions.RemoveEmptyEntries).Length;
        var segments = root.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        foreach (var segment in relativePath.Split('/', '\\'))
        {
            if (segment is "" or ".")
                continue;
            if (segment == "..")
            {
                if (segments.Count == rootDepth)
                    return null;
                segments.RemoveAt(segments.Count - 1);
            }
            else
            {
                segments.Add(segment);
            }
        }
        return string.Join('/', segments);
    }

    // MARK: - Bytes

    /// <summary>At most <paramref name="cap"/> bytes; one more refuses the file.</summary>
    private static byte[] ReadBounded(Stream stream, int cap, string label)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        int read;
        while ((read = stream.Read(chunk, 0, chunk.Length)) > 0)
        {
            if (buffer.Length + read > cap)
                throw PopClipReadException.TooLarge(label);
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }

    /// <summary>Strict UTF-8 without a byte-order mark, or null.</summary>
    private static string? DecodeUtf8(byte[] bytes)
    {
        try
        {
            var text = StrictUtf8.GetString(bytes);
            return text.StartsWith('﻿') ? text[1..] : text;
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    // MARK: - Snippet

    /// <summary>Port of macOS <c>extractPayload</c>: normalize line ends, strip the code fence, then the PopClip header.</summary>
    private static string ExtractPayload(string snippet)
    {
        var lines = snippet.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').ToList();

        if (lines.Count > 0 && lines[0].Trim().StartsWith("```", StringComparison.Ordinal))
        {
            lines.RemoveAt(0);
            var closing = lines.FindLastIndex(l => l.Trim().StartsWith("```", StringComparison.Ordinal));
            if (closing >= 0)
                lines.RemoveAt(closing);
        }

        if (lines.Count > 0 && lines[0].Trim().ToLowerInvariant().Replace(" ", "") == "#popclip")
            lines.RemoveAt(0);

        return string.Join('\n', lines);
    }

    // MARK: - Parsers (each builds the plain tree PopClipConfig decodes)

    private static object? ParseJson(byte[] bytes)
    {
        var json = bytes.AsSpan();
        if (json.StartsWith(Encoding.UTF8.Preamble))
            json = json[Encoding.UTF8.Preamble.Length..];
        try
        {
            using var doc = JsonDocument.Parse(json.ToArray(), new JsonDocumentOptions { MaxDepth = MaxDepth });
            return JsonNode(doc.RootElement);
        }
        catch (JsonException e)
        {
            throw PopClipReadException.Malformed(e.Message);
        }
    }

    private static object? JsonNode(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => element.EnumerateObject()
            .Aggregate(new Dictionary<string, object?>(), (map, p) => { map[p.Name] = JsonNode(p.Value); return map; }),
        JsonValueKind.Array => element.EnumerateArray().Select(JsonNode).ToList(),
        JsonValueKind.String => element.GetString(),
        JsonValueKind.Number => element.GetDouble(),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => null,
    };

    /// <summary>
    /// YAML read as parser events, never through the deserializer, so nothing is ever instantiated. Every scalar is
    /// a string (a plain <c>~</c>, <c>null</c> or empty value is null). Any type tag (<c>!!binary</c>,
    /// <c>!Some.Type</c>, a bare <c>!</c>) and any alias are refused; one document only.
    /// </summary>
    private static object? ParseYaml(string text)
    {
        try
        {
            var parser = new Parser(new StringReader(text));
            parser.Consume<StreamStart>();
            if (parser.TryConsume<StreamEnd>(out _))
                return null;
            parser.Consume<DocumentStart>();
            var root = YamlNode(parser, 0);
            parser.Consume<DocumentEnd>();
            if (!parser.TryConsume<StreamEnd>(out _))
                throw PopClipReadException.Malformed("The config holds more than one YAML document.");
            return root;
        }
        catch (YamlException e)
        {
            throw PopClipReadException.Malformed(e.Message);
        }
    }

    private static object? YamlNode(IParser parser, int depth)
    {
        if (depth > MaxDepth)
            throw PopClipReadException.Malformed("The config is nested too deeply.");

        var current = parser.Consume<ParsingEvent>();
        if (current is AnchorAlias)
            throw PopClipReadException.Malformed("YAML aliases are not supported.");
        if (current is NodeEvent { Tag.IsEmpty: false } tagged)
            throw PopClipReadException.Malformed($"YAML type tags are not allowed ('{tagged.Tag}').");

        switch (current)
        {
            case Scalar scalar:
                return scalar.Style == ScalarStyle.Plain && scalar.Value is "" or "~" or "null" or "Null" or "NULL"
                    ? null
                    : scalar.Value;
            case SequenceStart:
                var list = new List<object?>();
                while (!parser.TryConsume<SequenceEnd>(out _))
                    list.Add(YamlNode(parser, depth + 1));
                return list;
            case MappingStart:
                var map = new Dictionary<string, object?>();
                while (!parser.TryConsume<MappingEnd>(out _))
                {
                    var key = YamlNode(parser, depth + 1) as string
                        ?? throw PopClipReadException.Malformed("A YAML mapping key must be text.");
                    map[key] = YamlNode(parser, depth + 1);
                }
                return map;
            default:
                throw PopClipReadException.Malformed($"Unexpected YAML content ({current.GetType().Name}).");
        }
    }

    /// <summary>
    /// An XML property list (the DTD is ignored and never fetched). A binary plist is refused: .NET has no decoder
    /// for it and PopGuy does not ship one.
    /// </summary>
    private static object? ParsePlist(byte[] bytes)
    {
        if (bytes.AsSpan().StartsWith("bplist"u8))
            throw PopClipReadException.UnsupportedFormat("binary plist");
        try
        {
            var settings = new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Ignore,
                XmlResolver = null,
                IgnoreComments = true,
                IgnoreProcessingInstructions = true,
            };
            using var reader = XmlReader.Create(new MemoryStream(bytes), settings);
            var plist = XDocument.Load(reader).Root;
            if (plist?.Name.LocalName != "plist" || plist.Elements().FirstOrDefault() is not { } top)
                throw PopClipReadException.Malformed("The property list is empty.");
            return PlistNode(top, 0);
        }
        catch (XmlException e)
        {
            throw PopClipReadException.Malformed(e.Message);
        }
    }

    private static object? PlistNode(XElement element, int depth)
    {
        if (depth > MaxDepth)
            throw PopClipReadException.Malformed("The config is nested too deeply.");

        switch (element.Name.LocalName)
        {
            case "dict":
                var map = new Dictionary<string, object?>();
                var children = element.Elements().ToList();
                if (children.Count % 2 != 0)
                    throw PopClipReadException.Malformed("A property list dictionary is missing a value.");
                for (var i = 0; i + 1 < children.Count; i += 2)
                {
                    if (children[i].Name.LocalName != "key")
                        throw PopClipReadException.Malformed("A property list dictionary is missing a key.");
                    map[children[i].Value] = PlistNode(children[i + 1], depth + 1);
                }
                return map;
            case "array":
                return element.Elements().Select(e => PlistNode(e, depth + 1)).ToList();
            case "string":
                return element.Value;
            case "integer" or "real":
                return double.TryParse(element.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
                    ? number
                    : null;
            case "true":
                return true;
            case "false":
                return false;
            case "date" or "data":
                // Never read as text by the decoder.
                return null;
            default:
                throw PopClipReadException.Malformed($"Unknown property list element <{element.Name.LocalName}>.");
        }
    }
}
