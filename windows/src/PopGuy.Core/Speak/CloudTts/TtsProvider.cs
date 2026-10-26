using PopGuy.Core.Actions;
using PopGuy.Core.Providers;

namespace PopGuy.Core.Speak.CloudTts;

// The cloud TTS adapter contract (macOS TTSProvider.swift, spec-4 §2.1). Adapters (OpenAI, Google Cloud TTS, Azure
// Speech) only build requests and decode audio; SpeakCoordinator routes, falls back, caches and plays.

/// <summary>One synthesis call. ToString shows no text: the spoken text is never logged.</summary>
/// <param name="Voice">Already resolved (<see cref="TtsVoices.Resolve"/>).</param>
/// <param name="LanguageCode">BCP-47 tag; used by the locale-bound providers (Google, Azure).</param>
/// <param name="Speed">The provider's speed scale (1.0 = normal; <see cref="SpeakRules.CloudSpeechSpeed"/>), or null.</param>
/// <param name="Pitch">A multiplier (0.5-2.0, 1.0 = normal), or null; providers without pitch (OpenAI) ignore it.</param>
public sealed record TtsSynthesisRequest(
    string Text, string Voice, string LanguageCode, double? Speed, double? Pitch, TtsProviderConfig Config)
{
    public override string ToString() => nameof(TtsSynthesisRequest);
}

/// <summary>A cloud TTS provider; the key comes from <c>SecretIds.Tts(kind)</c> and is never logged.</summary>
public interface ITtsProvider
{
    /// <summary>The adapter's own voice for a BCP-47 tag (the last step of <see cref="TtsVoices.Resolve"/>).</summary>
    string DefaultVoice(string languageCode);

    /// <summary>
    /// Synthesizes <paramref name="request"/> to MP3 bytes. Throws <see cref="ProviderError"/> (MissingOption for a
    /// missing Azure region, Http for a non-2xx status, Transport, DecodingFailed for an empty or malformed body);
    /// OperationCanceledException when <paramref name="ct"/> is cancelled.
    /// </summary>
    Task<byte[]> SynthesizeAsync(TtsSynthesisRequest request, string apiKey, CancellationToken ct);
}

public static class TtsVoices
{
    /// <summary>The voice for a call: the per-language override, else the provider-wide voice, else the adapter's.</summary>
    public static string Resolve(string languageCode, TtsProviderConfig config, ITtsProvider provider) =>
        config.VoiceOverrides.TryGetValue(languageCode, out var voice)
            ? voice
            : config.DefaultVoice ?? provider.DefaultVoice(languageCode);
}
