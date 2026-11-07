// ComposerServer.swift
//
// Terminal Composer socket server: listens on a same-user Unix domain socket (POSIX
// sockets driven by Dispatch sources) for the popguy-edit CLI, which sends one "open"
// line and waits for one reply line. One composer session is active at a time.
// Prompt text is never logged; only lengths and states.

import Foundation
import os

/// Opaque id of one composer session (one popguy-edit connection that sent "open").
nonisolated struct ComposerSession: Hashable, Sendable {
    fileprivate let id: Int
}

/// Receives server events on the main actor, in the order they happened.
@MainActor
protocol ComposerServerDelegate: AnyObject {
    /// A client opened a session. Answer it once with `ComposerServer.reply(_:to:)`.
    func composerServer(_ server: ComposerServer, didOpen session: ComposerSession, text: String, fileName: String)
    /// The session's connection closed: the client exited (also after a "done" reply, which
    /// is how the owner times auto-submit), failed, the server closed it after a "cancel" or
    /// "error" reply, or the server stopped. Fires exactly once for every session announced
    /// by `didOpen`; after it, the session is gone and replies to it are ignored.
    func composerServer(_ server: ComposerServer, sessionDidEnd session: ComposerSession)
    /// A second "open" arrived while a session was active; the server already replied
    /// "busy" and closed that connection.
    func composerServerDidRejectBusy(_ server: ComposerServer)
}

