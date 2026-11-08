// EmojiPickerModel.swift
// PopGuy — EmojiPicker
//
// Query, sections and keyboard selection of the emoji picker (ported from FastMoji).
// Navigation is driven by method calls from a key monitor, never by view focus.
//
// Isolation: the model is MainActor (it drives SwiftUI); its value types and the shared
// catalog are nonisolated.

import Combine
import Foundation

// MARK: - Value types

nonisolated struct PickerSection: Identifiable, Sendable {
    let id: String
    let title: String
    let emojis: [Emoji]
    let columns: Int
}

/// The browse tabs (used when the query is empty); one per `Emoji.Kind`.
nonisolated enum PickerTab: CaseIterable, Sendable {
    case emoji, symbols

    init(kind: Emoji.Kind?) {
        switch kind {
        case nil: self = .emoji
        case .symbol: self = .symbols
        }
    }

    var title: String {
        switch self {
        case .emoji: "Emoji"
        case .symbols: "Symbols"
        }
    }

    /// The `Emoji.kind` of this tab's rows.
    var kind: Emoji.Kind? {
        switch self {
        case .emoji: nil
        case .symbols: .symbol
        }
    }

    var columns: Int { 9 }

    /// Section ids are "<idPrefix>-<name>".
    fileprivate var idPrefix: String {
        switch self {
        case .emoji: "category"
        case .symbols: "symbols"
        }
    }

    /// Stable lowercase name for ids ("frequent-emoji", "results-symbols").
    fileprivate var slug: String {
        switch self {
        case .emoji: "emoji"
        case .symbols: "symbols"
        }
    }
}

nonisolated struct PickerSelection: Equatable, Sendable {
    var section: Int
    var index: Int
}

nonisolated enum MoveDirection: Sendable {
    case left, right, up, down
}

// MARK: - PickerCatalog

/// Read-only data built once from `CatalogIndex.emojis`, so sections, lookups and search results
/// hold the same `Emoji` values (`firstIndex(of:)` stays consistent).
nonisolated final class PickerCatalog: Sendable {
    /// Glyph → emoji, to turn the frecency history back into emojis.
    let byEmoji: [String: Emoji]
    /// Category sections of each tab, built once (rebuilds only concatenate them).
    private let tabSections: [PickerTab: [PickerSection]]

    init(index: CatalogIndex) {
        let emojis = index.emojis
        byEmoji = Dictionary(emojis.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })
        var tabSections: [PickerTab: [PickerSection]] = [:]
        for tab in PickerTab.allCases {
            tabSections[tab] = Self.groupByCategory(emojis.filter { $0.kind == tab.kind }, tab: tab)
        }
        self.tabSections = tabSections
    }

    /// The category sections of `tab`, in catalog order (without "Frequently Used").
    func categorySections(for tab: PickerTab) -> [PickerSection] {
        tabSections[tab] ?? []
    }

    /// One section per category, in catalog order.
    private static func groupByCategory(_ catalog: [Emoji], tab: PickerTab) -> [PickerSection] {
        var order: [String] = []
        var groups: [String: [Emoji]] = [:]
        for emoji in catalog {
            if groups[emoji.category] == nil { order.append(emoji.category) }
            groups[emoji.category, default: []].append(emoji)
        }
        return order.map {
            PickerSection(id: "\(tab.idPrefix)-\($0)", title: $0, emojis: groups[$0] ?? [], columns: tab.columns)
        }
    }
}

// MARK: - EmojiPickerModel

@MainActor
final class EmojiPickerModel: ObservableObject {
    static let frequentCount = 18

    @Published var query = "" {
        didSet {
            // TextField bindings can write the same value back; keep the user's selection then.
            guard query != oldValue else { return }
            rebuild()
        }
    }

    /// Browse tab, shown while the query is empty; a search lists every kind whatever the tab.
    @Published var tab: PickerTab = .emoji {
        didSet {
            // With a query the sections don't depend on the tab.
            guard tab != oldValue, query.isEmpty else { return }
            rebuild()
        }
    }

    /// Every section holds at least one emoji; empty when a search has no hits.
    @Published private(set) var sections: [PickerSection] = []
    @Published private(set) var selection: PickerSelection?
    /// Bumped by every `reset()` so views can react to a reopen even when nothing else changed.
    @Published private(set) var resetCount = 0
    /// True once the user moved the selection since the last query change / reset.
    private(set) var hasMoved = false

    var onConfirm: ((Emoji) -> Void)?

    private let catalog: PickerCatalog
    private let search: EmojiSearch
    private let frecency: EmojiFrecency

