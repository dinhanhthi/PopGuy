using System.Globalization;
using PopGuy.Core.Actions;
using PopGuy.Core.Speak.CloudTts;
using PopGuy.Core.Toolbar;

namespace PopGuy.Core.Speak;

// Routes Speak between the system voice and a cloud provider, and publishes one phase for the toolbar (macOS
// SpeakCoordinator.swift, spec-4 §1.5-1.10). The dictionary Listen path (§1.7) comes with the dictionaries.
// UNTRUSTED DATA: the spoken text is never logged or put in an error, nor is a key.

/// <summary>
/// One Speak request at a time: <see cref="SpeakAsync"/>, <see cref="ReplayAsync"/> and <see cref="Stop"/> each cancel
/// the previous request, and a request that was superseded never plays or falls back. Speak is orthogonal to the
/// toolbar's action state: the App mirrors <see cref="Phase"/> into <see cref="ToolbarSession.SpeakPhase"/> and
/// <see cref="CanReplay"/> into <see cref="PresentationInput.CanReplaySpeak"/>.
/// </summary>
public sealed class SpeakCoordinator
{
    /// <summary>What "Listen again" plays: cached cloud audio, or a new system rendering (never a new cloud request).</summary>
    private enum ReplaySource { None, System, CloudCache }

    private readonly record struct Request(int Generation, CancellationToken Token);

    private readonly ISystemTts _system;
    private readonly IAudioPlayback _playback;
    private readonly Func<TtsProviderKind, ITtsProvider?> _cloudProviders;
    private readonly Func<TtsProviderKind, string?> _cloudKeys;
    private readonly object _gate = new();

    private SpeakPhase _phase;
    private bool _didFallBack;
    private string? _lastText;
    private bool _canReplay;
    private int _generation;
    private CancellationTokenSource? _cts;
    private ReplaySource _replaySource;
    private byte[]? _cloudAudio;
    private SpeakAccent _lastAccent;
    private SpeakSettings _lastSettings = new();

    /// <param name="cloudProviders">The adapter for a kind; null when there is none (the system voice plays).</param>
    /// <param name="cloudKeys">The saved key for a kind (<c>SecretIds.Tts(kind)</c>); null or empty means none.</param>
    public SpeakCoordinator(
        ISystemTts system, IAudioPlayback playback,
        Func<TtsProviderKind, ITtsProvider?> cloudProviders, Func<TtsProviderKind, string?> cloudKeys)
    {
        _system = system;
        _playback = playback;
        _cloudProviders = cloudProviders;
        _cloudKeys = cloudKeys;
    }

    /// <summary>Raised after any published state changes, on the thread that changed it.</summary>
    public event Action? Changed;

    /// <summary>Loading from the request until audio is audible, then Playing until it ends or stops.</summary>
    public SpeakPhase Phase
    {
        get
        {
            lock (_gate)
                return _phase;
        }
    }

    public bool IsSpeaking => Phase == SpeakPhase.Playing;

    /// <summary>A cloud engine was selected but the system voice played. Reset by each Speak, not by Stop.</summary>
    public bool DidFallBackToSystem
    {
        get
        {
            lock (_gate)
                return _didFallBack;
        }
    }

    /// <summary>The trimmed text of the last Speak (the toolbar's spoken-text body); null after <see cref="ClearReplay"/>.</summary>
    public string? LastSpokenText
    {
        get
        {
            lock (_gate)
                return _lastText;
        }
    }

    /// <summary>"Listen again" is available: audio played for the current text. Survives Stop.</summary>
    public bool CanReplay
    {
        get
        {
            lock (_gate)
                return _canReplay;
        }
    }

