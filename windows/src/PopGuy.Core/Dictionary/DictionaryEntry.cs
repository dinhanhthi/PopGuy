using PopGuy.Core.Actions;

// Not PopGuy.Core.Dictionary: that namespace would hide Dictionary<TKey, TValue> in every PopGuy.Core.* file.
namespace PopGuy.Core.Dictionaries;

// The typed lookup result shared by every dictionary provider (macOS DictionaryEntry.swift and DictionaryProvider.swift,
// spec-4 §3.2-3.4). Separate from the AI provider abstraction: a dictionary returns an entry, not streamed text.

/// <summary>A definition. Structured sources fill <see cref="LexicalEntries"/>; a plain-text source only <see cref="RawText"/>.</summary>
public sealed record DictionaryEntry(
    string Headword, IReadOnlyList<LexicalEntry> LexicalEntries, string SourceName, string? RawText = null)
{
    /// <summary>The first pronunciation audio URL of the source (https only; see DictionaryAudioEngine).</summary>
    public string? PrimaryAudioUrl => LexicalEntries.Select(e => e.AudioUrl).FirstOrDefault(url => url is not null);

    public bool IsPlainTextOnly => LexicalEntries.Count == 0 && RawText is not null;
}

/// <summary>One language / part-of-speech group of an entry.</summary>
public sealed record LexicalEntry(
    string? Language, string? PartOfSpeech, IReadOnlyList<Pronunciation> Pronunciations, IReadOnlyList<Sense> Senses,
    string? AudioUrl);

public sealed record Pronunciation(string Ipa, IReadOnlyList<string> Tags);

/// <summary>A definition with its examples (an example may be "source\ntranslation") and synonyms.</summary>
public sealed record Sense(string Definition, IReadOnlyList<string> Examples, IReadOnlyList<string> Synonyms);

/// <summary>One provider's definition; Look up shows one tab per result when there are several.</summary>
public sealed record DictionaryProviderResult(DictionaryProviderKind ProviderKind, DictionaryEntry Entry);

/// <summary>A dictionary source (minhqnd, Free Dictionary API; Babylon in a later phase).</summary>
public interface IDictionaryProvider
{
    /// <summary>
    /// The entry for <paramref name="term"/>. Throws <see cref="DictionaryLookupException"/> (NotFound for a miss), or
    /// OperationCanceledException when <paramref name="ct"/> is cancelled.
    /// </summary>
    Task<DictionaryEntry> LookupAsync(string term, string? sourceLanguage, string? definitionLanguage, CancellationToken ct);
}

public enum DictionaryLookupErrorKind { NotFound, Network, RateLimited, Decoding }

/// <summary>A failed lookup; the message is the one the toolbar and history show (spec-4 §3.4).</summary>
public sealed class DictionaryLookupException : Exception
{
    private DictionaryLookupException(DictionaryLookupErrorKind kind, string message) : base(message) => Kind = kind;

    public DictionaryLookupErrorKind Kind { get; }

    public static DictionaryLookupException NotFound() => new(DictionaryLookupErrorKind.NotFound, "No definition found");

    public static DictionaryLookupException Network(string underlying) =>
        new(DictionaryLookupErrorKind.Network, $"Dictionary lookup failed: {underlying}");

    public static DictionaryLookupException RateLimited() =>
        new(DictionaryLookupErrorKind.RateLimited, "Dictionary rate limit reached. Try again later.");

    public static DictionaryLookupException Decoding(string detail) =>
        new(DictionaryLookupErrorKind.Decoding, $"Could not read dictionary response: {detail}");
}
