using System.Globalization;
using System.Text;
using Microsoft.Data.Sqlite;
using PopGuy.Core.Settings;

namespace PopGuy.Core.Dictionaries;

/// <summary>
/// One SQLite index per Babylon dictionary, <c>&lt;id&gt;.sqlite</c> in the cache directory (macOS
/// BabylonBGLIndexCache.swift, schema_version 1: tables entries and terms, index terms_term, a meta row).
/// <para>
/// Nothing is kept in memory: a lookup opens the index read-only, runs one indexed query and closes it. The index is
/// valid while its meta row matches the schema version, the dictionary id and the file's path, modification time and
/// size; otherwise the file is parsed again and the index rebuilt in a temporary file moved into place, so a failure
/// never leaves a half-built index. Unlike macOS, an index that cannot be written fails the lookup (no in-memory copy).
/// </para>
/// SQL is parameterized. Connections are not pooled, so no file handle outlives a lookup and the index can be replaced.
/// </summary>
public sealed class BabylonIndexCache(string directory)
{
    /// <summary>Bump when the schema or <see cref="NormalizedTerm"/> changes.</summary>
    private const int SchemaVersion = 1;

    private static readonly Lazy<BabylonIndexCache> SharedCache =
        new(() => new(Path.Combine(AppPaths.Resolve().CacheDirectory, "BabylonIndexes")));

    private readonly Lock _gate = new();

    /// <summary>The app's indexes, in <c>%LOCALAPPDATA%\PopGuyData\BabylonIndexes</c>.</summary>
    public static BabylonIndexCache Shared => SharedCache.Value;

    /// <summary>
    /// The entries whose headword or an alternate matches <paramref name="term"/> (case and diacritics ignored), in file
    /// order and without alternates. Builds the index first when it is missing or stale. Runs off the caller's thread,
    /// one lookup at a time; a cancelled caller stops waiting, and a build it started still finishes.
    /// </summary>
    public Task<IReadOnlyList<BabylonBglEntry>> LookupAsync(
        BabylonDictionary dictionary, string term, CancellationToken ct) =>
        Task.Run(() =>
        {
            lock (_gate)
                return Lookup(dictionary, term);
        }, CancellationToken.None).WaitAsync(ct);

    /// <summary>Trimmed, case and diacritics folded (the same for the index and the query): "Résumé" is "resume".</summary>
    internal static string NormalizedTerm(string term)
    {
        string decomposed;
        try
        {
            decomposed = term.Trim().Normalize(NormalizationForm.FormD);
        }
        catch (ArgumentException)
        {
            // Invalid UTF-16 (a lone surrogate) cannot be normalized.
            return term.Trim().ToLowerInvariant();
        }
        var folded = new StringBuilder(decomposed.Length);
        foreach (var c in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
                folded.Append(c);
        }
        return folded.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    private IReadOnlyList<BabylonBglEntry> Lookup(BabylonDictionary dictionary, string term)
    {
        var signature = Signature.Of(dictionary.FilePath);
        var normalized = NormalizedTerm(term);
        if (TryRead(dictionary, signature, normalized) is { } entries)
            return entries;
        Build(dictionary, signature);
        return TryRead(dictionary, signature, normalized)
            ?? throw DictionaryLookupException.Decoding("Babylon index is unreadable after rebuilding it.");
    }

    // MARK: - Read

    /// <summary>The matches, or null when the index is missing, unreadable or stale.</summary>
    private List<BabylonBglEntry>? TryRead(BabylonDictionary dictionary, Signature signature, string term)
    {
        var path = IndexPath(dictionary.Id, "sqlite");
        if (!File.Exists(path))
            return null;
        using var connection = Connection(path, SqliteOpenMode.ReadOnly);
        try
        {
            connection.Open();
            if (!IsValid(connection, dictionary, signature))
                return null;
        }
        catch (SqliteException)
        {
            return null;
        }

        using var query = connection.CreateCommand();
        query.CommandText = """
            SELECT e.headword, e.definition FROM terms t
            JOIN entries e ON e.id = t.entry_id
            WHERE t.term = $term ORDER BY e.id
            """;
        query.Parameters.AddWithValue("$term", term);
        using var reader = query.ExecuteReader();
        var entries = new List<BabylonBglEntry>();
        while (reader.Read())
            entries.Add(new BabylonBglEntry(reader.GetString(0), reader.GetString(1), []));
        return entries;
    }

    private static bool IsValid(SqliteConnection connection, BabylonDictionary dictionary, Signature signature)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT schema_version, dictionary_id, file_path, mtime, size FROM meta LIMIT 1";
        using var reader = command.ExecuteReader();
        return reader.Read()
            && reader.GetInt64(0) == SchemaVersion
            && reader.GetString(1) == IdString(dictionary.Id)
            && reader.GetString(2) == signature.FilePath
            && !reader.IsDBNull(3) && reader.GetDouble(3) == signature.ModifiedSeconds
            && !reader.IsDBNull(4) && reader.GetInt64(4) == signature.Size;
    }

    // MARK: - Build

