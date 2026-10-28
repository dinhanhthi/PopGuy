namespace PopGuy.Core.Actions;

/// <summary>A Translate target: the BCP-47 code providers get, and the name the picker shows and <c>{{language}}</c> uses.</summary>
public sealed record TargetLanguage(string Code, string Name);

/// <summary>
/// The languages of the toolbar's Translate picker (macOS <c>TargetLanguage</c> in <c>ToolbarViewModel.swift</c>, which
/// the settings' Translate list must match).
/// </summary>
public static class TargetLanguages
{
    public static TargetLanguage English { get; } = new("en", "English");

    public static IReadOnlyList<TargetLanguage> All { get; } =
    [
        English,
        new("vi", "Vietnamese"),
        new("fr", "French"),
        new("es", "Spanish"),
        new("de", "German"),
        new("ja", "Japanese"),
        new("zh", "Chinese (Simplified)"),
        new("ko", "Korean"),
        new("pt", "Portuguese"),
        new("it", "Italian"),
    ];

    /// <summary>The language with <paramref name="code"/>; English for an unknown code (macOS parity).</summary>
    public static TargetLanguage FromCode(string code) => All.FirstOrDefault(l => l.Code == code) ?? English;
}
