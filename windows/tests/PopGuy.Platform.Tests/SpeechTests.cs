using System.Runtime.InteropServices;
using System.Text;
using PopGuy.Core.Speak;
using PopGuy.Platform.Speech;

namespace PopGuy.Platform.Tests;

// The system voice on the Windows speech synthesizer. Synthesis needs no audio device, so it runs on the CI runner;
// playback does (the runner has none), so only its cancel-before-start path is tested here, which never opens a player.
public sealed class SpeechTests
{
    [Theory]
    [InlineData(-1.0f, 0.5)]
    [InlineData(0.0f, 0.5)]
    [InlineData(0.25f, 0.75)]
    [InlineData(0.5f, 1.0)]
    [InlineData(0.75f, 2.0)]
    [InlineData(1.0f, 3.0)]
    [InlineData(2.0f, 3.0)]
    public void TheRateMapsToTheSpeakingRateWithTheDefaultAtNormalSpeed(float rate, double expected)
    {
        Assert.Equal(expected, SystemTts.SpeakingRate(rate), 6);
    }

    [Theory]
    [InlineData(0.5f, 0.5)]
    [InlineData(1.0f, 1.0)]
    [InlineData(2.0f, 2.0)]
    [InlineData(3.0f, 2.0)]
    public void ThePitchMultiplierIsTheAudioPitch(float pitch, double expected)
    {
        Assert.Equal(expected, SystemTts.AudioPitch(pitch), 6);
    }

    [Fact]
    public void TheVoicesHaveIdsLanguagesAndAtMostOneDefault()
    {
        var voices = InstalledVoices();

        Assert.All(voices, v => Assert.False(string.IsNullOrEmpty(v.Id)));
        Assert.All(voices, v => Assert.False(string.IsNullOrEmpty(v.Language)));
        // The OS default voice is flagged; at most once (it may be missing from the list on a server image).
        Assert.True(voices.Count(v => v.IsDefault) <= 1);
    }

    [Fact]
    public async Task SynthesisReturnsAWavStreamForEveryVoiceIdShape()
    {
        var voices = InstalledVoices();
        var tts = new SystemTts();

        // A chosen voice, the default voice, and an id that is not installed (the default voice too).
        foreach (var voiceId in new[] { voices[^1].Id, null, "com.apple.voice.compact.en-US.Samantha" })
        {
            await using var wav = await tts.SynthesizeAsync(
                "PopGuy test.", voiceId, SpeakRules.DefaultRate, 1.0f, TestContext.Current.CancellationToken);
            var header = new byte[12];
            await wav.ReadExactlyAsync(header, TestContext.Current.CancellationToken);
            Assert.Equal("RIFF", Encoding.ASCII.GetString(header, 0, 4));
            Assert.Equal("WAVE", Encoding.ASCII.GetString(header, 8, 4));
        }
    }

    [Fact]
    public async Task PlaybackCancelledBeforeTheStartPlaysNothingAndDisposesTheAudio()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var audio = new MemoryStream(new byte[16]);
        var started = false;

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => new AudioPlayback().PlayAsync(audio, AudioContentTypes.Wav, () => started = true, cts.Token));
        Assert.False(started);
        Assert.False(audio.CanRead);
    }

    /// <summary>Skips off Windows, and where no voice is installed (a server image without speech).</summary>
    private static IReadOnlyList<SystemVoice> InstalledVoices()
    {
        if (!OperatingSystem.IsWindows()) Assert.Skip("The speech synthesizer needs Windows.");
        IReadOnlyList<SystemVoice> voices;
        try
        {
            voices = new SystemTts().Voices();
        }
        catch (COMException e)
        {
            Assert.Skip($"The speech synthesizer is unavailable: 0x{e.HResult:X8}");
            throw;
        }
        if (voices.Count == 0) Assert.Skip("No speech voice is installed.");
        return voices;
    }
}