    init(catalog: PickerCatalog, search: EmojiSearch, frecency: EmojiFrecency) {
        self.catalog = catalog
        self.search = search
        self.frecency = frecency
        rebuild()
    }

    var selectedEmoji: Emoji? {
        guard let selection else { return nil }
        return sections[selection.section].emojis[selection.index]
    }

    func move(_ direction: MoveDirection) {
        hasMoved = true
        guard let current = selection else { return }
        let columns = sections[current.section].columns
        let count = sections[current.section].emojis.count
        let row = current.index / columns
        let col = current.index % columns
        let lastRow = (count - 1) / columns
        let hasNext = current.section + 1 < sections.count
        let hasPrevious = current.section > 0
        var next = current

        switch direction {
        case .right:
            if current.index + 1 < count {
                next.index += 1
            } else if hasNext {
                next = PickerSelection(section: current.section + 1, index: 0)
            }
        case .left:
            if current.index > 0 {
                next.index -= 1
            } else if hasPrevious {
                let previous = current.section - 1
                next = PickerSelection(section: previous, index: sections[previous].emojis.count - 1)
            }
        case .down:
            if row < lastRow {
                next.index = min(current.index + columns, count - 1)
            } else if hasNext {
                let following = sections[current.section + 1]
                next = PickerSelection(
                    section: current.section + 1,
                    index: min(min(col, following.columns - 1), following.emojis.count - 1)
                )
            }
        case .up:
            if row > 0 {
                next.index -= columns
            } else if hasPrevious {
                let previous = sections[current.section - 1]
                let previousLastRow = (previous.emojis.count - 1) / previous.columns
                next = PickerSelection(
                    section: current.section - 1,
                    index: min(
                        previousLastRow * previous.columns + min(col, previous.columns - 1),
                        previous.emojis.count - 1
                    )
                )
            }
        }
        selection = next
    }

    /// Selects the first cell of section `sectionIndex` (category bar). Counts as a user move.
    func jump(to sectionIndex: Int) {
        guard sections.indices.contains(sectionIndex) else { return }
        selection = PickerSelection(section: sectionIndex, index: 0)
        hasMoved = true
    }

    /// Selects `emoji` in section `section` (it may also appear in "Frequently Used").
    func select(_ emoji: Emoji, in section: Int) {
        guard sections.indices.contains(section),
              let index = sections[section].emojis.firstIndex(of: emoji) else { return }
        selection = PickerSelection(section: section, index: index)
    }

    /// Records the selected emoji in the history, then hands it to `onConfirm`.
    func confirm() {
        guard let emoji = selectedEmoji else { return }
        frecency.record(emoji.emoji)
        onConfirm?(emoji)
    }

    /// Re-reads the history, clears the query and refreshes "Frequently Used" (call each time
    /// the picker opens).
    func reset() {
        frecency.reload()
        if query.isEmpty {
            rebuild()
        } else {
            query = ""
        }
        resetCount += 1
    }

    private func rebuild() {
        if query.isEmpty {
            // Rank the whole history, then keep this tab's kind, so other kinds never take its slots.
            let tab = self.tab
            let frequent = frecency.top(frecency.entries.count)
                .compactMap { catalog.byEmoji[$0] }
                .filter { $0.kind == tab.kind }
                .prefix(Self.frequentCount)
            sections = (frequent.isEmpty
                ? []
                : [PickerSection(
                    id: "frequent-\(tab.slug)",
                    title: "Frequently Used",
                    emojis: Array(frequent),
                    columns: tab.columns
                )])
                + catalog.categorySections(for: tab)
        } else {
            let frecency = self.frecency
            let hits = search.search(query) { frecency.score($0) }
            sections = Self.groupByKind(hits)
        }
        selection = sections.isEmpty ? nil : PickerSelection(section: 0, index: 0)
        hasMoved = false
    }

    /// One section per kind ("Emoji", "Symbols"), in order of first appearance in the ranked
    /// hits, so the kind with the best (penalized) score leads; each keeps the ranked order.
    private static func groupByKind(_ hits: [Emoji]) -> [PickerSection] {
        var order: [PickerTab] = []
        var groups: [PickerTab: [Emoji]] = [:]
        for hit in hits {
            let tab = PickerTab(kind: hit.kind)
            if groups[tab] == nil { order.append(tab) }
            groups[tab, default: []].append(hit)
        }
        return order.map {
            PickerSection(id: "results-\($0.slug)", title: $0.title, emojis: groups[$0] ?? [], columns: $0.columns)
        }
    }
}
