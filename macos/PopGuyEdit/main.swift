// main.swift — popguy-edit
//
// Terminal Composer CLI: the $VISUAL editor that terminal programs call with a file path.
// It reads and validates the file, sends its text to the running PopGuy app over a
// same-user Unix domain socket (POSIX sockets), then blocks until the composer replies:
// "done" writes the text back in place, tells the app "written" and exits 0; cancel, busy,
// error or a closed connection exit 1 and leave the file untouched; a failed write exits 1
// without "written". The text itself is never printed.

import AppKit
import Foundation

// MARK: - Helpers

/// Prints one "popguy-edit: ..." line on stderr and exits.
func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("popguy-edit: \(message)\n".utf8))
    exit(code)
}

func describe(_ error: any Error) -> String {
    switch error as? ComposerFileError {
    case .notRegularFile: return "not a regular file"
    case .tooLarge: return "file is larger than 1 MiB"
    case .invalidUTF8: return "file is not valid UTF-8"
    case .io(let code): return String(cString: strerror(code))
    case nil: return error.localizedDescription
    }
}

/// `<home>/Library/Application Support/PopGuy/Composer/composer.sock`, with the home
/// directory taken from the password database (never from the environment).
func socketPath() -> String? {
    guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
    return String(cString: dir) + "/Library/Application Support/PopGuy/Composer/composer.sock"
}

/// The socket address, or nil when the path does not fit `sun_path` (with its NUL).
func socketAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

/// One connection attempt on a fresh socket; nil if nobody is listening.
func connectOnce(_ address: sockaddr_un) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = address
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result == 0 { return fd }
    close(fd)
    return nil
}

/// The `PopGuy.app` that contains this executable (`…/X.app/Contents/Helpers/popguy-edit`),
/// resolved through symlinks such as `~/.local/bin/popguy-edit`; nil when run elsewhere.
func enclosingAppPath() -> String? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else {
        return nil
    }
    defer { free(resolved) }
    let helpers = URL(fileURLWithPath: String(cString: resolved)).deletingLastPathComponent()
    let contents = helpers.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
          app.pathExtension == "app" else { return nil }
    return app.path
}

/// Launches the app in the background with LaunchServices' `open` tool.
func launchApp(_ appPath: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-a", appPath]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        // Nothing to do: the retry loop below reports the failure.
    }
}

/// Writes all of `data`, retrying partial writes and EINTR.
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let written = write(fd, base + offset, raw.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

enum ReplyLine {
    case line(Data)
    case closed
    case failed
}

/// Reads one "\n"-framed line, capped at `ComposerMessage.maxLineBytes` (without the "\n").
func readReplyLine(_ fd: Int32) -> ReplyLine {
    var line = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            return .failed
        }
        if count == 0 { return .closed }
        let received = chunk[0..<count]
        if let newline = received.firstIndex(of: 0x0A) {
            line.append(contentsOf: received[..<newline])
            return line.count <= ComposerMessage.maxLineBytes ? .line(line) : .failed
        }
        line.append(contentsOf: received)
        if line.count > ComposerMessage.maxLineBytes { return .failed }
    }
}

// MARK: - Main

// A closed socket must surface as a write error, not kill the process.
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
guard arguments.count == 2, !arguments[1].isEmpty else {
    fail("usage: popguy-edit <file>", code: 2)
}
let path = arguments[1]

let original: ComposerFileContent
do {
    original = try ComposerFileRules.read(path: path)
} catch {
    fail("\(path): \(describe(error))")
}

guard let sockPath = socketPath() else { fail("cannot find the home directory") }
guard let address = socketAddress(sockPath) else { fail("socket path is too long: \(sockPath)") }

var connection = connectOnce(address)
if connection == nil {
    // Launch PopGuy only when it is not running at all; if it runs but does not listen,
    // the feature is off and launching again would not help.
    if NSRunningApplication.runningApplications(withBundleIdentifier: "dinh.thi.PopGuy").isEmpty,
       let appPath = enclosingAppPath() {
        launchApp(appPath)
    }
    // Retry for about 5 s (25 x 200 ms) while the app starts its server.
    for _ in 0..<25 where connection == nil {
        usleep(200_000)
        connection = connectOnce(address)
    }
}
guard let fd = connection else {
    fail("Terminal Composer is off or PopGuy is not running — enable it in PopGuy Settings → Composer.")
}

let request: Data
do {
    let fileName = URL(fileURLWithPath: path).lastPathComponent
    request = try ComposerMessage.encodeLine(.open(text: original.text, fileName: fileName, mode: "edit"))
} catch {
    fail("file is too large to send to PopGuy")
}
guard writeAll(fd, request) else { fail("PopGuy closed the connection") }

// Keep the socket fully open while the composer is up: the app treats EOF as "client gone".
switch readReplyLine(fd) {
case .closed:
    fail("PopGuy closed the connection")
case .failed:
    fail("invalid reply from PopGuy")
case .line(let line):
    guard let reply = try? ComposerMessage.decodeLine(line) else { fail("invalid reply from PopGuy") }
    switch reply {
    case .done(let text, _):
        do {
            try ComposerFileRules.write(text, to: path, original: original)
        } catch {
            fail("\(path): \(describe(error))")
        }
        // Best effort: without it the app keeps the draft and skips auto-submit.
        if let ack = try? ComposerMessage.encodeLine(.written) {
            _ = writeAll(fd, ack)
        }
        close(fd)
        exit(0)
    case .cancel:
        fail("cancelled")
    case .busy:
        fail("another composer is already open")
    case .error(let reason):
        fail(reason)
    case .open, .written:
        fail("invalid reply from PopGuy")
    }
}
