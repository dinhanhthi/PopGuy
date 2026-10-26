using PopGuy.Core.Actions;

namespace PopGuy.Core.Speak.CloudTts;

/// <summary>
/// What Settings offers for each cloud TTS provider (macOS TTSProviderKind.swift and the adapters' curatedVoices): the
/// model picker (OpenAI only), the voices of a model (OpenAI: multilingual) or of a language (Google, Azure:
/// locale-bound), and pitch support.
/// </summary>
public static class TtsCatalog
{
    private static readonly string[] OpenAiVoices =
        ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"];

    /// <summary>gpt-4o-mini-tts adds ballad, verse, marin and cedar (OpenAI recommends marin and cedar).</summary>
    private static readonly string[] OpenAiMiniTtsVoices =
        ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse", "marin", "cedar"];

    /// <summary>Only OpenAI has a user-facing model: Google and Azure pick the quality through the voice name.</summary>
    public static bool UsesModel(this TtsProviderKind kind) => kind == TtsProviderKind.OpenAiTts;

    /// <summary>The model used when none is saved, or null for the providers without one.</summary>
    public static string? DefaultModel(this TtsProviderKind kind) =>
        kind == TtsProviderKind.OpenAiTts ? OpenAITtsProvider.DefaultModel : null;

    /// <summary>The model picker's entries; anything else is a custom model.</summary>
    public static IReadOnlyList<string> CuratedModels(this TtsProviderKind kind) =>
        kind == TtsProviderKind.OpenAiTts ? [OpenAITtsProvider.DefaultModel] : [];

    /// <summary>OpenAI's voices for <paramref name="model"/> (the classic set for the tts-1 models); none for the others.</summary>
    public static IReadOnlyList<string> CuratedVoices(this TtsProviderKind kind, string model) => kind switch
    {
        TtsProviderKind.OpenAiTts => model.StartsWith(OpenAITtsProvider.DefaultModel, StringComparison.Ordinal)
            ? OpenAiMiniTtsVoices
            : OpenAiVoices,
        _ => [],
    };

    /// <summary>
    /// The per-language voices of the locale-bound providers for a BCP-47 tag, best first (Google: Chirp 3 HD, then
    /// Neural2; Azure: Dragon HD, then Neural); none for OpenAI or an unknown tag. Every name starts with its locale.
    /// </summary>
    public static IReadOnlyList<string> CuratedVoicesForLanguage(this TtsProviderKind kind, string languageCode) => kind switch
    {
        TtsProviderKind.GoogleCloudTts => languageCode switch
        {
            "en-US" =>
            [
                "en-US-Chirp3-HD-Aoede", "en-US-Chirp3-HD-Charon", "en-US-Chirp3-HD-Kore", "en-US-Chirp3-HD-Puck",
                "en-US-Neural2-C", "en-US-Neural2-A", "en-US-Neural2-J",
            ],
            "en-GB" =>
            [
                "en-GB-Chirp3-HD-Aoede", "en-GB-Chirp3-HD-Charon", "en-GB-Chirp3-HD-Kore", "en-GB-Chirp3-HD-Puck",
                "en-GB-Neural2-A", "en-GB-Neural2-B", "en-GB-Neural2-F",
            ],
            "fr-FR" =>
            [
                "fr-FR-Chirp3-HD-Aoede", "fr-FR-Chirp3-HD-Charon", "fr-FR-Chirp3-HD-Kore", "fr-FR-Chirp3-HD-Puck",
                "fr-FR-Neural2-F", "fr-FR-Neural2-G",
            ],
            "es-ES" =>
            [
                "es-ES-Chirp3-HD-Aoede", "es-ES-Chirp3-HD-Charon", "es-ES-Chirp3-HD-Kore", "es-ES-Chirp3-HD-Puck",
                "es-ES-Neural2-A", "es-ES-Neural2-B", "es-ES-Neural2-C",
            ],
            "de-DE" =>
            [
                "de-DE-Chirp3-HD-Aoede", "de-DE-Chirp3-HD-Charon", "de-DE-Chirp3-HD-Kore", "de-DE-Chirp3-HD-Puck",
                "de-DE-Neural2-G", "de-DE-Neural2-H",
            ],
            _ => [],
        },
        TtsProviderKind.AzureTts => languageCode switch
        {
            "en-US" =>
            [
                "en-US-Aria:DragonHDLatestNeural", "en-US-Jenny:DragonHDLatestNeural", "en-US-Andrew:DragonHDLatestNeural",
                "en-US-Brian:DragonHDLatestNeural", "en-US-AriaNeural", "en-US-JennyNeural", "en-US-GuyNeural",
            ],
            "en-GB" =>
            [
                "en-GB-Ada:DragonHDLatestNeural", "en-GB-Ollie:DragonHDLatestNeural", "en-GB-SoniaNeural", "en-GB-RyanNeural",
                "en-GB-LibbyNeural",
            ],
            "fr-FR" => ["fr-FR-Vivienne:DragonHDLatestNeural", "fr-FR-Remy:DragonHDLatestNeural", "fr-FR-DeniseNeural", "fr-FR-HenriNeural"],
            "es-ES" => ["es-ES-Ximena:DragonHDLatestNeural", "es-ES-Tristan:DragonHDLatestNeural", "es-ES-ElviraNeural", "es-ES-AlvaroNeural"],
            "de-DE" => ["de-DE-Seraphina:DragonHDLatestNeural", "de-DE-Florian:DragonHDLatestNeural", "de-DE-KatjaNeural", "de-DE-ConradNeural"],
            _ => [],
        },
        _ => [],
    };

    /// <summary>OpenAI's speech API has no pitch; Google and Azure take one.</summary>
    public static bool SupportsPitch(this TtsProviderKind kind) => kind != TtsProviderKind.OpenAiTts;

    /// <summary>
    /// <paramref name="config"/> without its provider-wide voice when <paramref name="validVoices"/> (the new model's
    /// voices) does not have it (macOS clearingInvalidDefaultVoice).
    /// </summary>
    public static TtsProviderConfig ClearingInvalidDefaultVoice(this TtsProviderConfig config, IReadOnlyList<string> validVoices) =>
        config.DefaultVoice is { } voice && !validVoices.Contains(voice) ? config with { DefaultVoice = null } : config;
}
