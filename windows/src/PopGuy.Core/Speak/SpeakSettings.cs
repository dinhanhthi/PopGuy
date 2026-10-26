using PopGuy.Core.Actions;

namespace PopGuy.Core.Speak;

// The Speak settings rules (macOS SpeakSettings.swift + SpeakCoordinator.swift, spec-4 §1.3-1.4, §1.6, §1.10). The
// persisted records (SpeakSettings, SpeakAccent, SpeakEngineSelection "system" | "cloud:<kind>", TtsProviderConfig)
// stay in Actions/ActionTypes.cs with their JSON contract.

/// <summary>An installed system voice (macOS <c>VoiceCatalog.VoiceInfo</c>).</summary>
/// <param name="Id">The platform voice id, the value saved as <see cref="SpeakSettings.DefaultVoiceId"/>.</param>
/// <param name="Language">BCP-47 tag, e.g. "en-US".</param>
/// <param name="IsDefault">The voice chosen in the OS speech settings.</param>
public sealed record SystemVoice(string Id, string DisplayName, string Language, bool IsDefault = false);

public static class SpeakRules
{
    /// <summary>PopGuy's system rate scale is the macOS speech-synthesis scale; engines map it to their own.</summary>
    public const float MinimumRate = 0.0f;
    public const float DefaultRate = 0.5f;
    public const float MaximumRate = 1.0f;

    private const string MacVoicePrefix = "com.apple.";

    /// <summary>The BCP-47 tag a voice must match exactly (never by prefix: en-US and en-GB must not collide).</summary>
    public static string Bcp47(this SpeakAccent accent) => accent switch
    {
        SpeakAccent.UkEnglish => "en-GB",
        SpeakAccent.French => "fr-FR",
        SpeakAccent.Spanish => "es-ES",
        SpeakAccent.German => "de-DE",
        _ => "en-US",
    };

    /// <summary>The engine's name in Settings and history (macOS <c>SpeakEngineSelection.displayName</c>).</summary>
    public static string DisplayName(this SpeakEngineSelection engine) => engine.CloudProvider switch
    {
        null => "System voice",
        TtsProviderKind.OpenAiTts => "OpenAI",
        TtsProviderKind.GoogleCloudTts => "Google Cloud TTS",
        _ => "Azure Speech",
    };

    /// <summary>The accent's full name (macOS <c>SpeakAccent.displayName</c>).</summary>
    public static string DisplayName(this SpeakAccent accent) => accent switch
    {
        SpeakAccent.UkEnglish => "UK English",
        SpeakAccent.French => "French",
        SpeakAccent.Spanish => "Spanish",
        SpeakAccent.German => "German",
        _ => "US English",
    };

    /// <summary>
    /// The cloud speech speed for a system rate: linear, 0.6 at the minimum rate, 1.0 at the default, 1.5 at the
    /// maximum, rounded to 3 places (a narrow range that sounds natural on every provider).
    /// </summary>
    public static double CloudSpeechSpeed(float rate)
    {
        double min = MinimumRate, standard = DefaultRate, max = MaximumRate;
        var clamped = Math.Clamp((double)rate, min, max);
        var speed = clamped <= standard
            ? 0.6 + (clamped - min) / (standard - min) * 0.4
            : 1.0 + (clamped - standard) / (max - standard) * 0.5;
        return Math.Round(speed * 1000, MidpointRounding.AwayFromZero) / 1000;
    }

    /// <summary>
    /// The system voice for <paramref name="accent"/>; null means the system default. The saved voice applies only to
    /// the default accent. A saved voice that is not installed (a macOS AVSpeech id, a voice from another PC) resolves
    /// to the default voice for the language in a macOS id, else for the accent.
    /// </summary>
    public static string? ResolveSystemVoice(IReadOnlyList<SystemVoice> voices, SpeakSettings settings, SpeakAccent accent)
    {
        if (settings.DefaultVoiceId is { Length: > 0 } saved && accent == settings.DefaultAccent)
        {
            if (voices.Any(v => v.Id == saved))
                return saved;
            if (MacVoiceLanguage(saved) is { } language && VoiceFor(voices, language) is { } voice)
                return voice;
        }
        return VoiceFor(voices, accent.Bcp47());
    }

    /// <summary>The OS default voice when it speaks <paramref name="language"/>, else the first voice that does.</summary>
    private static string? VoiceFor(IReadOnlyList<SystemVoice> voices, string language)
    {
        var matching = voices.Where(v => string.Equals(v.Language, language, StringComparison.OrdinalIgnoreCase)).ToList();
        return (matching.FirstOrDefault(v => v.IsDefault) ?? matching.FirstOrDefault())?.Id;
    }

    /// <summary>
    /// The locale in a macOS voice id: <c>com.apple.voice.compact.en-US.Samantha</c> and
    /// <c>com.apple.ttsbundle.siri_female_en-US_compact</c> give "en-US"; null when the id names none.
    /// </summary>
    private static string? MacVoiceLanguage(string id)
    {
        if (!id.StartsWith(MacVoicePrefix, StringComparison.Ordinal))
            return null;
        return id.Split('.', '_').FirstOrDefault(IsLocale);

        static bool IsLocale(string token) =>
            token.Length is 5 or 6 && token[^3] == '-'
            && token[..^3].All(char.IsAsciiLetterLower) && token[^2..].All(char.IsAsciiLetterUpper);
    }
}
