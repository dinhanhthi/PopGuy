using PopGuy.Core.Speak;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace PopGuy.Platform.Speech;

/// <summary>
/// The one audio player for system and cloud speech (macOS <c>AVSpeechSynthesizer</c> output and
/// <c>AVAudioPlayer</c>), on the Windows media player (WinRT). The audio stream must be seekable (both callers pass
/// memory). A new play stops the current one, whose task then throws OperationCanceledException.
/// <para>
/// Each play gets its own media player, so a late event of a replaced play can never end or start the next one. The
/// player is kept out of the system media controls (media keys and the volume flyout). Its events arrive on media
/// threads: <c>started</c> is called on one of them, and a cancel stops the player on the cancelling thread.
/// </para>
/// </summary>
public sealed class AudioPlayback : IAudioPlayback
{
    private readonly object _gate = new();
    private Session? _current;

    public async Task PlayAsync(Stream audio, string contentType, Action started, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(audio);
        ArgumentNullException.ThrowIfNull(contentType);
        ArgumentNullException.ThrowIfNull(started);
        Session session;
        try
        {
            ct.ThrowIfCancellationRequested();
            session = new Session(audio, contentType, started);
        }
        catch
        {
            await audio.DisposeAsync();
            throw;
        }

        Session? previous;
        lock (_gate)
        {
            previous = _current;
            _current = session;
        }
        previous?.Stop(CancellationToken.None);

        try
        {
            // Already cancelled: the callback runs here, before Play, so nothing is heard.
            using (ct.Register(static (state, token) => ((Session)state!).Stop(token), session))
            {
                session.Play();
                await session.Completion;
            }
        }
        finally
        {
            lock (_gate)
            {
                if (_current == session)
                    _current = null;
            }
            session.Dispose();
        }
    }

    /// <summary>
    /// One play. Exactly one of ended, failed or stopped finishes it (<see cref="TryFinish"/>), and only that one
    /// completes <see cref="Completion"/>, so the player is never disposed while a stop is still using it.
    /// </summary>
    private sealed class Session : IDisposable
    {
        private readonly object _gate = new();

        // Continuations run on the thread pool: never inside a media event or a cancel call.
        private readonly TaskCompletionSource _done = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly Stream _audio;
        private readonly IRandomAccessStream _randomAccess;
        private readonly MediaSource _source;
        private readonly MediaPlayer _player;
        private readonly MediaPlaybackSession _playbackSession;
        private readonly Action _started;
        private bool _hasStarted;
        private bool _finished;

        public Session(Stream audio, string contentType, Action started)
        {
            _audio = audio;
            _started = started;
            _randomAccess = audio.AsRandomAccessStream();
            _source = MediaSource.CreateFromStream(_randomAccess, contentType);
            _player = new MediaPlayer { AutoPlay = false, AudioCategory = MediaPlayerAudioCategory.Speech };
            _player.CommandManager.IsEnabled = false;
            _playbackSession = _player.PlaybackSession;
            _playbackSession.PlaybackStateChanged += OnPlaybackStateChanged;
            _player.MediaEnded += OnMediaEnded;
            _player.MediaFailed += OnMediaFailed;
            _player.Source = _source;
        }

        public Task Completion => _done.Task;

        public void Play()
        {
            lock (_gate)
            {
                if (_finished)
                    return;
            }
            // A stop that lands right here clears the source first, so this plays nothing.
            _player.Play();
        }

        /// <summary>Stops at once: pauses and drops the source on the calling thread, then cancels the task.</summary>
        public void Stop(CancellationToken token)
        {
            if (!TryFinish())
                return;
            try
            {
                _player.Pause();
                _player.Source = null;
            }
            catch (Exception)
            {
                // A stop must not throw out of a cancel call; the player is disposed next anyway.
            }
            _done.TrySetCanceled(token);
        }

        public void Dispose()
        {
            _playbackSession.PlaybackStateChanged -= OnPlaybackStateChanged;
            _player.MediaEnded -= OnMediaEnded;
            _player.MediaFailed -= OnMediaFailed;
            _player.Source = null;
            _player.Dispose();
            _source.Dispose();
            _randomAccess.Dispose();
            _audio.Dispose();
        }

        private void OnPlaybackStateChanged(MediaPlaybackSession sender, object args)
        {
            // Paused and None follow a stop; only Playing means audible.
            if (sender.PlaybackState == MediaPlaybackState.Playing)
                MarkStarted();
        }

        private void OnMediaEnded(MediaPlayer sender, object args)
        {
            // A clip too short to report Playing was still heard: started comes first, or the coordinator falls back.
            MarkStarted();
            if (TryFinish())
                _done.TrySetResult();
        }

        private void OnMediaFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args)
        {
            if (TryFinish())
                _done.TrySetException(new InvalidOperationException(
                    $"The audio could not be played ({args.Error}, 0x{args.ExtendedErrorCode?.HResult:X8})."));
        }

        private void MarkStarted()
        {
            lock (_gate)
            {
                if (_finished || _hasStarted)
                    return;
                _hasStarted = true;
            }
            _started();
        }

        private bool TryFinish()
        {
            lock (_gate)
            {
                if (_finished)
                    return false;
                _finished = true;
                return true;
            }
        }
    }
}
