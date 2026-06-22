// PopClipExtensionReader.swift
// PopGuy — PluginImport
//
// Reads a PopClip `.popclipext` bundle or a PopClip snippet string into a
// `PopClipConfig`. File-backed shell/AppleScript references are inlined as
// source strings. No code is executed; no network is accessed.
//
// Isolation: nonisolated — all operations are pure FileManager + Decoder work.
// Swift 6 strict concurrency (SWIFT_STRICT_CONCURRENCY = complete).

import Foundation
import Yams

// MARK: - Error

/// Errors thrown by `PopClipExtensionReader`.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum PopClipReadError: Error, Sendable {
    /// No recognizable `Config.*` file was found inside the bundle.
    case configNotFound
    /// The config file format is not supported (unknown extension).
    case unsupportedFormat(String)
    /// A file exceeds the maximum allowed size.
    case tooLarge(String)
    /// The content could not be decoded into a `PopClipConfig`.
    case malformed(String)
}

extension PopClipReadError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .configNotFound:
            return "No Config.plist, Config.yaml, Config.yml, or Config.json found in the extension bundle."
        case .unsupportedFormat(let ext):
            return "Unsupported config format: \(ext)."
        case .tooLarge(let name):
            return "\(name) exceeds the maximum allowed size."
        case .malformed(let detail):
            return "Malformed extension config: \(detail)"
        }
    }
}

// MARK: - Reader

