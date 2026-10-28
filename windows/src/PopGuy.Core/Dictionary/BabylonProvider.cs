using PopGuy.Core.Settings;

namespace PopGuy.Core.Dictionaries;

/// <summary>
/// Lookups in the user's Babylon .bgl files (macOS BabylonBGLDictionaryProvider.swift, spec-4 §3.5): every enabled
/// file, in order, through its index. A file that cannot be read or indexed is skipped so the others still answer; no
/// match in any is NotFound. As on macOS, the files' declared languages are not consulted. The entry is plain text
/// (<see cref="DictionaryEntry.RawText"/>): for each match, the dictionary's name, then its definition.
/// </summary>
public sealed class BabylonProvider(IReadOnlyList<BabylonDictionary> dictionaries, BabylonIndexCache index)
    : IDictionaryProvider
{
    public const string SourceName = "Babylon (BGL)";

    public async Task<DictionaryEntry> LookupAsync(
        string term, string? sourceLanguage, string? definitionLanguage, CancellationToken ct)
    {
        var trimmed = term.Trim();
        if (trimmed.Length == 0)
            throw DictionaryLookupException.NotFound();

        var definitions = new List<string>();
        foreach (var dictionary in dictionaries.Where(d => d.IsEnabled))
        {
            IReadOnlyList<BabylonBglEntry> matches;
            try
            {
                matches = await index.LookupAsync(dictionary, trimmed, ct);
            }
            catch (Exception) when (!ct.IsCancellationRequested)
            {
                continue;
            }
            definitions.AddRange(matches.Select(match => $"{DisplayName(dictionary)}\n{match.Definition}"));
        }

        if (definitions.Count == 0)
            throw DictionaryLookupException.NotFound();
        return new DictionaryEntry(trimmed, [], SourceName, string.Join("\n\n", definitions));
    }

    /// <summary>The trimmed display name, else the file name without its extension (macOS resolvedDisplayName).</summary>
    private static string DisplayName(BabylonDictionary dictionary) =>
        dictionary.DisplayName.Trim() is { Length: > 0 } name ? name
        : Path.GetFileNameWithoutExtension(dictionary.FilePath) is { Length: > 0 } file ? file
        : "Babylon Dictionary";
}
