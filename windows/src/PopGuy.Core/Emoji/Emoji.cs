using System.Text;
using System.Text.Json.Serialization;
using PopGuy.Core.Json;

namespace PopGuy.Core.Emojis;

/// <summary>
/// One entry of the bundled emoji or symbol data (macOS <c>Emoji.swift</c>): <c>emoji.json</c> and <c>symbols.json</c>,
/// generated from emojibase and embedded from <c>macos/PopGuy/Resources/Emoji</c>.
/// </summary>
public sealed record Emoji
{
    /// <summary>The glyph (JSON <c>emoji</c>; a member can't share the record's name).</summary>
    [JsonPropertyName("emoji")]
    public required string Glyph { get; init; }

    [JsonPropertyName("description")]
    public required string Description { get; init; }

    [JsonPropertyName("category")]
    public required string Category { get; init; }

    [JsonPropertyName("aliases")]
    public required IReadOnlyList<string> Aliases { get; init; }

    [JsonPropertyName("tags")]
    public required IReadOnlyList<string> Tags { get; init; }

    /// <summary>vi / fr / es labels and tags (absent from some rows).</summary>
    [JsonPropertyName("keywords")]
    public IReadOnlyList<string>? Keywords { get; init; }

    /// <summary>Emoji version the glyph first appeared in (absent from symbols).</summary>
    [JsonPropertyName("version")]
    public double? Version { get; init; }

    /// <summary>True when the emoji takes a skin tone (absent from the JSON otherwise).</summary>
    [JsonPropertyName("skin_tones")]
    public bool? SkinTones { get; init; }

    /// <summary>Emoji version of the toned forms, only when newer than <see cref="Version"/>.</summary>
    [JsonPropertyName("skin_tones_version")]
    public double? SkinTonesVersion { get; init; }

    /// <summary>Which file the row came from (null = emoji). Set at load, never decoded.</summary>
    [JsonIgnore]
    public EmojiKind? Kind { get; init; }

    /// <summary>
    /// <see cref="Glyph"/> with <paramref name="tone"/> applied: the modifier goes after every modifier base and replaces
    /// the U+FE0F that follows it (✌️ → ✌🏽, 🕵️‍♂️ → 🕵🏽‍♂️, 🧑‍🤝‍🧑 → 🧑🏽‍🤝‍🧑🏽).
    /// </summary>
    public string Toned(SkinTone tone)
    {
        if (SkinTones != true || tone.Modifier() is not { } modifier)
            return Glyph;
        var multiScalar = Glyph.EnumerateRunes().Skip(1).Any();
        var result = new StringBuilder(Glyph.Length + 4);
        var afterBase = false;
        foreach (var rune in Glyph.EnumerateRunes())
        {
            if (afterBase && rune.Value == 0xFE0F)
            {
                afterBase = false;
                continue;
            }
            result.Append(rune.ToString());
            // 🤝 takes a tone on its own, never inside a sequence (🧑‍🤝‍🧑).
            afterBase = EmojiModifierBase.Contains(rune.Value) && !(rune.Value == 0x1F91D && multiScalar);
            if (afterBase)
                result.Append(modifier.ToString());
        }
        return result.ToString();
    }
}

/// <summary>Which data file a row came from.</summary>
public enum EmojiKind
{
    Symbol,
}

/// <summary>Skin tone applied to the people and hand emoji that support one (macOS <c>SkinTone</c>).</summary>
[JsonConverter(typeof(RawValueEnumConverter<SkinTone>))]
public enum SkinTone
{
    [JsonStringEnumMemberName("none")] None,
    [JsonStringEnumMemberName("light")] Light,
    [JsonStringEnumMemberName("mediumLight")] MediumLight,
    [JsonStringEnumMemberName("medium")] Medium,
    [JsonStringEnumMemberName("mediumDark")] MediumDark,
    [JsonStringEnumMemberName("dark")] Dark,
}

public static class SkinToneExtensions
{
    /// <summary>The Fitzpatrick modifier (U+1F3FB...U+1F3FF), null for the default yellow.</summary>
    public static Rune? Modifier(this SkinTone tone) => tone switch
    {
        SkinTone.Light => new Rune(0x1F3FB),
        SkinTone.MediumLight => new Rune(0x1F3FC),
        SkinTone.Medium => new Rune(0x1F3FD),
        SkinTone.MediumDark => new Rune(0x1F3FE),
        SkinTone.Dark => new Rune(0x1F3FF),
        _ => null,
    };
}

/// <summary>
/// The Emoji_Modifier_Base code points, which .NET does not expose: Unicode <c>emoji-data.txt</c> (Unicode 17.0), the
/// property Swift reads on macOS.
/// </summary>
internal static class EmojiModifierBase
{
    private static readonly (int Lo, int Hi)[] Ranges =
    [
        (0x261D, 0x261D), (0x26F9, 0x26F9), (0x270A, 0x270D), (0x1F385, 0x1F385), (0x1F3C2, 0x1F3C4),
        (0x1F3C7, 0x1F3C7), (0x1F3CA, 0x1F3CC), (0x1F442, 0x1F443), (0x1F446, 0x1F450), (0x1F466, 0x1F478),
        (0x1F47C, 0x1F47C), (0x1F481, 0x1F483), (0x1F485, 0x1F487), (0x1F48F, 0x1F48F), (0x1F491, 0x1F491),
        (0x1F4AA, 0x1F4AA), (0x1F574, 0x1F575), (0x1F57A, 0x1F57A), (0x1F590, 0x1F590), (0x1F595, 0x1F596),
        (0x1F645, 0x1F647), (0x1F64B, 0x1F64F), (0x1F6A3, 0x1F6A3), (0x1F6B4, 0x1F6B6), (0x1F6C0, 0x1F6C0),
        (0x1F6CC, 0x1F6CC), (0x1F90C, 0x1F90C), (0x1F90F, 0x1F90F), (0x1F918, 0x1F91F), (0x1F926, 0x1F926),
        (0x1F930, 0x1F939), (0x1F93C, 0x1F93E), (0x1F977, 0x1F977), (0x1F9B5, 0x1F9B6), (0x1F9B8, 0x1F9B9),
        (0x1F9BB, 0x1F9BB), (0x1F9CD, 0x1F9CF), (0x1F9D1, 0x1F9DD), (0x1FAC3, 0x1FAC5), (0x1FAF0, 0x1FAF8),
    ];

    public static bool Contains(int codePoint)
    {
        foreach (var (lo, hi) in Ranges)
        {
            if (codePoint < lo)
                return false;
            if (codePoint <= hi)
                return true;
        }
        return false;
    }
}