/// Thread safety: every mutable stored property is read and written only on `queue`
/// (a private serial Dispatch queue that also runs every Dispatch source handler);
/// the public methods hop onto it. That confinement is the invariant behind
/// `@unchecked Sendable`, the same idea as `RegexCache` with its lock.
/// Call `stop()` before releasing the server so its sources and descriptors are freed.
nonisolated final class ComposerServer: @unchecked Sendable {

    @MainActor weak var delegate: (any ComposerServerDelegate)?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PopGuy", category: "composer")
    /// How long one reply may wait for a client that does not read.
    private static let writeTimeoutMs = 5_000

    private enum State {
        case awaitingOpen
        case session(ComposerSession, replied: Bool)
    }

    private final class Connection {
        let id: Int
        let fd: Int32
        let source: any DispatchSourceRead
        var state: State = .awaitingOpen
        var input: [UInt8] = []

        init(id: Int, fd: Int32, source: any DispatchSourceRead) {
            self.id = id
            self.fd = fd
            self.source = source
        }
    }

    private let queue = DispatchQueue(label: "PopGuy.ComposerServer")
    private var listener: (any DispatchSourceRead)?
    private var socketPath: String?
    private var connections: [Int: Connection] = [:]
    private var active: (session: ComposerSession, connection: Int)?
    private var nextID = 1

    init() {}

    // MARK: Public API

    /// Starts listening. Returns false (and logs why) when the socket cannot be served,
    /// e.g. the path is too long or another process already listens on it.
    @discardableResult
    func start() -> Bool {
        queue.sync { startOnQueue() }
    }

    /// Stops listening, closes every connection (ending the active session) and removes
    /// the socket file. Safe to call twice; `start()` may be called again afterwards.
    func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Sends the one reply of `session`. After `.done` the connection stays open until the
    /// client exits; after `.cancel` or `.error` the server closes it. Either way the end is
    /// reported by `sessionDidEnd`. Replies to an ended session, second replies, and
    /// `.open`/`.busy` (not replies) are ignored.
    func reply(_ message: ComposerMessage, to session: ComposerSession) {
        queue.async { [self] in replyOnQueue(message, to: session) }
    }

    // MARK: Listening

    private func startOnQueue() -> Bool {
        guard listener == nil else { return true }
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            Self.log.error("Composer: cannot find the home directory")
            return false
        }
        let directory = String(cString: home) + "/Library/Application Support/PopGuy/Composer"
        let path = directory + "/composer.sock"
        guard let address = Self.socketAddress(path) else {
            Self.log.error("Composer: socket path is too long (\(path.utf8.count) bytes)")
            return false
        }
        guard Self.prepareDirectory(directory) else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.log.error("Composer: socket failed (errno \(errno))")
            return false
        }
        var bound = Self.bind(fd, address)
        if !bound && errno == EADDRINUSE {
            guard Self.isStale(address) else {
                Self.log.error("Composer: another process is listening on the socket")
                close(fd)
                return false
            }
            unlink(path)
            bound = Self.bind(fd, address)
        }
        guard bound else {
            Self.log.error("Composer: bind failed (errno \(errno))")
            close(fd)
            return false
        }
        // umask is process-wide, so the mode is set explicitly before anyone can connect.
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0, Self.configure(fd) else {
            Self.log.error("Composer: socket setup failed (errno \(errno))")
            close(fd)
            unlink(path)
            return false
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
        socketPath = path
        Self.log.info("Composer: listening")
        return true
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        for connection in Array(connections.values) {
            finish(connection)
        }
        if let socketPath {
            unlink(socketPath)
            Self.log.info("Composer: stopped")
        }
        socketPath = nil
    }

    /// Accepts every pending client of the non-blocking listener.
    private func acceptAll(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard Self.configure(fd), getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Self.log.error("Composer: rejected a connection (setup failed or another user)")
                close(fd)
                continue
            }
            let id = nextID
            nextID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(connectionID: id) }
            source.setCancelHandler { close(fd) }
            connections[id] = Connection(id: id, fd: fd, source: source)
            source.resume()
        }
    }

    // MARK: Connections

    /// One read per event (the source fires again while data remains).
    private func readAvailable(connectionID: Int) {
        guard let connection = connections[connectionID] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = chunk.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else {
            finish(connection)
            return
        }
        // Only the first line matters; later bytes are drained and ignored.
        guard case .awaitingOpen = connection.state else { return }
        let searchStart = connection.input.count
        connection.input.append(contentsOf: chunk[0..<count])
        if let newline = connection.input[searchStart...].firstIndex(of: 0x0A) {
            let line = Data(connection.input[..<newline])
            connection.input = []
            handleFirstLine(line, on: connection)
        } else if connection.input.count > ComposerMessage.maxLineBytes {
            connection.input = []
            Self.log.error("Composer: request line exceeds the size cap")
            send(.error(reason: "Request is too large."), on: connection, thenClose: true)
        }
    }

    private func handleFirstLine(_ line: Data, on connection: Connection) {
        guard let message = try? ComposerMessage.decodeLine(line),
              case .open(let text, let fileName, _) = message else {
            Self.log.error("Composer: invalid request (\(line.count) bytes)")
            send(.error(reason: "Invalid request."), on: connection, thenClose: true)
            return
        }
        if active != nil {
            Self.log.info("Composer: rejected a second session as busy")
            send(.busy, on: connection, thenClose: true)
            notify { server, delegate in delegate.composerServerDidRejectBusy(server) }
            return
        }
        let session = ComposerSession(id: connection.id)
        connection.state = .session(session, replied: false)
        active = (session, connection.id)
        Self.log.info("Composer: session \(session.id) opened (\(text.utf8.count) bytes)")
        notify { server, delegate in
            delegate.composerServer(server, didOpen: session, text: text, fileName: fileName)
        }
    }

    private func replyOnQueue(_ message: ComposerMessage, to session: ComposerSession) {
        guard let active, active.session == session, let connection = connections[active.connection],
              case .session(_, replied: false) = connection.state else {
            Self.log.info("Composer: ignored a reply to an ended or answered session")
            return
        }
        let closeAfter: Bool
        switch message {
        case .done: closeAfter = false
        case .cancel, .error: closeAfter = true
        case .open, .busy:
            Self.log.fault("Composer: open/busy is not a reply")
            return
        }
        connection.state = .session(session, replied: true)
        send(message, on: connection, thenClose: closeAfter)
    }

    /// Writes one reply line; closes the connection afterwards when asked, or when the
    /// line cannot be encoded or written.
    private func send(_ message: ComposerMessage, on connection: Connection, thenClose: Bool) {
        var shouldClose = thenClose
        let line: Data
        if let encoded = try? ComposerMessage.encodeLine(message) {
            line = encoded
        } else if let fallback = try? ComposerMessage.encodeLine(.error(reason: "Text is too large.")) {
            Self.log.error("Composer: reply could not be encoded")
            line = fallback
            shouldClose = true
        } else {
            finish(connection)
            return
        }
        if !Self.writeAll(connection.fd, line) {
            Self.log.error("Composer: reply write failed (\(line.count) bytes)")
            shouldClose = true
        }
        if shouldClose { finish(connection) }
    }

    /// Closes a connection (its descriptor closes in the source's cancel handler) and ends
    /// its session, if it had one.
    private func finish(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        connection.source.cancel()
        guard let active, active.connection == connection.id else { return }
        self.active = nil
        let session = active.session
        Self.log.info("Composer: session \(session.id) ended")
        notify { server, delegate in delegate.composerServer(server, sessionDidEnd: session) }
    }

    /// Hops to the main queue (FIFO, so events keep their order) and calls the delegate.
    private func notify(_ body: @escaping @MainActor @Sendable (ComposerServer, any ComposerServerDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let delegate = self.delegate else { return }
                body(self, delegate)
            }
        }
    }

    // MARK: POSIX helpers

    /// The socket address, or nil when the path does not fit `sun_path` with its NUL.
    private static func socketAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Creates the socket directory if needed and makes it a 0700 directory owned by us.
    private static func prepareDirectory(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            log.error("Composer: cannot create the socket directory")
            return false
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              chmod(path, 0o700) == 0 else {
            log.error("Composer: the socket directory is not a private directory of this user")
            return false
        }
        return true
    }

    private static func bind(_ fd: Int32, _ address: sockaddr_un) -> Bool {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    /// True when nobody listens on the existing socket file (connect is refused).
    private static func isStale(_ address: sockaddr_un) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        var address = address
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result != 0 && errno == ECONNREFUSED
    }

    /// Non-blocking, close-on-exec, and no SIGPIPE when writing to a closed peer.
    private static func configure(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0
            && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
            && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    /// Writes all of `data` to a non-blocking socket, waiting with POSIX poll while the
    /// send buffer is full, for at most `writeTimeoutMs` in total.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(writeTimeoutMs) * 1_000_000
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                guard written < 0 && errno == EAGAIN else { return false }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let waitMs = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(writeTimeoutMs)))
                if poll(&pollFD, 1, waitMs) < 0 && errno != EINTR { return false }
            }
            return true
        }
    }
}
