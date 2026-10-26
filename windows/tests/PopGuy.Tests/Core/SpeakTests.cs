using System.Text;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Core.Speak;
using PopGuy.Core.Speak.CloudTts;
using PopGuy.Core.Toolbar;

namespace PopGuy.Tests.Core;

// Key feature: the Speak coordinator (macOS SpeakCoordinator.swift, spec-4 §1.5-1.10): phases idle → loading → playing
// → idle, cloud failure falls back to the system voice, a new Speak or Stop cancels the previous request, "Listen again"
// replays cached cloud audio without a new request (and a fallback replays through the system voice, never re-billing),
// the cloud speed mapping, and a macOS voice id resolving to the Windows voice for its language.
public sealed class SpeakTests
{
    private static readonly IReadOnlyList<SystemVoice> Voices =
    [
        new("win-david", "David", "en-US"),
        new("win-zira", "Zira", "en-US", IsDefault: true),
        new("win-hazel", "Hazel", "en-GB"),
        new("win-george", "George", "en-GB", IsDefault: true),
        new("win-hortense", "Hortense", "fr-FR"),
    ];

    private sealed class FakeSystemTts : ISystemTts
    {
        public List<(string Text, string? VoiceId)> Calls { get; } = [];

        /// <summary>When set, synthesis waits for it, ignoring cancellation (a late result must still be dropped).</summary>
        public TaskCompletionSource? Hold { get; set; }

        public IReadOnlyList<SystemVoice> Voices() => SpeakTests.Voices;

        public async Task<Stream> SynthesizeAsync(
            string text, string? voiceId, float rate, float pitch, CancellationToken ct)
        {
            Calls.Add((text, voiceId));
            var hold = Hold;
            if (hold is not null)
                await hold.Task;
            return new MemoryStream(Encoding.UTF8.GetBytes("wav:" + text));
        }
    }

    private sealed class FakeCloud(Exception? error = null) : ITtsProvider
    {
        public int Calls { get; private set; }

        public TtsSynthesisRequest? LastRequest { get; private set; }

        public string DefaultVoice(string languageCode) => "alloy";

        public Task<byte[]> SynthesizeAsync(TtsSynthesisRequest request, string apiKey, CancellationToken ct)
        {
            Calls++;
            LastRequest = request;
            return error is null
                ? Task.FromResult(Encoding.UTF8.GetBytes("mp3:" + request.Text))
                : Task.FromException<byte[]>(error);
        }
    }

    /// <summary>Starts every audio at once and plays it until <see cref="EndCurrent"/> or cancellation.</summary>
    private sealed class FakePlayback : IAudioPlayback
    {
        private TaskCompletionSource _end = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public List<(string Audio, string ContentType)> Played { get; } = [];

        public bool Cancelled { get; private set; }

        public async Task PlayAsync(Stream audio, string contentType, Action started, CancellationToken ct)
        {
            // Recorded before the token check, so a superseded request reaching the player shows.
            using var reader = new StreamReader(audio);
            Played.Add((await reader.ReadToEndAsync(CancellationToken.None), contentType));
            ct.ThrowIfCancellationRequested();
            _end = new(TaskCreationOptions.RunContinuationsAsynchronously);
            started();
            try
            {
                await _end.Task.WaitAsync(ct);
            }
            catch (OperationCanceledException)
            {
                Cancelled = true;
                throw;
            }
        }

        public void EndCurrent() => _end.TrySetResult();
    }

    private static (SpeakCoordinator Coordinator, FakeSystemTts System, FakePlayback Playback) Make(
        FakeCloud? cloud = null, string? key = "pg-test-key")
    {
        var system = new FakeSystemTts();
        var playback = new FakePlayback();
        var coordinator = new SpeakCoordinator(system, playback, _ => cloud, _ => key);
        return (coordinator, system, playback);
    }

    private static readonly SpeakSettings Cloud = new() { SelectedEngine = SpeakEngineSelection.Cloud(TtsProviderKind.OpenAiTts) };

    [Fact]
    public async Task PhasesGoLoadingPlayingIdleAndKeepListenAgain()
    {
        var (speak, system, playback) = Make();
        system.Hold = new();
        var changes = 0;
        speak.Changed += () => changes++;

        var run = speak.SpeakAsync("  Hello world \n", SpeakAccent.UsEnglish, new(), new());

        // Loading at once, before the synthesis returns.
        Assert.Equal(SpeakPhase.Loading, speak.Phase);
        Assert.Equal("Hello world", speak.LastSpokenText);
        Assert.False(speak.CanReplay);

        system.Hold.SetResult();
        await WaitUntil(() => speak.Phase == SpeakPhase.Playing);
        Assert.True(speak.IsSpeaking);
        Assert.True(speak.CanReplay);
        Assert.Equal(("wav:Hello world", AudioContentTypes.Wav), Assert.Single(playback.Played));

        playback.EndCurrent();
        await run;
        Assert.Equal(SpeakPhase.Idle, speak.Phase);
        Assert.True(speak.CanReplay);
        Assert.True(changes >= 3);

        // Whitespace-only text changes nothing.
        await speak.SpeakAsync(" \n ", SpeakAccent.UsEnglish, new(), new());
        Assert.Equal("Hello world", speak.LastSpokenText);
    }

