// PopClipConfig.swift
// PopGuy — PluginImport
//
// Decodable mirror of the PopClip extension Config schema.
//
// Isolation: nonisolated / Sendable value types — pure data, no execution,
// no file IO. The reader and adapter tasks handle those.
//
// Decoding is PERMISSIVE:
//  - Unknown keys are silently ignored (DynamicKey container).
//  - Missing keys default to nil / empty.
//  - Per-field aliases handle PopClip's dual "space form" and camelCase naming.
//  - Type mismatches on individual fields fail the field silently, not the whole decode.

import Foundation

// MARK: - DynamicKey

/// A CodingKey that accepts any string key, allowing unknown keys to be ignored.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated private struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - SkipDecodable

/// A black-hole Decodable used to advance past a malformed element in an unkeyed container.
/// Accepts any value regardless of type by consuming a nested container or scalar.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated private struct SkipDecodable: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        // Consume the element without retaining any data.
        if (try? decoder.unkeyedContainer()) != nil { return }
        if (try? decoder.container(keyedBy: DynamicKey.self)) != nil { return }
        var single = try decoder.singleValueContainer()
        // Try the most permissive scalar type — Bool subsumes most primitives via
        // singleValueContainer, but String or Int may match where Bool does not.
        if (try? single.decode(String.self)) != nil { return }
        if (try? single.decode(Bool.self)) != nil { return }
        if (try? single.decode(Int.self)) != nil { return }
        if (try? single.decode(Double.self)) != nil { return }
        _ = try? single.decodeNil()
    }
}

// MARK: - PopClipConfig

/// Top-level model for a PopClip extension config file (plist / YAML / JSON).
///
/// Supports both the multi-action form (`actions` array) and the single-action
/// shorthand form where action fields appear at the root level.
///
/// After decoding, `actions` always contains the resolved action list:
/// - Multi-action: `actions` array decoded as-is.
/// - Single-action (no `actions` key): the root is decoded as a `PopClipAction`
///   and wrapped into a one-element array.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct PopClipConfig: Decodable, Sendable {

    /// Extension display name (may fall back to the action title in the adapter).
    let name: String?

    /// Reverse-DNS bundle identifier for the extension.
    let identifier: String?

    /// Extension-level icon (PopClip icon syntax, e.g. `"symbol:star"`).
    /// The adapter falls back to this when an action has no icon of its own.
    let icon: String?

    /// Resolved list of actions — always populated after decode.
    /// `var` so `PopClipExtensionReader` can inline file-backed scripts after decoding.
    var actions: [PopClipAction]

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        // try? decodeIfPresent returns T?? — flatMap collapses to T?.
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let v = (try? container.decodeIfPresent(String.self,
                                                           forKey: DynamicKey(stringValue: key))).flatMap({ $0 }) {
                    return v
                }
            }
            return nil
        }

        name       = string("name")
        identifier = string("identifier")
        icon       = string("icon")

        // Resolve actions: prefer the explicit `actions` array; fall back to
        // treating the root container itself as a single action.
        // Important: if `actions` key is PRESENT (even as []), use it as-is.
        // Only when it is ABSENT do we attempt single-action root decoding.
        if container.contains(DynamicKey(stringValue: "actions")) {
            // Decode element-by-element so one malformed element is skipped but all
            // valid actions are preserved. A type mismatch on the whole array (e.g. the
            // key maps to a scalar) falls back to empty — consistent with old behavior.
            var decoded: [PopClipAction] = []
            if var unkeyed = try? container.nestedUnkeyedContainer(forKey: DynamicKey(stringValue: "actions")) {
                while !unkeyed.isAtEnd {
                    if let action = try? unkeyed.decode(PopClipAction.self) {
                        decoded.append(action)
                    } else {
                        // Skip the malformed element by advancing past it with a dummy decode.
                        _ = try? unkeyed.decode(SkipDecodable.self)
                    }
                }
            }
            actions = decoded
        } else {
            // No `actions` key — try decoding the root as a single action.
            if let single = try? PopClipAction(from: decoder) {
                actions = [single]
            } else {
                actions = []
            }
        }
    }
}

// MARK: - PopClipAction

