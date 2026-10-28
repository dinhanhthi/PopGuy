using System.Globalization;
using System.Text;
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
/// <see cref="MaxEntries"/>. Writes are atomic and run in the background, one after another; changes made while a write
/// is queued share it (only the latest list is written). <see cref="FlushAsync"/> waits for them. A missing or corrupt file loads as empty, and write errors are swallowed (history is not critical
/// state). Callers check the historyEnabled setting before recording. <see cref="Changed"/> fires after every change,
/// on the thread that made it.
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

    /// <summary>A record was added or deleted, or the history was cleared. Raised outside the store's lock.</summary>
    public event EventHandler? Changed;

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
            QueueWriteLocked();
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// The records of <paramref name="actionName"/> (all actions when null) whose input or output fuzzily matches
    /// <paramref name="query"/> (<see cref="HistorySearch.Matches"/>; a blank query matches all), newest first.
    /// </summary>
    public IReadOnlyList<HistoryRecord> Query(string? actionName, string query)
    {
        var searching = !string.IsNullOrWhiteSpace(query);
        return [.. Records.Where(record =>
            (actionName is null || record.ActionName == actionName)
            && (!searching || HistorySearch.Matches(query, record.Input) || HistorySearch.Matches(query, record.Output)))];
    }

    /// <summary>Removes the record with <paramref name="id"/> and saves; false when there is none.</summary>
    public bool Delete(Guid id)
    {
        lock (_gate)
        {
            if (_records.RemoveAll(record => record.Id == id) == 0)
                return false;
            QueueWriteLocked();
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>Removes every record and saves (an empty array).</summary>
    public void ClearAll()
    {
        lock (_gate)
        {
            if (_records.Count == 0)
                return;
            _records.Clear();
            QueueWriteLocked();
        }
        Changed?.Invoke(this, EventArgs.Empty);
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

    /// <summary>Saves the list in the background, once for every change made until that save starts. Under the lock.</summary>
    private void QueueWriteLocked()
    {
        // A queued write that has not started yet is always the last one, and it snapshots when it starts.
        if (_writeQueued)
            return;
        _writeQueued = true;
        _writes = _writes.ContinueWith(_ => WriteLatest(), TaskScheduler.Default);
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

/// <summary>The History page's search (macOS <c>HistoryView.fuzzyMatches</c>, spec-3 §5.6).</summary>
public static class HistorySearch
{
    /// <summary>
    /// Fuzzy subsequence match (fzf/Sublime style): every non-whitespace character of <paramref name="query"/> appears in
    /// <paramref name="text"/>, in order, ignoring case. A query of only whitespace matches everything.
    /// </summary>
    public static bool Matches(string query, string text)
    {
        var haystack = text.ToLowerInvariant();
        var from = 0;
        foreach (var rune in query.ToLowerInvariant().EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune))
                continue;
            var found = haystack.IndexOf(rune.ToString(), from, StringComparison.Ordinal);
            if (found < 0)
                return false;
            from = found + rune.Utf16SequenceLength;
        }
        return true;
    }
}
