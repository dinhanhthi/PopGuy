using PopGuy.Core.Speak;
using Windows.Media.SpeechSynthesis;

namespace PopGuy.Platform.Speech;

/// <summary>
/// The system voice (macOS <c>TTSEngine</c>) on the Windows speech synthesizer (WinRT): its installed voices, and the
/// text rendered as WAV for <see cref="AudioPlayback"/>. The text is plain text, never SSML. A voice id that is not
/// installed uses the default voice. UNTRUSTED DATA: the text is never logged or put in an error.
/// </summary>
public sealed class SystemTts : ISystemTts
{
    /// <summary>The synthesizer's speaking-rate floor, its normal speed, and the rate PopGuy's maximum maps to.</summary>
    private const double SlowestRate = 0.5, NormalRate = 1.0, FastestRate = 3.0;

    /// <summary>The synthesizer's pitch range (1 = the voice's own pitch).</summary>
    private const double LowestPitch = 0.0, HighestPitch = 2.0;

    public IReadOnlyList<SystemVoice> Voices()
    {
        var defaultId = SpeechSynthesizer.DefaultVoice?.Id;
        return SpeechSynthesizer.AllVoices
            .Select(v => new SystemVoice(v.Id, v.DisplayName, v.Language, v.Id == defaultId))
            .ToList();
    }

    /// <summary>Renders the text into memory, so the result is seekable and outlives the synthesizer.</summary>
    public async Task<Stream> SynthesizeAsync(string text, string? voiceId, float rate, float pitch, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        using var synthesizer = new SpeechSynthesizer();
        if (voiceId is { Length: > 0 } && SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Id == voiceId) is { } voice)
            synthesizer.Voice = voice;
        synthesizer.Options.SpeakingRate = SpeakingRate(rate);
        synthesizer.Options.AudioPitch = AudioPitch(pitch);

        using var rendered = await synthesizer.SynthesizeTextToStreamAsync(text).AsTask(ct);
        using var source = rendered.AsStreamForRead();
        var wav = new MemoryStream();
        await source.CopyToAsync(wav, ct);
        wav.Position = 0;
        return wav;
    }

    /// <summary>
    /// PopGuy's rate (the macOS speech scale, 0-1, default 0.5) as the synthesizer's speaking rate, linear on each side
    /// of the default like the cloud speed: 0 gives 0.5 (the synthesizer's floor, half speed), 0.5 gives 1.0 (normal),
    /// 1 gives 3.0.
    /// </summary>
    internal static double SpeakingRate(float rate)
    {
        double min = SpeakRules.MinimumRate, standard = SpeakRules.DefaultRate, max = SpeakRules.MaximumRate;
        var clamped = Math.Clamp((double)rate, min, max);
        return clamped <= standard
            ? SlowestRate + (clamped - min) / (standard - min) * (NormalRate - SlowestRate)
            : NormalRate + (clamped - standard) / (max - standard) * (FastestRate - NormalRate);
    }

    /// <summary>PopGuy's pitch multiplier (0.5-2, default 1) is the synthesizer's own pitch scale, clamped to it.</summary>
    internal static double AudioPitch(float pitch) => Math.Clamp((double)pitch, LowestPitch, HighestPitch);
}
