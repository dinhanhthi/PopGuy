using System.IO.Pipes;
using System.Security.Principal;
using Microsoft.UI.Dispatching;
using PopGuy.Core.Composer;

namespace PopGuy.Composer;

/// <summary>Opaque id of one composer session (one popguy-edit connection that sent "open").</summary>
internal readonly record struct ComposerSession(long Id);

/// <summary>
/// Terminal Composer pipe server (macOS ComposerServer): listens on the same-user named pipe
/// <c>PopGuy-Composer-&lt;user SID&gt;</c> for popguy-edit.exe, which sends one "open" line and waits for one reply
/// line; after a "done" reply it sends "written" once the file is written. One composer session is active at a time: a
/// second "open" is answered "busy" and closed, so one unconnected pipe instance is always listening, also while a
/// session is open. Pipe I/O runs on the thread pool; the events are raised on the UI thread, in the order they
/// happened. UNTRUSTED DATA: the prompt text is never logged, only lengths and states.
/// </summary>
internal sealed class ComposerPipeServer(DispatcherQueue dispatcher, Action<string> log)
{
    /// <summary>How long one reply may wait for a client that does not read.</summary>
    private static readonly TimeSpan WriteTimeout = TimeSpan.FromSeconds(5);

    private sealed class Connection(NamedPipeServerStream pipe, long id)
    {
        public NamedPipeServerStream Pipe { get; } = pipe;
        public long Id { get; } = id;
        // Guarded by _gate.
        public bool Replied { get; set; }
        /// <summary>The reply was "done", so a "written" line marks the session delivered.</summary>
        public bool AwaitsWritten { get; set; }
        public bool Delivered { get; set; }
    }

    /// <summary>Per user: the CLI connects to <c>PopGuy-Composer-&lt;its user SID&gt;</c>.</summary>
    private string PipeName { get; } = "PopGuy-Composer-" + WindowsIdentity.GetCurrent().User!.Value;

    private readonly Lock _gate = new();
    // Guarded by _gate.
    private CancellationTokenSource? _run;
    private NamedPipeServerStream? _listening;
    private readonly HashSet<Connection> _connections = [];
    private Connection? _active;
    private long _nextId = 1;

    /// <summary>A client opened a session (its text and file name). Answer it once with <see cref="Reply"/>. UI thread.</summary>
    public event Action<ComposerSession, string, string>? SessionOpened;

    /// <summary>
    /// The session's connection closed: the client exited (also after a "done" reply), failed, the server closed it
    /// after a "cancel", "busy" or "error" reply, or the server stopped. <c>delivered</c> is true only when the client
    /// sent "written" after a "done" reply. Raised exactly once for every session announced by
    /// <see cref="SessionOpened"/>; afterwards replies to it are ignored. UI thread.
    /// </summary>
    public event Action<ComposerSession, bool>? SessionEnded;

    /// <summary>A second "open" arrived while a session was active; the server answers "busy" and closes it. UI thread.</summary>
    public event Action? BusyRejected;

    /// <summary>
    /// Starts listening. Returns false (and logs why) when the pipe cannot be created. Does nothing while already
    /// listening.
    /// </summary>
    public bool Start()
    {
        lock (_gate)
        {
            if (_run is not null) return true;
            NamedPipeServerStream first;
            try
            {
                first = CreateInstance();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                log($"composer: cannot listen, {e.GetType().Name}");
                return false;
            }
            _run = new CancellationTokenSource();
            _listening = first;
            var token = _run.Token;
            _ = Task.Run(() => AcceptLoopAsync(first, token));
            log("composer: listening");
            return true;
        }
    }

    /// <summary>
    /// Stops listening and closes every connection (ending the active session, not delivered). Safe to call twice;
    /// <see cref="Start"/> may be called again afterwards.
    /// </summary>
    public void Stop()
    {
        var pipes = new List<NamedPipeServerStream>();
        lock (_gate)
        {
            if (_run is null) return;
            _run.Cancel();
            _run.Dispose();
            _run = null;
            if (_listening is not null) pipes.Add(_listening);
            _listening = null;
            foreach (var connection in _connections.ToList())
                if (EndLocked(connection)) pipes.Add(connection.Pipe);
            log("composer: stopped");
        }
        foreach (var pipe in pipes) pipe.Dispose();
    }

