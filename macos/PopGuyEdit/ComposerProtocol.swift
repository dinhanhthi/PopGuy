// ComposerProtocol.swift
//
// Terminal Composer wire protocol and file rules, shared by the popguy-edit CLI
// (macos/PopGuyEdit/) and the PopGuy app (macos/PopGuy/Modules/TerminalComposer/).
// MIRROR: both copies must stay byte-identical. Foundation only (no AppKit), so it
// compiles in the command-line tool target too.
//
// Wire protocol: JSON lines over a same-user AF_UNIX socket, UTF-8, one message per "\n".
//   client -> app: open
//   app -> client: done | cancel | busy | error
// Message text is LF-only and never logged.

import Foundation

// MARK: - Wire protocol

// nonisolated: the app target defaults to MainActor isolation; the codec and file
// rules must be callable from the socket queue and from the CLI.
nonisolated enum ComposerMessage: Codable, Equatable, Sendable {

    /// Client -> app: edit `text` (the file's display text) in the composer.
    case open(text: String, fileName: String, mode: String)
    /// App -> client: the user finished; write `text` back. `submit` asks the caller to submit.
    case done(text: String, submit: Bool)
    /// App -> client: the user cancelled; leave the file untouched.
    case cancel
    /// App -> client: another composer session is already open.
    case busy
    /// App -> client: the app refused the request (e.g. the feature is off).
    case error(reason: String)

    /// Cap on the UTF-8 size of a message's text (and of the file the CLI reads).
    static let maxTextBytes = 1_048_576
    /// Cap on one encoded line, without its "\n". JSON escaping inflates text, so it is
    /// larger than `maxTextBytes`; framed reads stop at this many bytes.
    static let maxLineBytes = 8 * 1_048_576

    /// Encodes one message as a JSON line terminated by "\n". The JSON encoder escapes
    /// newlines inside strings, so the only raw "\n" is the terminator.
    static func encodeLine(_ message: ComposerMessage) throws -> Data {
        if let text = message.text, text.utf8.count > maxTextBytes {
            throw ComposerProtocolError.textTooLarge
        }
        var line = try JSONEncoder().encode(message)
        guard line.count <= maxLineBytes else { throw ComposerProtocolError.lineTooLarge }
        line.append(0x0A)
        return line
    }

    /// Decodes one line, with or without its terminating "\n".
    static func decodeLine(_ line: Data) throws -> ComposerMessage {
        let body = line.last == 0x0A ? line.dropLast() : line
        guard body.count <= maxLineBytes else { throw ComposerProtocolError.lineTooLarge }
        let message = try JSONDecoder().decode(ComposerMessage.self, from: body)
        if let text = message.text, text.utf8.count > maxTextBytes {
            throw ComposerProtocolError.textTooLarge
        }
        return message
    }

    private var text: String? {
        switch self {
        case .open(let text, _, _), .done(let text, _): return text
        case .cancel, .busy, .error: return nil
        }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case type, text, fileName, mode, submit, reason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "open":
            self = .open(
                text: try container.decode(String.self, forKey: .text),
                fileName: try container.decode(String.self, forKey: .fileName),
                mode: try container.decode(String.self, forKey: .mode)
            )
        case "done":
            self = .done(
                text: try container.decode(String.self, forKey: .text),
                submit: try container.decode(Bool.self, forKey: .submit)
            )
        case "cancel":
            self = .cancel
        case "busy":
            self = .busy
        case "error":
            self = .error(reason: try container.decode(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown message type"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .open(let text, let fileName, let mode):
            try container.encode("open", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(fileName, forKey: .fileName)
            try container.encode(mode, forKey: .mode)
        case .done(let text, let submit):
            try container.encode("done", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(submit, forKey: .submit)
        case .cancel:
            try container.encode("cancel", forKey: .type)
        case .busy:
            try container.encode("busy", forKey: .type)
        case .error(let reason):
            try container.encode("error", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

nonisolated enum ComposerProtocolError: Error, Equatable, Sendable {
    case lineTooLarge
    case textTooLarge
}

// MARK: - File rules

nonisolated enum ComposerLineEnding: Equatable, Sendable {
    case lf
    case crlf
}

/// What the CLI read from the file: the display text plus what it needs to write it back.
nonisolated struct ComposerFileContent: Equatable, Sendable {
    /// LF-only text without the file's one trailing newline.
    let text: String
    let hadTrailingNewline: Bool
    let lineEnding: ComposerLineEnding
}

nonisolated enum ComposerFileError: Error, Equatable, Sendable {
    case notRegularFile
    case tooLarge
    case invalidUTF8
    case io(errno: Int32)
}

nonisolated enum ComposerFileRules {

    static let maxFileBytes = ComposerMessage.maxTextBytes

    /// Reads the file the editor was given. A missing file is empty text. Only regular
    /// files (a symlink is judged by its target) up to `maxFileBytes` of valid UTF-8 are
    /// accepted. The type is checked with POSIX stat before opening, and the file is opened
    /// non-blocking, so a FIFO or device can never block the read.
    static func read(path: String) throws -> ComposerFileContent {
        var info = stat()
        if stat(path, &info) != 0 {
            if errno == ENOENT {
                return ComposerFileContent(text: "", hadTrailingNewline: false, lineEnding: .lf)
            }
            throw ComposerFileError.io(errno: errno)
        }
        try checkEditable(info)

        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ComposerFileError.io(errno: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Re-check the opened file: the path may have been swapped since stat.
        guard fstat(fd, &info) == 0 else { throw ComposerFileError.io(errno: errno) }
        try checkEditable(info)

        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        guard data.count <= maxFileBytes else { throw ComposerFileError.tooLarge }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ComposerFileError.invalidUTF8
        }

        let lineEnding: ComposerLineEnding = raw.contains("\r\n") ? .crlf : .lf
        var text = normalizeLineEndings(raw)
        let hadTrailingNewline = text.hasSuffix("\n")
        if hadTrailingNewline { text.removeLast() }
        return ComposerFileContent(text: text, hadTrailingNewline: hadTrailingNewline, lineEnding: lineEnding)
    }

    /// Converts CRLF and bare CR to LF. The wire text is LF-only.
    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Writes the composer's LF text back: one trailing newline only if the original had
    /// one, CRLF only if the original used CRLF. Written in place (truncate + write, not an
    /// atomic replace) so symlinks, hard links, permissions and ownership stay as they
    /// are; the caller waits for the editor to exit, so nobody reads a half-written file.
    static func write(_ text: String, to path: String, original: ComposerFileContent) throws {
        var output = normalizeLineEndings(text)
        if original.hadTrailingNewline { output += "\n" }
        if original.lineEnding == .crlf {
            output = output.replacingOccurrences(of: "\n", with: "\r\n")
        }

        let fd = open(path, O_WRONLY | O_CREAT | O_NONBLOCK | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw ComposerFileError.io(errno: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ComposerFileError.io(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ComposerFileError.notRegularFile }
        guard ftruncate(fd, 0) == 0 else { throw ComposerFileError.io(errno: errno) }
        try handle.write(contentsOf: Data(output.utf8))
    }

    private static func checkEditable(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG else { throw ComposerFileError.notRegularFile }
        guard info.st_size <= maxFileBytes else { throw ComposerFileError.tooLarge }
    }
}