/// Reads a PopClip `.popclipext` bundle or snippet string into a `PopClipConfig`.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
nonisolated enum PopClipExtensionReader {

    // MARK: Private constants

    /// Maximum size for a config or script file (64 KiB).
    private static let maxScriptBytes: Int = 64 * 1_024

    /// Maximum size for a snippet string (256 KiB).
    private static let maxSnippetBytes: Int = 256 * 1_024

    /// Deterministic search order for config files inside a bundle.
    private static let configCandidates: [(name: String, ext: String)] = [
        ("Config", "plist"),
        ("Config", "json"),
        ("Config", "yaml"),
        ("Config", "yml"),
    ]

    // MARK: - Bundle reader

    /// Reads a `.popclipext` bundle directory and returns a decoded `PopClipConfig`.
    ///
    /// - Parameter bundleURL: URL of the `.popclipext` bundle directory.
    /// - Returns: A `PopClipConfig` with file-backed scripts inlined.
    /// - Throws: `PopClipReadError` on missing config, oversized files, or decode failures.
    static func read(bundleURL: URL) throws -> PopClipConfig {
        let configURL = try findConfig(in: bundleURL)
        let ext = configURL.pathExtension.lowercased()

        // Size-guard BEFORE reading.
        try guardSize(of: configURL, label: configURL.lastPathComponent)

        let data = try Data(contentsOf: configURL)

        var config: PopClipConfig
        switch ext {
        case "plist":
            do {
                config = try PropertyListDecoder().decode(PopClipConfig.self, from: data)
            } catch let err as PopClipReadError {
                throw err
            } catch {
                throw PopClipReadError.malformed(error.localizedDescription)
            }
        case "json":
            do {
                config = try JSONDecoder().decode(PopClipConfig.self, from: data)
            } catch let err as PopClipReadError {
                throw err
            } catch {
                throw PopClipReadError.malformed(error.localizedDescription)
            }
        case "yaml", "yml":
            guard let yamlString = String(data: data, encoding: .utf8) else {
                throw PopClipReadError.malformed("Config YAML is not valid UTF-8.")
            }
            do {
                config = try YAMLDecoder().decode(PopClipConfig.self, from: yamlString)
            } catch let err as PopClipReadError {
                throw err
            } catch {
                throw PopClipReadError.malformed(error.localizedDescription)
            }
        default:
            throw PopClipReadError.unsupportedFormat(ext)
        }

        // Inline file-backed scripts relative to the bundle.
        try inlineFileScripts(in: &config, bundleURL: bundleURL)

        return config
    }

    // MARK: - Snippet reader

    /// Parses a PopClip snippet string and returns a `PopClipConfig`.
    ///
    /// Supported snippet forms:
    /// - `#popclip` / `# popclip` header line followed by YAML.
    /// - Fenced code block: `` ```yaml … ``` ``, `` ```json … ``` ``, or bare `` ``` … ``` ``.
    ///
    /// - Parameter snippet: The raw snippet string (e.g. copied from a PopClip extension post).
    /// - Returns: A decoded `PopClipConfig`.
    /// - Throws: `PopClipReadError` on oversized input, empty payload, or decode failures.
    static func read(snippet: String) throws -> PopClipConfig {
        // Size-guard BEFORE any processing.
        guard snippet.utf8.count <= maxSnippetBytes else {
            throw PopClipReadError.tooLarge("snippet")
        }

        let payload = extractPayload(from: snippet)

        guard !payload.isEmpty else {
            throw PopClipReadError.malformed("Snippet contains no decodable payload after stripping headers.")
        }

        // Determine format: trimmed JSON starts with '{'.
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{") {
            // JSON path.
            guard let data = trimmed.data(using: .utf8) else {
                throw PopClipReadError.malformed("Snippet payload is not valid UTF-8.")
            }
            do {
                return try JSONDecoder().decode(PopClipConfig.self, from: data)
            } catch let err as PopClipReadError {
                throw err
            } catch {
                throw PopClipReadError.malformed(error.localizedDescription)
            }
        } else {
            // YAML path — '#popclip' line is a legal YAML comment; YAMLDecoder tolerates it.
            do {
                return try YAMLDecoder().decode(PopClipConfig.self, from: payload)
            } catch let err as PopClipReadError {
                throw err
            } catch {
                throw PopClipReadError.malformed(error.localizedDescription)
            }
        }
    }

    // MARK: - Private helpers

    /// Locates the first matching `Config.*` file inside `bundleURL`, in
    /// deterministic priority order (plist > json > yaml > yml).
    private static func findConfig(in bundleURL: URL) throws -> URL {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: bundleURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        } catch {
            throw PopClipReadError.malformed("Cannot read bundle directory: \(error.localizedDescription)")
        }

        // Build a lowercase-keyed lookup of top-level filenames.
        var fileMap: [String: URL] = [:]
        for url in contents {
            fileMap[url.lastPathComponent.lowercased()] = url
        }

        for candidate in configCandidates {
            let lower = "\(candidate.name.lowercased()).\(candidate.ext)"
            if let match = fileMap[lower] {
                return match
            }
        }

        throw PopClipReadError.configNotFound
    }

    /// Checks that the file at `url` exists and does not exceed `maxScriptBytes`.
    ///
    /// Throws `PopClipReadError.malformed` if the file cannot be read (e.g. missing)
    /// or if the file size cannot be determined (special files, device nodes, pipes).
    /// Throws `PopClipReadError.tooLarge` if the file exceeds the cap.
    private static func guardSize(of url: URL, label: String) throws {
        let resourceValues: URLResourceValues
        do {
            resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            throw PopClipReadError.malformed("Cannot read '\(label)': \(error.localizedDescription)")
        }
        guard let size = resourceValues.fileSize else {
            throw PopClipReadError.malformed("Cannot determine size of '\(label)'.")
        }
        if size > maxScriptBytes {
            throw PopClipReadError.tooLarge(label)
        }
    }

    /// Inlines `shellScriptFile` and `appleScriptFile` references in each action.
    ///
    /// - Parameters:
    ///   - config: The decoded config to mutate in place.
    ///   - bundleURL: The bundle root; all file paths must resolve inside it.
    private static func inlineFileScripts(in config: inout PopClipConfig, bundleURL: URL) throws {
        // Canonical path for the bundle root (resolve symlinks for containment check).
        let bundlePath = bundleURL.resolvingSymlinksInPath().path

        for index in config.actions.indices {
            let action = config.actions[index]

            if let scriptFile = action.shellScriptFile {
                let resolved = try resolveContained(
                    relativePath: scriptFile,
                    insideBundle: bundlePath,
                    bundleURL: bundleURL,
                    label: "shellScriptFile"
                )
                try guardSize(of: resolved, label: scriptFile)
                guard let source = try? String(contentsOf: resolved, encoding: .utf8) else {
                    throw PopClipReadError.malformed("shellScriptFile '\(scriptFile)' is not valid UTF-8.")
                }
                config.actions[index].shellScript = source
            }

            if let scriptFile = action.appleScriptFile {
                let resolved = try resolveContained(
                    relativePath: scriptFile,
                    insideBundle: bundlePath,
                    bundleURL: bundleURL,
                    label: "appleScriptFile"
                )
                try guardSize(of: resolved, label: scriptFile)
                guard let source = try? String(contentsOf: resolved, encoding: .utf8) else {
                    throw PopClipReadError.malformed("appleScriptFile '\(scriptFile)' is not valid UTF-8.")
                }
                config.actions[index].appleScript = source
            }
        }
    }

    /// Resolves a relative file path against the bundle and verifies it stays inside.
    ///
    /// Rejects paths that escape the bundle via `../` components or symlinks.
    ///
    /// - Parameters:
    ///   - relativePath: The untrusted relative path from the config (e.g. `"script.sh"`).
    ///   - insideBundle: Canonical (symlink-resolved) absolute path of the bundle.
    ///   - bundleURL: The bundle URL, used as the base for URL construction.
    ///   - label: Field name, used only in error messages.
    /// - Returns: A file URL for the resolved file.
    /// - Throws: `PopClipReadError.malformed` if the path escapes the bundle.
    private static func resolveContained(
        relativePath: String,
        insideBundle bundlePath: String,
        bundleURL: URL,
        label: String
    ) throws -> URL {
        // Build the candidate URL and resolve symlinks to get a canonical path.
        let candidate = bundleURL.appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()

        // The canonical path must start with bundlePath/ (or equal bundlePath,
        // though that would be a directory, not a script).
        let canonicalPath = candidate.path
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        guard canonicalPath.hasPrefix(prefix) || canonicalPath == bundlePath else {
            throw PopClipReadError.malformed(
                "\(label) '\(relativePath)' escapes the bundle directory."
            )
        }

        return candidate
    }

    /// Strips fenced code blocks and `#popclip` header lines from a snippet,
    /// returning the raw YAML/JSON payload.
    private static func extractPayload(from snippet: String) -> String {
        // Normalize line endings (CRLF and bare CR → LF) before splitting so that
        // `\r\n` does not produce empty elements and corrupt YAML literal block scalars.
        let normalized = snippet
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        // Strip outer fenced code block if present (``` or ```yaml / ```json etc.).
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
            // Remove matching closing fence (last line that starts with ```).
            if let lastFenceIdx = lines.lastIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            }) {
                lines.remove(at: lastFenceIdx)
            }
        }

        // Strip a leading `#popclip` / `# popclip` comment line.
        if let first = lines.first {
            let trimmedFirst = first.trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
            if trimmedFirst == "#popclip" {
                lines.removeFirst()
            }
        }

        return lines.joined(separator: "\n")
    }
}
