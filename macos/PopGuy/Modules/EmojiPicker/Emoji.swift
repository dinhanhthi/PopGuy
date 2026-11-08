// Emoji.swift
// PopGuy — EmojiPicker
//
// The bundled emoji and symbol data (`Resources/Emoji/emoji.json`, `symbols.json`, generated
// from emojibase in FastMoji), the skin tone setting, and the catalog loader.
//
// Isolation: nonisolated — plain value types and pure functions, usable from any context.

import Foundation

// MARK: - Emoji

/// One entry of the bundled emoji or symbol data.
nonisolated struct Emoji: Codable, Hashable, Identifiable, Sendable {
    let emoji: String
    let description: String
    let category: String
    let aliases: [String]
    let tags: [String]
    /// vi / fr / es labels and tags (absent from some rows).
    var keywords: [String]? = nil
    /// Emoji version the glyph first appeared in (absent from symbols).
    var version: Double? = nil
    /// `skin_tones`: true when the emoji takes a skin tone (absent from the JSON otherwise).
    var skinTones: Bool? = nil
    /// `skin_tones_version`: Emoji version of the toned forms, only when newer than `version`.
    var skinTonesVersion: Double? = nil
    /// Which file the row came from (nil = emoji). Set at load, never decoded.
    var kind: Kind? = nil

    enum Kind: String, Codable, Sendable {
        case symbol
    }

    var id: String { emoji }

    enum CodingKeys: String, CodingKey {
        case emoji, description, category, aliases, tags, keywords, version
        case skinTones = "skin_tones"
        case skinTonesVersion = "skin_tones_version"
    }

    /// `emoji` with `tone` applied: the modifier goes after every modifier base and replaces the
    /// U+FE0F that follows it (✌️ → ✌🏽, 🕵️‍♂️ → 🕵🏽‍♂️, 🧑‍🤝‍🧑 → 🧑🏽‍🤝‍🧑🏽).
    func toned(_ tone: SkinTone) -> String {
        guard skinTones == true, let modifier = tone.modifier else { return emoji }
        var scalars = String.UnicodeScalarView()
        var afterBase = false
        for scalar in emoji.unicodeScalars {
            if afterBase, scalar == "\u{FE0F}" {
                afterBase = false
                continue
            }
            scalars.append(scalar)
            // 🤝 takes a tone on its own, never inside a sequence (🧑‍🤝‍🧑).
            afterBase = scalar.properties.isEmojiModifierBase
                && !(scalar == "\u{1F91D}" && emoji.unicodeScalars.count > 1)
            if afterBase { scalars.append(modifier) }
        }
        return String(scalars)
    }
}

// MARK: - SkinTone

/// Skin tone applied to the people and hand emoji that support one.
nonisolated enum SkinTone: String, CaseIterable, Identifiable, Sendable {
    case none
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var id: String { rawValue }

    /// The Fitzpatrick modifier (U+1F3FB...U+1F3FF), nil for the default yellow.
    var modifier: Unicode.Scalar? {
        switch self {
        case .none: nil
        case .light: "\u{1F3FB}"
        case .mediumLight: "\u{1F3FC}"
        case .medium: "\u{1F3FD}"
        case .mediumDark: "\u{1F3FE}"
        case .dark: "\u{1F3FF}"
        }
    }

    var title: String {
        switch self {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium-Light"
        case .medium: "Medium"
        case .mediumDark: "Medium-Dark"
        case .dark: "Dark"
        }
    }
}

// MARK: - EmojiCatalog

nonisolated enum EmojiCatalog {
    /// Loads `emoji.json`, then `symbols.json`, from the bundle, keeping file order (emojibase
    /// order is category order). Each file fails closed on its own.
    /// Emoji rows newer than `maxVersion` are dropped (the system font can't draw them); rows with
    /// no version are kept. Rows whose toned forms are newer than `maxVersion` lose `skinTones`.
    static func load(
        bundle: Bundle = .main,
        maxVersion: Double = maxEmojiVersion(for: ProcessInfo.processInfo.operatingSystemVersion)
    ) -> [Emoji] {
        let emojis = load("emoji", kind: nil, bundle: bundle)
            .filter { ($0.version ?? 0) <= maxVersion }
            .map { emoji in
                var emoji = emoji
                if (emoji.skinTonesVersion ?? 0) > maxVersion { emoji.skinTones = nil }
                return emoji
            }
        return emojis + load("symbols", kind: .symbol, bundle: bundle)
    }

    /// The rows of `<resource>.json` tagged with `kind`, or none if the file is missing or broken.
    private static func load(_ resource: String, kind: Emoji.Kind?, bundle: Bundle) -> [Emoji] {
        do {
            guard let url = bundle.url(forResource: resource, withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try JSONDecoder().decode([Emoji].self, from: Data(contentsOf: url)).map { emoji in
                var emoji = emoji
                emoji.kind = kind
                return emoji
            }
        } catch {
            assertionFailure("Failed to load \(resource).json: \(error)")
            return []
        }
    }

    /// Newest Emoji version the system font draws on `os`: each step is the macOS release that
    /// shipped it, and anything in between takes the lower step.
    static func maxEmojiVersion(for os: OperatingSystemVersion) -> Double {
        let steps: [(major: Int, minor: Int, version: Double)] = [
            (26, 4, 17.0),
            (15, 4, 16.0),
            (14, 4, 15.1),
            (13, 3, 15.0),
        ]
        let current = (os.majorVersion, os.minorVersion)
        return steps.first { current >= ($0.major, $0.minor) }?.version ?? 14.0
    }
}