    private void Build(BabylonDictionary dictionary, Signature signature)
    {
        Directory.CreateDirectory(directory);
        var temporary = IndexPath(dictionary.Id, "sqlite.tmp");
        File.Delete(temporary);
        try
        {
            Write(temporary, new BabylonBglParser().ReadFile(dictionary.FilePath), dictionary, signature);
            File.Delete(IndexPath(dictionary.Id, "sqlite-wal"));
            File.Delete(IndexPath(dictionary.Id, "sqlite-shm"));
            File.Move(temporary, IndexPath(dictionary.Id, "sqlite"), overwrite: true);
        }
        catch
        {
            try
            {
                File.Delete(temporary);
            }
            catch (IOException)
            {
                // Replaced by the next build.
            }
            throw;
        }
    }

    private static void Write(
        string path, IEnumerable<BabylonBglEntry> entries, BabylonDictionary dictionary, Signature signature)
    {
        using var connection = Connection(path, SqliteOpenMode.ReadWriteCreate);
        connection.Open();
        Execute(connection, """
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE entries(id INTEGER PRIMARY KEY, headword TEXT NOT NULL, definition TEXT NOT NULL);
            CREATE TABLE terms(term TEXT NOT NULL, entry_id INTEGER NOT NULL);
            CREATE TABLE meta(
                schema_version INTEGER NOT NULL,
                dictionary_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                mtime REAL,
                size INTEGER,
                entry_count INTEGER NOT NULL
            );
            """);

        long count = 0;
        using (var transaction = connection.BeginTransaction())
        {
            using var insertEntry = connection.CreateCommand();
            insertEntry.CommandText = "INSERT INTO entries(id, headword, definition) VALUES ($id, $headword, $definition)";
            var entryId = insertEntry.Parameters.Add("$id", SqliteType.Integer);
            var headword = insertEntry.Parameters.Add("$headword", SqliteType.Text);
            var definition = insertEntry.Parameters.Add("$definition", SqliteType.Text);

            using var insertTerm = connection.CreateCommand();
            insertTerm.CommandText = "INSERT INTO terms(term, entry_id) VALUES ($term, $entryId)";
            var term = insertTerm.Parameters.Add("$term", SqliteType.Text);
            var termEntryId = insertTerm.Parameters.Add("$entryId", SqliteType.Integer);

            foreach (var entry in entries)
            {
                count++;
                entryId.Value = count;
                headword.Value = entry.Headword;
                definition.Value = entry.Definition;
                insertEntry.ExecuteNonQuery();

                termEntryId.Value = count;
                foreach (var lookupTerm in LookupTerms(entry))
                {
                    term.Value = lookupTerm;
                    insertTerm.ExecuteNonQuery();
                }
            }
            transaction.Commit();
        }
        Execute(connection, "CREATE INDEX terms_term ON terms(term);");

        // The meta row is written last: an index without it is never valid.
        using var insertMeta = connection.CreateCommand();
        insertMeta.CommandText = """
            INSERT INTO meta(schema_version, dictionary_id, file_path, mtime, size, entry_count)
            VALUES ($version, $id, $path, $mtime, $size, $count)
            """;
        insertMeta.Parameters.AddWithValue("$version", SchemaVersion);
        insertMeta.Parameters.AddWithValue("$id", IdString(dictionary.Id));
        insertMeta.Parameters.AddWithValue("$path", signature.FilePath);
        insertMeta.Parameters.AddWithValue("$mtime", signature.ModifiedSeconds);
        insertMeta.Parameters.AddWithValue("$size", signature.Size);
        insertMeta.Parameters.AddWithValue("$count", count);
        insertMeta.ExecuteNonQuery();
    }

    /// <summary>The headword and alternates, normalized, without empty ones or duplicates, in order.</summary>
    private static IEnumerable<string> LookupTerms(BabylonBglEntry entry) =>
        entry.Alternates.Prepend(entry.Headword).Select(NormalizedTerm).Where(t => t.Length > 0)
            .Distinct(StringComparer.Ordinal);

    private static void Execute(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    // MARK: - Files

    private static SqliteConnection Connection(string path, SqliteOpenMode mode) =>
        new(new SqliteConnectionStringBuilder { DataSource = path, Mode = mode, Pooling = false }.ToString());

    /// <summary>Uppercase, as macOS writes a UUID.</summary>
    private static string IdString(Guid id) => id.ToString("D").ToUpperInvariant();

    private string IndexPath(Guid id, string suffix) => Path.Combine(directory, $"{IdString(id)}.{suffix}");

    /// <summary>The source file's identity: path, modification time (seconds since the Unix epoch) and size.</summary>
    private sealed record Signature(string FilePath, double ModifiedSeconds, long Size)
    {
        public static Signature Of(string path)
        {
            var file = new FileInfo(path);
            if (!file.Exists)
                throw DictionaryLookupException.Decoding("BGL file not found.");
            return new(path, (file.LastWriteTimeUtc - DateTime.UnixEpoch).TotalSeconds, file.Length);
        }
    }
}
