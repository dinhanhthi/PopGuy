namespace PopGuy.Core.Speak;

// The platform seams SpeakCoordinator drives (Platform implements them on the Windows speech and media frameworks).

/// <summary>The system speech synthesizer (macOS <c>TTSEngine</c>), which renders audio for the shared player.</summary>
public interface ISystemTts
{
    /// <summary>The installed voices.</summary>
    IReadOnlyList<SystemVoice> Voices();

    /// <summary>
    /// Renders <paramref name="text"/> as WAV audio (<see cref="AudioContentTypes.Wav"/>). <paramref name="rate"/> is
    /// PopGuy's scale (<see cref="SpeakRules.MinimumRate"/>-<see cref="SpeakRules.MaximumRate"/>, default
    /// <see cref="SpeakRules.DefaultRate"/>) and <paramref name="pitch"/> a multiplier (0.5-2.0, default 1.0); the
    /// implementation maps both to its engine. A null or missing <paramref name="voiceId"/> uses the default voice.
    /// </summary>
    Task<Stream> SynthesizeAsync(string text, string? voiceId, float rate, float pitch, CancellationToken ct);
}

/// <summary>The one audio player for system and cloud speech.</summary>
public interface IAudioPlayback
{
    /// <summary>
    /// Plays <paramref name="audio"/> (owned and disposed by the player), replacing anything playing, and completes when
    /// it plays to its end. Calls <paramref name="started"/> once it is audible. Throws when the audio cannot be played
    /// (the coordinator then falls back). Cancelling <paramref name="ct"/> stops playback at once (inside the cancel
    /// call), and before the start it plays nothing; the task then throws OperationCanceledException.
    /// </summary>
    Task PlayAsync(Stream audio, string contentType, Action started, CancellationToken ct);
}

public static class AudioContentTypes
{
    /// <summary>The system synthesizer's output.</summary>
    public const string Wav = "audio/wav";

    /// <summary>Every cloud provider's output.</summary>
    public const string Mp3 = "audio/mpeg";
}
