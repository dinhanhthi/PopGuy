// EmojiFrecency.swift
// PopGuy — EmojiPicker
//
// Emoji usage history for "Frequently Used" and search ranking: count × exponential decay
// (half-life 7 days), persisted in UserDefaults.
//
// Isolation: MainActor (module default) — owned by the picker model.

import Foundation

final class EmojiFrecency {
    nonisolated struct Entry: Codable, Sendable {
        var count: Int
        var lastUsed: Date
    }

    static let defaultsKey = "emojiPicker.frecency.v1"
    private static let halfLifeDays = 7.0

    private(set) var entries: [String: Entry] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    /// Re-reads the history from defaults, so a key removed elsewhere (Settings "Clear") is
    /// never written back from this cached copy.
    func reload() {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func record(_ emoji: String, now: Date = Date()) {
        var entry = entries[emoji] ?? Entry(count: 0, lastUsed: now)
        entry.count += 1
        entry.lastUsed = now
        entries[emoji] = entry
        save()
    }

    func score(_ emoji: String, now: Date = Date()) -> Double {
        guard let entry = entries[emoji] else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(entry.lastUsed)) / 86_400
        return Double(entry.count) * pow(0.5, ageDays / Self.halfLifeDays)
    }

    /// The `n` highest-scoring emoji; ties go to the most recently used.
    func top(_ n: Int, now: Date = Date()) -> [String] {
        let ranked = entries
            .map { (emoji: $0.key, score: score($0.key, now: now), lastUsed: $0.value.lastUsed) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.lastUsed > $1.lastUsed }
        return ranked.prefix(max(0, n)).map(\.emoji)
    }

    func clear() {
        entries = [:]
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
