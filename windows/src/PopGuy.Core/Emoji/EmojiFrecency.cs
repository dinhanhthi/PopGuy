using System.Text.Json;
using System.Text.Json.Serialization;
using PopGuy.Core.Json;

namespace PopGuy.Core.Emojis;

/// <summary>
/// Emoji usage history for "Frequently Used" and search ranking (macOS <c>EmojiFrecency.swift</c>): count × exponential
/// decay (half-life 7 days). Kept in its own file (<see cref="AppPaths.EmojiUsageFile"/>), not in settings.json, so a
/// pick never fires a settings change. A missing or corrupt file loads as empty, and write errors are swallowed (the
/// history is not critical state). Not thread-safe: owned by the picker model.
/// </summary>
public sealed class EmojiFrecency
{
    public sealed record Entry(
        [property: JsonPropertyName("count")] int Count,
        [property: JsonPropertyName("lastUsed")] DateTimeOffset LastUsed);

    private const double HalfLifeDays = 7.0;

    private readonly string _path;
    private Dictionary<string, Entry> _entries = [];

    public EmojiFrecency(string path)
    {
        _path = path;
        Reload();
    }

    public IReadOnlyDictionary<string, Entry> Entries => _entries;

    /// <summary>
    /// Re-reads the history from the file, so a file deleted elsewhere (Settings "Clear") is never written back from this
    /// cached copy.
    /// </summary>
    public void Reload()
    {
        try
        {
            using var stream = File.OpenRead(_path);
            var loaded = JsonSerializer.Deserialize<Dictionary<string, Entry>>(stream, PopGuyJson.Options) ?? [];
            // A JSON null value gets past the nullable annotations and would make Score/Top throw: treat it as corrupt.
            _entries = loaded.Values.Contains(null!) ? [] : loaded;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            _entries = [];
        }
    }

    public void Record(string emoji, DateTimeOffset? now = null)
    {
        var time = now ?? DateTimeOffset.UtcNow;
        var count = _entries.TryGetValue(emoji, out var entry) ? entry.Count : 0;
        _entries[emoji] = new Entry(count + 1, time);
        Save();
    }

    public double Score(string emoji, DateTimeOffset? now = null)
    {
        if (!_entries.TryGetValue(emoji, out var entry))
            return 0;
        var ageDays = Math.Max(0, ((now ?? DateTimeOffset.UtcNow) - entry.LastUsed).TotalSeconds) / 86_400;
        return entry.Count * Math.Pow(0.5, ageDays / HalfLifeDays);
    }

    /// <summary>The <paramref name="n"/> highest-scoring emoji; ties go to the most recently used.</summary>
    public IReadOnlyList<string> Top(int n, DateTimeOffset? now = null)
    {
        var time = now ?? DateTimeOffset.UtcNow;
        return
        [
            .. _entries
                .Select(p => (Emoji: p.Key, Score: Score(p.Key, time), p.Value.LastUsed))
                .OrderByDescending(r => r.Score)
                .ThenByDescending(r => r.LastUsed)
                .Take(Math.Max(0, n))
                .Select(r => r.Emoji),
        ];
    }

    public void Clear()
    {
        _entries = [];
        try
        {
            File.Delete(_path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    private void Save()
    {
        try
        {
            PopGuyJson.WriteFileAtomically(_path, _entries);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}