/// A single action within a PopClip extension config.
///
/// All fields are optional — decode permissively so that an action with unknown
/// or partially-populated fields does not break import of the whole extension.
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated struct PopClipAction: Decodable, Sendable {

    // MARK: Identity / Display

    /// Action display name. Aliases: `"title"`, `"label"`.
    let title: String?

    /// Action icon (PopClip icon syntax, e.g. `"symbol:globe"`, `"text:AB"`).
    let icon: String?

    /// Reverse-DNS identifier for this action within the extension.
    let identifier: String?

    // MARK: Filtering

    /// Regular expression; action is active only when the selection matches.
    let regex: String?

    /// Requirements array — strings like `"text"`, `"url"`. Decoded from either
    /// a JSON array of strings or a single string (wrapped into a one-element array).
    let requirements: [String]?

    // MARK: Lifecycle hooks

    /// Action to perform before running (e.g. `"cut"`, `"copy"`).
    let before: String?

    /// Action to perform after running (e.g. `"paste"`, `"paste-result"`).
    let after: String?

    // MARK: Executors (one active per action)

    /// URL template with optional `***` placeholder for the selected text.
    let url: String?

    /// Key combo trigger. Aliases: `"key combo"`, `"keyCombo"`, `"key combos"`.
    /// When the source is an array, the first element is captured.
    let keyCombo: String?

    /// Inline shell script source. Aliases: `"shell script"`, `"shellScript"`.
    /// `var` so `PopClipExtensionReader` can inline file-backed scripts after decoding.
    var shellScript: String?

    /// Path to a shell script file within the extension bundle.
    /// Aliases: `"shell script file"`, `"shellScriptFile"`.
    let shellScriptFile: String?

    /// Shell/interpreter to use for the script (e.g. `"/usr/bin/python3"`).
    let interpreter: String?

    /// Inline AppleScript source.
    /// Aliases: `"apple script"`, `"applescript"`, `"appleScript"`.
    /// `var` so `PopClipExtensionReader` can inline file-backed scripts after decoding.
    var appleScript: String?

    /// Path to an AppleScript file within the extension bundle.
    /// Aliases: `"apple script file"`, `"applescriptFile"`, `"appleScriptFile"`.
    let appleScriptFile: String?

    /// AppleScript handler call descriptor.
    /// Aliases: `"apple script call"`, `"applescriptCall"`.
    let appleScriptCall: String?

    /// Name of an Apple Shortcuts shortcut to run.
    /// Aliases: `"shortcut name"`, `"shortcutName"`.
    let shortcutName: String?

    /// Name of a macOS service to invoke.
    /// Aliases: `"service name"`, `"serviceName"`.
    let serviceName: String?

    /// Inline JavaScript source. Aliases: `"javascript"`, `"js"`.
    let javascript: String?

    /// Path to a JavaScript file within the extension bundle.
    /// Aliases: `"javascript file"`, `"javascriptFile"`.
    let javascriptFile: String?

    // MARK: Options presence

    /// True when the extension defines an `options` array (user-configurable settings).
    let hasOptions: Bool

    // MARK: - Decodable

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        // MARK: Helpers (local functions — inherit nonisolation from the enclosing init)

        /// Return the first non-nil String decoded from the given keys, in order.
        /// try? wraps decodeIfPresent result in an extra Optional layer (T??) — flatMap collapses to T?.
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let v = (try? container.decodeIfPresent(String.self,
                                                           forKey: DynamicKey(stringValue: key))).flatMap({ $0 }) {
                    return v
                }
            }
            return nil
        }

        /// Decode `requirements` permissively: accept `[String]` or a bare `String`.
        func requirements(for key: String) -> [String]? {
            let k = DynamicKey(stringValue: key)
            if let arr = (try? container.decodeIfPresent([String].self, forKey: k)).flatMap({ $0 }) {
                return arr
            }
            if let single = (try? container.decodeIfPresent(String.self, forKey: k)).flatMap({ $0 }) {
                return [single]
            }
            return nil
        }

        /// Decode a key-combo field permissively: accept `String` or `[String]` (take first).
        func keyCombo(for keys: String...) -> String? {
            for key in keys {
                let k = DynamicKey(stringValue: key)
                if let s = (try? container.decodeIfPresent(String.self, forKey: k)).flatMap({ $0 }) {
                    return s
                }
                if let first = (try? container.decodeIfPresent([String].self, forKey: k)).flatMap({ $0 })?.first {
                    return first
                }
            }
            return nil
        }

        // MARK: Decode fields

        title      = string("title", "label")
        icon       = string("icon")
        identifier = string("identifier")
        regex      = string("regex")
        before     = string("before")
        after      = string("after")
        url        = string("url")
        interpreter = string("interpreter")

        self.requirements = requirements(for: "requirements")
        self.keyCombo     = keyCombo(for: "key combo", "keyCombo", "key combos")

        shellScript     = string("shell script",      "shellScript")
        shellScriptFile = string("shell script file", "shellScriptFile")
        appleScript     = string("apple script",      "applescript",     "appleScript")
        appleScriptFile = string("apple script file", "applescriptFile", "appleScriptFile")
        appleScriptCall = string("apple script call", "applescriptCall")
        shortcutName    = string("shortcut name",     "shortcutName")
        serviceName     = string("service name",      "serviceName")
        javascript      = string("javascript",        "js")
        javascriptFile  = string("javascript file",   "javascriptFile")

        hasOptions = container.contains(DynamicKey(stringValue: "options"))
    }
}
