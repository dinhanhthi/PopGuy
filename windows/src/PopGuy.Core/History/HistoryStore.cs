using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using PopGuy.Core.Actions;
using PopGuy.Core.Json;

namespace PopGuy.Core.History;

/// <summary>
/// One logged action run (macOS <c>HistoryRecord.swift</c>, spec-3 §4), with the macOS JSON keys. Null optionals are
/// omitted. <see cref="SourceBundleId"/> holds the source process's exe name on Windows.
/// </summary>
public sealed record HistoryRecord
{
    [JsonPropertyName("id")] public Guid Id { get; init; } = Guid.NewGuid();

    /// <summary>When the run finished, in UTC to the second (written as ISO-8601, e.g. <c>2026-09-25T10:15:30Z</c>).</summary>
    [JsonPropertyName("timestamp")] public DateTime Timestamp { get; init; } = WholeSecondsUtcNow();

    /// <summary>"Improve", "Translate", "Speak", "Look up", ... or a custom action's title.</summary>
    [JsonPropertyName("actionName")] public required string ActionName { get; init; }

    /// <summary>Null for runs without a provider (Speak, scripts, dictionaries), which set <see cref="ProviderLabel"/>.</summary>
    [JsonPropertyName("providerKind")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ProviderKind? ProviderKind { get; init; }

    [JsonPropertyName("providerLabel")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ProviderLabel { get; init; }

    [JsonPropertyName("model")] public required string Model { get; init; }

    [JsonPropertyName("sourceBundleID")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SourceBundleId { get; init; }

    [JsonPropertyName("sourceAppName")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SourceAppName { get; init; }

    [JsonPropertyName("durationMs")] public required int DurationMs { get; init; }
    [JsonPropertyName("success")] public required bool Success { get; init; }

    [JsonPropertyName("errorMessage")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ErrorMessage { get; init; }

    /// <summary>The input text, or a preview when <see cref="Truncated"/>.</summary>
    [JsonPropertyName("input")] public required string Input { get; init; }

    /// <summary>The output text, or a preview when <see cref="Truncated"/>; "" on failure.</summary>
    [JsonPropertyName("output")] public required string Output { get; init; }

    /// <summary>True when the input or output was shortened to a preview. Set by <see cref="HistoryStore.Record"/>.</summary>
    [JsonPropertyName("truncated")] public bool Truncated { get; init; }

    private static DateTime WholeSecondsUtcNow()
    {
        var now = DateTime.UtcNow;
        return now.AddTicks(-(now.Ticks % TimeSpan.TicksPerSecond));
    }
}

/// <summary>
/// The capped log of action runs in history.json (macOS <c>HistoryStore.swift</c>): newest first, at most
/// <see cref="MaxEntries"/>. Writes are atomic and run in the background, one after another; records added while a write
/// is queued share it (only the latest list is written). <see cref="FlushAsync"/> waits for them. A missing or corrupt file loads as empty, and write errors are swallowed (history is not critical
/// state). Callers check the historyEnabled setting before recording.
/// </summary>
public sealed class HistoryStore
{
    public const int MaxEntries = 500;

    private const int PreviewMaxChars = 240;
    private const int ErrorMaxChars = 500;

    private readonly string _path;
    private readonly Lock _gate = new();
    private readonly List<HistoryRecord> _records;
    private Task _writes = Task.CompletedTask;
    private bool _writeQueued;

    public HistoryStore(AppPaths paths)
    {
        _path = paths.HistoryFile;
        _records = Load();
    }

    /// <summary>A snapshot of the records, newest first.</summary>
    public IReadOnlyList<HistoryRecord> Records
    {
        get
        {
            lock (_gate)
                return [.. _records];
        }
    }

    /// <summary>
    /// Adds a finished run as the newest record and saves in the background. With <paramref name="storeFullText"/> off
    /// (the historyStoreFullText setting), long input and output are kept as a first/last preview.
    /// </summary>
    public void Record(HistoryRecord record, bool storeFullText)
    {
        var input = storeFullText ? record.Input : Preview(record.Input);
        var output = storeFullText ? record.Output : Preview(record.Output);
        var stored = record with
        {
            Input = input,
            Output = output,
            Truncated = input != record.Input || output != record.Output,
            ErrorMessage = record.ErrorMessage is { } error ? Prefix(error, ErrorMaxChars) : null,
        };
        lock (_gate)
        {
            _records.Insert(0, stored);
            if (_records.Count > MaxEntries)
                _records.RemoveRange(MaxEntries, _records.Count - MaxEntries);
            // A queued write that has not started yet is always the last one, and it snapshots when it starts.
            if (_writeQueued)
                return;
            _writeQueued = true;
            _writes = _writes.ContinueWith(_ => WriteLatest(), TaskScheduler.Default);
        }
    }

    /// <summary>Completes when every save started so far has finished.</summary>
    public Task FlushAsync()
    {
        lock (_gate)
            return _writes;
    }

    // MARK: - Preview (spec-3 §4)

    /// <summary>More than 24 words: the first 12 and the last 12; then more than 240 characters: the first and last 120.</summary>
    private static string Preview(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var preview = words.Length > 24 ? string.Join(' ', words[..12]) + " … " + string.Join(' ', words[^12..]) : text;
        var chars = new StringInfo(preview);
        if (chars.LengthInTextElements <= PreviewMaxChars)
            return preview;
        const int half = PreviewMaxChars / 2;
        return chars.SubstringByTextElements(0, half) + " … " + chars.SubstringByTextElements(chars.LengthInTextElements - half);
    }

    /// <summary>The first <paramref name="max"/> characters (grapheme clusters, as Swift counts them).</summary>
    private static string Prefix(string text, int max)
    {
        var chars = new StringInfo(text);
        return chars.LengthInTextElements <= max ? text : chars.SubstringByTextElements(0, max);
    }

    // MARK: - File

    private List<HistoryRecord> Load()
    {
        try
        {
            // A null element is not caught by the nullable annotations; drop it.
            var records = JsonSerializer.Deserialize<List<HistoryRecord?>>(File.ReadAllText(_path), PopGuyJson.Options) ?? [];
            return [.. records.OfType<HistoryRecord>()];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            return [];
        }
    }

    private void WriteLatest()
    {
        HistoryRecord[] records;
        lock (_gate)
        {
            _writeQueued = false;
            records = [.. _records];
        }
        try
        {
            PopGuyJson.WriteFileAtomically(_path, records);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}
