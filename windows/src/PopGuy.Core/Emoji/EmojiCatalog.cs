using System.Text.Json;
using PopGuy.Core.Json;

namespace PopGuy.Core.Emojis;

/// <summary>Loads the embedded emoji and symbol data (macOS <c>EmojiCatalog</c>).</summary>
public static class EmojiCatalog
{
    /// <summary>
    /// <c>emoji.json</c>, then <c>symbols.json</c>, in file order (emojibase order is category order). Each file fails
    /// closed on its own. Emoji rows newer than <paramref name="maxVersion"/> are dropped (the system font can't draw
    /// them); rows with no version are kept. Rows whose toned forms are newer lose <see cref="Emoji.SkinTones"/>.
    /// <paramref name="hideCountryFlags"/> drops the country and subdivision flags (Windows draws them as letters).
    /// </summary>
    public static IReadOnlyList<Emoji> Load(double maxVersion, bool hideCountryFlags)
    {
        var emojis = Load("emoji", kind: null)
            .Where(e => (e.Version ?? 0) <= maxVersion)
            .Where(e => !hideCountryFlags || !IsCountryFlag(e.Glyph))
            .Select(e => (e.SkinTonesVersion ?? 0) > maxVersion ? e with { SkinTones = null } : e);
        return [.. emojis, .. Load("symbols", EmojiKind.Symbol)];
    }

    /// <summary>
    /// Newest Emoji version the system font (Segoe UI Emoji) draws on Windows <paramref name="build"/>.<paramref name="ubr"/>.
    /// Conservative: the cumulative updates that shipped each font are to be confirmed in Windows VM 2.
    /// </summary>
    public static double MaxEmojiVersion(int build, int ubr)
    {
        if (build >= 26100 && (build > 26100 || ubr >= 1301))
            return 15.1;
        if ((build == 22621 || build == 22631) && ubr >= 3810)
            return 15.1;
        return build >= 22621 ? 15.0 : 14.0;
    }

    /// <summary>The rows of the embedded <c>&lt;resource&gt;.json</c> tagged with <paramref name="kind"/>, or none if it is missing or broken.</summary>
    private static List<Emoji> Load(string resource, EmojiKind? kind)
    {
        try
        {
            using var stream = typeof(EmojiCatalog).Assembly.GetManifestResourceStream($"PopGuy.Core.Emoji.{resource}.json");
            if (stream is null)
                return [];
            var rows = JsonSerializer.Deserialize<List<Emoji>>(stream, PopGuyJson.Options) ?? [];
            return kind is null ? rows : [.. rows.Select(e => e with { Kind = kind })];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// <summary>
    /// A regional-indicator pair (🇫🇷) or a tag-sequence subdivision flag (🏴 + tag characters). 🏁 🚩 🎌 🏴 🏳️ 🏳️‍🌈
    /// 🏳️‍⚧️ 🏴‍☠️ are neither.
    /// </summary>
    private static bool IsCountryFlag(string glyph)
    {
        var runes = glyph.EnumerateRunes().Select(r => r.Value).ToList();
        if (runes.Count == 2 && runes.All(r => r is >= 0x1F1E6 and <= 0x1F1FF))
            return true;
        return runes.Count > 1 && runes[0] == 0x1F3F4 && runes.Any(r => r is >= 0xE0020 and <= 0xE007F);
    }
}