    /// <summary>
    /// Sends the one reply of <paramref name="session"/>. After <see cref="ComposerMessage.Done"/> the connection stays
    /// open until the client exits; after Cancel, Busy or Error the server closes it. Either way the end is reported by
    /// <see cref="SessionEnded"/>. Replies to an ended session, second replies, and Open or Written are ignored.
    /// </summary>
    public void Reply(ComposerSession session, ComposerMessage message)
    {
        bool closeAfter;
        switch (message)
        {
            case ComposerMessage.Done: closeAfter = false; break;
            case ComposerMessage.Cancel or ComposerMessage.Busy or ComposerMessage.Error: closeAfter = true; break;
            default:
                log("composer: open and written are not replies");
                return;
        }
        Connection connection;
        lock (_gate)
        {
            if (_active is not { } active || active.Id != session.Id || active.Replied)
            {
                log("composer: ignored a reply to an ended or answered session");
                return;
            }
            active.Replied = true;
            active.AwaitsWritten = !closeAfter;
            connection = active;
        }
        _ = Task.Run(() => SendAsync(connection, message, closeAfter));
    }

    private NamedPipeServerStream CreateInstance() => new(
        PipeName,
        PipeDirection.InOut,
        NamedPipeServerStream.MaxAllowedServerInstances,
        PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

    /// <summary>
    /// Waits for clients, one instance at a time. The next instance is created (under the lock, so Stop never leaves
    /// one behind) as soon as a client connects, so a second client can always be answered "busy".
    /// </summary>
    private async Task AcceptLoopAsync(NamedPipeServerStream listening, CancellationToken token)
    {
        while (true)
        {
            var connected = true;
            try
            {
                await listening.WaitForConnectionAsync(token).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException)
            {
                if (token.IsCancellationRequested) return;
                // A client that connected and left at once: replace the instance and keep listening.
                log($"composer: a connection failed, {e.GetType().Name}");
                connected = false;
            }

            Connection? connection = null;
            NamedPipeServerStream? next;
            lock (_gate)
            {
                // Stop already disposed `listening`.
                if (token.IsCancellationRequested) return;
                if (connected)
                {
                    connection = new Connection(listening, _nextId++);
                    _connections.Add(connection);
                }
                try
                {
                    next = CreateInstance();
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    log($"composer: stopped listening, {e.GetType().Name}");
                    next = null;
                }
                _listening = next;
            }
            if (!connected) listening.Dispose();
            if (connection is not null) _ = RunConnectionAsync(connection);
            if (next is null) return;
            listening = next;
        }
    }

    /// <summary>
    /// Reads "\n"-framed lines, capped at <see cref="ComposerMessage.MaxLineBytes"/>. The first line must be "open";
    /// afterwards only "written" (after a "done" reply) matters and the rest is ignored. Ends when the client closes
    /// the pipe or the server disposes it.
    /// </summary>
    private async Task RunConnectionAsync(Connection connection)
    {
        var chunk = new byte[64 * 1024];
        using var pending = new MemoryStream();
        var opened = false;
        try
        {
            while (true)
            {
                var count = await connection.Pipe.ReadAsync(chunk).ConfigureAwait(false);
                if (count == 0) return;
                var start = 0;
                int newline;
                while ((newline = Array.IndexOf(chunk, (byte)'\n', start, count - start)) >= 0)
                {
                    pending.Write(chunk, start, newline - start);
                    start = newline + 1;
                    var length = (int)pending.Length;
                    var message = Decode(pending.GetBuffer().AsSpan(0, length));
                    pending.SetLength(0);
                    if (opened)
                    {
                        if (message is ComposerMessage.Written) MarkDelivered(connection);
                        continue;
                    }
                    if (!await OpenAsync(connection, message, length).ConfigureAwait(false)) return;
                    opened = true;
                }
                pending.Write(chunk, start, count - start);
                if (pending.Length <= ComposerMessage.MaxLineBytes) continue;
                pending.SetLength(0);
                if (opened) continue;
                log("composer: request line exceeds the size cap");
                await SendAsync(connection, new ComposerMessage.Error("Request is too large."), closeAfter: true).ConfigureAwait(false);
                return;
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException)
        {
            // The client went away, or Stop / a closing reply disposed the pipe.
        }
        catch (Exception e)
        {
            log($"composer: connection failed, {e.GetType().Name}");
        }
        finally
        {
            Finish(connection);
        }
    }

    private static ComposerMessage? Decode(ReadOnlySpan<byte> line)
    {
        try
        {
            return ComposerMessage.DecodeLine(line);
        }
        catch (ComposerProtocolException)
        {
            return null;
        }
    }

    /// <summary>Handles the first line. Returns false when the connection was answered and closed.</summary>
    private async Task<bool> OpenAsync(Connection connection, ComposerMessage? message, int length)
    {
        if (message is not ComposerMessage.Open open)
        {
            log($"composer: invalid request ({length} bytes)");
            await SendAsync(connection, new ComposerMessage.Error("Invalid request."), closeAfter: true).ConfigureAwait(false);
            return false;
        }
        lock (_gate)
        {
            // Stop may have ended this connection meanwhile.
            if (!_connections.Contains(connection)) return false;
            if (_active is null)
            {
                _active = connection;
                var session = new ComposerSession(connection.Id);
                log($"composer: session {connection.Id} opened ({length} bytes)");
                Post(() => SessionOpened?.Invoke(session, open.Text, open.FileName));
                return true;
            }
            log("composer: rejected a second session as busy");
            Post(() => BusyRejected?.Invoke());
        }
        await SendAsync(connection, new ComposerMessage.Busy(), closeAfter: true).ConfigureAwait(false);
        return false;
    }

    private void MarkDelivered(Connection connection)
    {
        lock (_gate)
        {
            if (connection.AwaitsWritten) connection.Delivered = true;
        }
    }

    /// <summary>
    /// Writes one line; closes the connection afterwards when asked, or when the line cannot be encoded or written
    /// within <see cref="WriteTimeout"/>. Closing disposes the pipe (never DisconnectNamedPipe, which discards unread
    /// data): the client still reads the line, then sees the end.
    /// </summary>
    private async Task SendAsync(Connection connection, ComposerMessage message, bool closeAfter)
    {
        byte[] line;
        try
        {
            line = ComposerMessage.EncodeLine(message);
        }
        catch (ComposerProtocolException)
        {
            log("composer: reply could not be encoded");
            line = ComposerMessage.EncodeLine(new ComposerMessage.Error("Text is too large."));
            closeAfter = true;
        }
        try
        {
            using var timeout = new CancellationTokenSource(WriteTimeout);
            await connection.Pipe.WriteAsync(line, timeout.Token).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException)
        {
            log($"composer: reply write failed ({line.Length} bytes)");
            closeAfter = true;
        }
        if (closeAfter) Finish(connection);
    }

    /// <summary>Closes a connection and ends its session, if it had one. Idempotent.</summary>
    private void Finish(Connection connection)
    {
        bool ended;
        lock (_gate) ended = EndLocked(connection);
        if (ended) connection.Pipe.Dispose();
    }

    /// <summary>Unregisters a connection and reports the end of its session. False if it was already ended.</summary>
    private bool EndLocked(Connection connection)
    {
        if (!_connections.Remove(connection)) return false;
        if (_active == connection)
        {
            _active = null;
            var session = new ComposerSession(connection.Id);
            var delivered = connection.Delivered;
            log($"composer: session {connection.Id} ended (delivered {delivered})");
            Post(() => SessionEnded?.Invoke(session, delivered));
        }
        return true;
    }

    /// <summary>Raises an event on the UI thread. Called under the lock, so events keep the order of the changes.</summary>
    private void Post(Action raise) => dispatcher.TryEnqueue(() => raise());
}
