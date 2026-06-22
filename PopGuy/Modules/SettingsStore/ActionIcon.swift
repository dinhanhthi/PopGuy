// ActionIcon.swift
// PopGuy — SettingsStore
//
// Typed icon model for custom actions.
//
// Isolation: nonisolated / Sendable value type — pure data that crosses actor
// boundaries alongside CustomAction.

import Foundation

// MARK: - ActionIcon

/// The icon displayed on a custom action toolbar button.
///
/// An icon is either an SF Symbol name (rendered via `Image(systemName:)`)
/// or an emoji character (rendered as plain text).
///
/// Codable layout:
///   `{"type": "sfSymbol", "value": "sparkles"}`
///   `{"type": "emoji",    "value": "🎯"}`
// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ActionIcon: Codable, Sendable, Equatable, Hashable {
    /// An SF Symbol, identified by its system name (e.g. `"sparkles"`).
    case sfSymbol(String)
    /// An emoji character (e.g. `"🎯"`).
    case emoji(String)

    // MARK: - Default

    /// Default icon for new custom actions.
    static let `default`: ActionIcon = .sfSymbol("sparkles")

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case type, value }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sfSymbol(let name):
            try container.encode("sfSymbol", forKey: .type)
            try container.encode(name, forKey: .value)
        case .emoji(let character):
            try container.encode("emoji", forKey: .type)
            try container.encode(character, forKey: .value)
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        switch type_ {
        case "sfSymbol":
            self = .sfSymbol(value)
        case "emoji":
            self = .emoji(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown ActionIcon type: \(type_)"
            )
        }
    }
}