    /// <summary>
    /// Speaks <paramref name="text"/> (trimmed; blank changes nothing) with the selected engine. A cloud engine falls
    /// back to the system voice when the provider has no adapter, the text is over the character limit, no key is
    /// saved, or the request or its audio fails. The task completes when the request ends; the App need not await it.
    /// </summary>
    public Task SpeakAsync(string text, SpeakAccent accent, SpeakSettings settings, TtsProviderConfig ttsConfig)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
            return Task.CompletedTask;
        Request request;
        CancellationTokenSource? previous;
        lock (_gate)
        {
            (request, previous) = BeginLocked();
            _didFallBack = false;
            _lastText = trimmed;
            _lastAccent = accent;
            _lastSettings = settings;
            _replaySource = ReplaySource.None;
            _canReplay = false;
            _cloudAudio = null;
        }
        previous?.Cancel();
        Changed?.Invoke();
        return RouteAsync(request, trimmed, accent, settings, ttsConfig);
    }

    /// <summary>
    /// "Listen again": replays the cached cloud audio with no request, or renders the last text again with the system
    /// voice (also after a cloud fallback, so a replay never re-bills). Changes nothing without a replay.
    /// </summary>
    public Task ReplayAsync()
    {
        Request request;
        CancellationTokenSource? previous;
        ReplaySource source;
        byte[]? cloudAudio;
        string text;
        SpeakAccent accent;
        SpeakSettings settings;
        lock (_gate)
        {
            if (_replaySource == ReplaySource.None || _lastText is not { Length: > 0 } last)
                return Task.CompletedTask;
            (request, previous) = BeginLocked();
            (source, cloudAudio, text, accent, settings) = (_replaySource, _cloudAudio, last, _lastAccent, _lastSettings);
            if (source == ReplaySource.CloudCache)
                _didFallBack = false;
        }
        previous?.Cancel();
        Changed?.Invoke();
        return source == ReplaySource.CloudCache && cloudAudio is not null
            ? ReplayCloudAsync(request, cloudAudio, text, accent, settings)
            : SpeakSystemAsync(request, text, accent, settings);
    }

    /// <summary>Stops playback and cancels any request in flight; "Listen again" stays available.</summary>
    public void Stop()
    {
        CancellationTokenSource? previous;
        bool changed;
        lock (_gate)
        {
            previous = _cts;
            _cts = null;
            _generation++;
            changed = _phase != SpeakPhase.Idle;
            _phase = SpeakPhase.Idle;
        }
        previous?.Cancel();
        if (changed)
            Changed?.Invoke();
    }

    /// <summary>Stops and drops the replay and the spoken text (the toolbar closed, or a new selection arrived).</summary>
    public void ClearReplay()
    {
        Stop();
        lock (_gate)
        {
            _replaySource = ReplaySource.None;
            _canReplay = false;
            _lastText = null;
            _cloudAudio = null;
        }
        Changed?.Invoke();
    }

    /// <summary>Supersedes the current request (its source is cancelled by the caller, outside the lock).</summary>
    private (Request, CancellationTokenSource?) BeginLocked()
    {
        var previous = _cts;
        _cts = new CancellationTokenSource();
        _generation++;
        _phase = SpeakPhase.Loading;
        return (new Request(_generation, _cts.Token), previous);
    }

    private bool IsCurrent(Request request)
    {
        lock (_gate)
            return request.Generation == _generation;
    }

    private async Task RouteAsync(
        Request request, string text, SpeakAccent accent, SpeakSettings settings, TtsProviderConfig ttsConfig)
    {
        if (settings.SelectedEngine.CloudProvider is { } kind)
        {
            if (await TrySpeakCloudAsync(request, kind, text, accent, settings, ttsConfig) || !FallBack(request))
                return;
        }
        await SpeakSystemAsync(request, text, accent, settings);
    }

    /// <summary>True when the cloud handled the request (played, or was superseded); false to fall back.</summary>
    private async Task<bool> TrySpeakCloudAsync(
        Request request, TtsProviderKind kind, string text, SpeakAccent accent, SpeakSettings settings,
        TtsProviderConfig ttsConfig)
    {
        // The limit counts user-perceived characters, as Swift does.
        if (_cloudProviders(kind) is not { } provider
            || new StringInfo(text).LengthInTextElements > settings.CloudCharLimit
            || _cloudKeys(kind) is not { Length: > 0 } key)
            return false;

        byte[]? audio = null;
        try
        {
            var language = accent.Bcp47();
            var synthesis = new TtsSynthesisRequest(
                text, TtsVoices.Resolve(language, ttsConfig, provider), language,
                SpeakRules.CloudSpeechSpeed(settings.Rate), settings.Pitch, ttsConfig);
            audio = await provider.SynthesizeAsync(synthesis, key, request.Token);
        }
        catch (Exception)
        {
            // Any failure falls back (macOS parity); the error is not shown.
        }
        if (!IsCurrent(request))
            return true;
        if (audio is not { Length: > 0 })
            return false;
        return await PlayAsync(request, new MemoryStream(audio), AudioContentTypes.Mp3, ReplaySource.CloudCache, audio);
    }

    private async Task ReplayCloudAsync(
        Request request, byte[] audio, string text, SpeakAccent accent, SpeakSettings settings)
    {
        if (!await PlayAsync(request, new MemoryStream(audio), AudioContentTypes.Mp3, ReplaySource.CloudCache, audio))
            await SpeakSystemAsync(request, text, accent, settings);
    }

    private async Task SpeakSystemAsync(Request request, string text, SpeakAccent accent, SpeakSettings settings)
    {
        Stream audio;
        try
        {
            var voice = SpeakRules.ResolveSystemVoice(_system.Voices(), settings, accent);
            audio = await _system.SynthesizeAsync(text, voice, settings.Rate, settings.Pitch, request.Token);
        }
        catch (Exception)
        {
            // No voice, or a synthesis error: nothing to play.
            Finish(request);
            return;
        }
        if (!IsCurrent(request))
        {
            await audio.DisposeAsync();
            return;
        }
        await PlayAsync(request, audio, AudioContentTypes.Wav, ReplaySource.System, cloudAudio: null);
        Finish(request);
    }

    /// <summary>
    /// Plays until the audio ends. False when it failed before it was audible and the request is still current (the
    /// caller may fall back); true otherwise, with the phase back to Idle.
    /// </summary>
    private async Task<bool> PlayAsync(
        Request request, Stream audio, string contentType, ReplaySource source, byte[]? cloudAudio)
    {
        var started = false;
        try
        {
            await _playback.PlayAsync(audio, contentType, () =>
            {
                started = true;
                Started(request, source, cloudAudio);
            }, request.Token);
        }
        catch (Exception)
        {
            // Stopped, superseded, or undecodable audio.
        }
        if (!started && IsCurrent(request))
            return false;
        Finish(request);
        return true;
    }

    private void Started(Request request, ReplaySource source, byte[]? cloudAudio)
    {
        lock (_gate)
        {
            if (request.Generation != _generation)
                return;
            _phase = SpeakPhase.Playing;
            _replaySource = source;
            _canReplay = true;
            // Cached only once it plays, so undecodable audio never becomes the replay.
            if (cloudAudio is not null)
                _cloudAudio = cloudAudio;
        }
        Changed?.Invoke();
    }

    /// <summary>Records a cloud fallback; false when the request was superseded.</summary>
    private bool FallBack(Request request)
    {
        lock (_gate)
        {
            if (request.Generation != _generation)
                return false;
            _didFallBack = true;
        }
        Changed?.Invoke();
        return true;
    }

    private void Finish(Request request)
    {
        lock (_gate)
        {
            if (request.Generation != _generation || _phase == SpeakPhase.Idle)
                return;
            _phase = SpeakPhase.Idle;
        }
        Changed?.Invoke();
    }
}