    [Theory]
    [InlineData(true, null)]
    [InlineData(false, "no key")]
    public async Task CloudFailureFallsBackToTheSystemVoiceAndReplayNeverReBills(bool providerFails, string? missingKey)
    {
        var cloud = new FakeCloud(providerFails ? ProviderError.Http(500, "boom") : null);
        var (speak, system, playback) = Make(cloud, key: missingKey is null ? "pg-test-key" : null);

        var run = speak.SpeakAsync("Bonjour", SpeakAccent.French, Cloud, new());
        await WaitUntil(() => speak.Phase == SpeakPhase.Playing);

        Assert.True(speak.DidFallBackToSystem);
        Assert.Equal(("Bonjour", "win-hortense"), Assert.Single(system.Calls));
        Assert.Equal(("wav:Bonjour", AudioContentTypes.Wav), Assert.Single(playback.Played));
        playback.EndCurrent();
        await run;

        var replay = speak.ReplayAsync();
        await WaitUntil(() => speak.Phase == SpeakPhase.Playing);
        Assert.Equal(2, system.Calls.Count);
        Assert.Equal(providerFails ? 1 : 0, cloud.Calls);
        playback.EndCurrent();
        await replay;
    }

    [Fact]
    public async Task ReplayReusesTheCachedCloudAudioWithoutANewRequest()
    {
        var cloud = new FakeCloud();
        var (speak, system, playback) = Make(cloud);
        var settings = Cloud with { Rate = 0.75f, Pitch = 1.5f };
        var config = new TtsProviderConfig { DefaultVoice = "marin" };

        var run = speak.SpeakAsync("Hello", SpeakAccent.UkEnglish, settings, config);
        await WaitUntil(() => speak.Phase == SpeakPhase.Playing);
        Assert.False(speak.DidFallBackToSystem);
        Assert.Equal(1.25, cloud.LastRequest!.Speed);
        Assert.Equal(1.5, cloud.LastRequest.Pitch);
        Assert.Equal("marin", cloud.LastRequest.Voice);
        Assert.Equal("en-GB", cloud.LastRequest.LanguageCode);

        // Stop keeps the cache: Listen again still works.
        speak.Stop();
        Assert.Equal(SpeakPhase.Idle, speak.Phase);
        await run;

        var replay = speak.ReplayAsync();
        await WaitUntil(() => speak.Phase == SpeakPhase.Playing);
        Assert.Equal(1, cloud.Calls);
        Assert.Empty(system.Calls);
        Assert.Equal(["mp3:Hello", "mp3:Hello"], playback.Played.Select(p => p.Audio));
        Assert.All(playback.Played, p => Assert.Equal(AudioContentTypes.Mp3, p.ContentType));
        playback.EndCurrent();
        await replay;

        // Clearing (toolbar closed, new selection) drops it.
        speak.ClearReplay();
        Assert.False(speak.CanReplay);
        Assert.Null(speak.LastSpokenText);
        await speak.ReplayAsync();
        Assert.Equal(2, playback.Played.Count);
    }

    [Fact]
    public async Task ANewSpeakOrStopCancelsThePreviousRequest()
    {
        var (speak, system, playback) = Make();
        var first = new TaskCompletionSource();
        system.Hold = first;
        var firstRun = speak.SpeakAsync("first", SpeakAccent.UsEnglish, new(), new());

        system.Hold = null;
        var secondRun = speak.SpeakAsync("second", SpeakAccent.UsEnglish, new(), new());
        await WaitUntil(() => speak.Phase == SpeakPhase.Playing);

        // The first synthesis finishing late never plays.
        first.TrySetResult();
        await firstRun;
        Assert.Equal("wav:second", Assert.Single(playback.Played).Audio);
        Assert.Equal("second", speak.LastSpokenText);
        Assert.Equal(SpeakPhase.Playing, speak.Phase);

        // Stop stops playback at once.
        speak.Stop();
        Assert.Equal(SpeakPhase.Idle, speak.Phase);
        Assert.True(playback.Cancelled);
        await secondRun;
        Assert.Equal(SpeakPhase.Idle, speak.Phase);
    }

    // Spec-4 §1.10: rate 0-1 (default 0.5) maps linearly to 0.6-1.0-1.5, clamped, rounded to 3 places.
    [Theory]
    [InlineData(0.0f, 0.6)]
    [InlineData(0.25f, 0.8)]
    [InlineData(0.3f, 0.84)]
    [InlineData(0.5f, 1.0)]
    [InlineData(0.75f, 1.25)]
    [InlineData(1.0f, 1.5)]
    [InlineData(-1.0f, 0.6)]
    [InlineData(2.0f, 1.5)]
    public void CloudSpeedMapsTheSystemRate(float rate, double speed) =>
        Assert.Equal(speed, SpeakRules.CloudSpeechSpeed(rate));

    [Theory]
    // A macOS AVSpeech id: the default Windows voice for its language.
    [InlineData("com.apple.voice.compact.en-GB.Daniel", SpeakAccent.UsEnglish, "win-george")]
    [InlineData("com.apple.ttsbundle.siri_female_fr-FR_compact", SpeakAccent.UsEnglish, "win-hortense")]
    // No locale in the id, or no voice for it: the accent's default voice.
    [InlineData("com.apple.speech.synthesis.voice.Alex", SpeakAccent.UsEnglish, "win-zira")]
    [InlineData("com.apple.voice.compact.de-DE.Anna", SpeakAccent.UsEnglish, "win-zira")]
    // An installed voice is used as is.
    [InlineData("win-david", SpeakAccent.UsEnglish, "win-david")]
    // The saved voice applies only to the default accent.
    [InlineData("win-david", SpeakAccent.UkEnglish, "win-george")]
    // No voice for the accent: the system default (null).
    [InlineData(null, SpeakAccent.German, null)]
    public void SystemVoiceResolvesForTheLanguage(string? savedVoice, SpeakAccent accent, string? expected)
    {
        var settings = new SpeakSettings { DefaultVoiceId = savedVoice };
        Assert.Equal(expected, SpeakRules.ResolveSystemVoice(Voices, settings, accent));
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        for (var i = 0; i < 200 && !condition(); i++)
            await Task.Delay(10);
        Assert.True(condition());
    }
}
