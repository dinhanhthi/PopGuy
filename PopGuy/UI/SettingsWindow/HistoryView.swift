// HistoryView.swift
// PopGuy — UI/SettingsWindow
//
// History tab: a settings card with the two history toggles + Clear All, and a
// newest-first list of recorded action runs. Each row collapses to a summary and
// expands to show the input/output text with per-section Copy and a per-row delete.
//
// Isolation: @MainActor throughout (implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION).
// macOS 13 compatible — no APIs newer than 13 without `if #available`.

import SwiftUI
import AppKit

// MARK: - HistoryView

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var licenseGate: LicenseGate
    var onUpgrade: () -> Void = {}

    /// IDs of rows currently expanded to show input/output detail.
    @State private var expandedIDs: Set<UUID> = []

    /// Drives the Clear All confirmation dialog.
    @State private var showClearConfirm = false

    /// Free-text query matched against each record's input and output.
    @State private var searchText: String = ""

    /// Selected action-name filter; `nil` means all actions.
    @State private var actionFilter: String? = nil

    /// True while the filter bar is stuck to the top (the settings card has
    /// scrolled past it). Drives the bar's larger pinned padding.
    @State private var isPinned = false

    /// Coordinate space used to measure the filter bar's offset from the top.
    private let scrollSpace = "historyScroll"

    var body: some View {
        ScrollView {
            // pinnedViews keeps the filter bar (the Section header) glued to the
            // top once the settings card scrolls past it, and lets it drop back
            // into place when scrolled to the top. Lazy so rows materialize on
            // scroll rather than all-at-once (the list is capped at 500 records).
            // Small outer spacing controls the gap around the filter bar (card ↔
            // bar and bar ↔ rows). The rows keep their own 16pt gap via a nested
            // stack so only the bar sits tight.
            LazyVStack(alignment: .leading, spacing: 4,
                       pinnedViews: [.sectionHeaders]) {
                settingsCard

                if cappedRecords.isEmpty {
                    emptyState
                } else {
                    Section {
                        let records = filteredRecords
                        if records.isEmpty {
                            noMatchesState
                        } else {
                            LazyVStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                                ForEach(records) { record in
                                    HistoryRow(
                                        // While searching, expand every match so the
                                        // hit is visible without an extra click.
                                        record: record,
                                        isExpanded: isSearching || expandedIDs.contains(record.id),
                                        onToggle: { toggleExpanded(record.id) },
                                        onDelete: { history.delete(id: record.id) }
                                    )
                                }
                            }
                        }
                    } header: {
                        filterBar
                    }
                }
            }
            .padding(SettingsMetrics.pagePadding)
        }
        .coordinateSpace(name: scrollSpace)
        .onPreferenceChange(HeaderOffsetKey.self) { minY in
            // The header pins at the top of the scroll view, where its minY
            // settles at ~0. A small threshold absorbs sub-pixel jitter.
            let pinned = minY <= 1
            if pinned != isPinned { isPinned = pinned }
        }
    }

    // MARK: - Filtering

    /// True when a non-empty search query is active.
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether full-text search is available for this tier.
    private var searchAllowed: Bool { licenseGate.entitlements.historySearchAllowed }

    /// Records capped to the tier's retention limit (view-layer only — store is never trimmed).
    private var cappedRecords: [HistoryRecord] {
        let cap = licenseGate.entitlements.maxHistoryRetained
        return Array(history.records.prefix(cap))
    }

    /// Distinct action names present in the capped records, sorted for the filter menu.
    private var availableActions: [String] {
        Array(Set(cappedRecords.map(\.actionName))).sorted()
    }

    /// Records narrowed by the action filter and a fuzzy search query that
    /// matches against the input and output text.
    private var filteredRecords: [HistoryRecord] {
        // Search is Pro-only — ignore the query when not allowed.
        let query = searchAllowed
            ? searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return cappedRecords.filter { record in
            if let actionFilter, record.actionName != actionFilter { return false }
            if !query.isEmpty {
                return Self.fuzzyMatches(query, in: record.input)
                    || Self.fuzzyMatches(query, in: record.output)
            }
            return true
        }
    }

    /// Fuzzy subsequence match: every non-whitespace character of `query` must
    /// appear in `text`, in order, case-insensitively (fzf/Sublime style).
    private static func fuzzyMatches(_ query: String, in text: String) -> Bool {
        let haystack = text.lowercased()
        var index = haystack.startIndex
        for ch in query.lowercased() where !ch.isWhitespace {
            guard let found = haystack[index...].firstIndex(of: ch) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if searchAllowed {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search input & output", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .hoverTooltip("Clear search")
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        Text("Search input & output")
                            .foregroundStyle(.tertiary)
                        ProBadge()
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Custom Menu (not a native Picker) so its label is built the
                // same way as the search box — identical vertical padding and
                // rounded-rect background — guaranteeing both controls share the
                // exact same height. A native .menu Picker renders as a fixed-
                // height NSPopUpButton bezel that can't be matched to the box.
                Menu {
                    Picker("", selection: $actionFilter) {
                        Text("All actions").tag(String?.none)
                        ForEach(availableActions, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        Text(actionFilter ?? "All actions")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if !searchAllowed {
                UpgradePromptView(
                    message: "History search requires a Pro plan. Upgrade to search across all recorded actions.",
                    onUpgrade: onUpgrade
                )
            }
        }
        // Tight when resting (below the History card); roomier when pinned to
        // the top so the stuck bar has breathing room above and below.
        .padding(.vertical, isPinned ? 10 : 0)
        // A backing that replays the window's own backdrop so rows scrolling
        // underneath are masked while the bar is pinned. Using the .windowBackground
        // material (not a solid color) matches the page exactly — the detail area
        // has no opaque fill, so windowBackgroundColor reads too light against it.
        // In the resting position (below the History card) it is therefore
        // invisible. Extended past the page padding to span edge-to-edge, and a
        // little above so the gap to the row above is masked when pinned (kept
        // small so it never cuts into the card at rest).
        .background(
            WindowBackdrop()
                .padding(.horizontal, -SettingsMetrics.pagePadding)
                .padding(.top, -1)
        )
        // Measure the bar's distance from the top to detect when it pins.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: HeaderOffsetKey.self,
                    value: geo.frame(in: .named(scrollSpace)).minY
                )
            }
        )
    }

    // MARK: - No matches state

    private var noMatchesState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No matching records")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    // MARK: - Settings card

    private var settingsCard: some View {
        SettingsCard(title: "History", accessory: {
            HStack(spacing: 8) {
                let shown = cappedRecords.count
                let total = history.records.count
                let countText = licenseGate.entitlements.isPro || shown == total
                    ? "\(shown) record\(shown == 1 ? "" : "s")"
                    : "\(shown) of \(total) record\(total == 1 ? "" : "s")"
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear All", role: .destructive) {
                    showClearConfirm = true
                }
                .disabled(history.records.isEmpty)
            }
            .confirmationDialog(
                "Clear all history?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) { history.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes every recorded action. This cannot be undone.")
            }
        }) {
            HStack(spacing: 20) {
                Toggle("Enable history", isOn: $settings.historyEnabled)

                Toggle("Store full input & output text", isOn: $settings.historyStoreFullText)
                    .disabled(!settings.historyEnabled)
            }

            Text("When off, only the beginning and end of each text are kept as a preview.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No history yet")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }
}

// MARK: - HeaderOffsetKey

/// Reports the filter bar's top offset within the scroll view so the view can
/// tell when the bar has pinned to the top.
private struct HeaderOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - WindowBackdrop

/// Reproduces the Settings window's own backdrop via `NSVisualEffectView` with
/// the `.windowBackground` material. The detail area has no opaque fill, so a
/// plain `windowBackgroundColor` reads too light against it; this matches the
/// real window background exactly, keeping the pinned filter bar invisible at
/// rest while still masking rows that scroll beneath it.
private struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - HistoryRow

/// A single history record: a tappable summary row that expands to reveal the
/// input/output text (or the error message on failure) with Copy buttons.
private struct HistoryRow: View {
    let record: HistoryRecord
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isExpanded {
                Divider()
                detail
                    .padding(SettingsMetrics.cardPadding)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(spacing: 10) {
            statusBadge

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.actionName)
                        .font(.headline)
                    Text(providerModelText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(record.sourceAppName ?? "—")
                    Text("·")
                    Text(record.timestamp.formatted(.relative(presentation: .named)))
                    Text("·")
                    Text("\(record.durationMs) ms")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .hoverTooltip("Delete this record")

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(SettingsMetrics.cardPadding)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    /// Provider, plus the model when this provider exposes one.
    private var providerModelText: String {
        if let kind = record.providerKind {
            if kind.usesModel, !record.model.isEmpty {
                return "\(kind.displayName) · \(record.model)"
            }
            return kind.displayName
        }
        // Runs without a ProviderKind (Speak): show the TTS engine label, plus the
        // accent stored in `model` when present.
        let label = record.providerLabel ?? "—"
        return record.model.isEmpty ? label : "\(label) · \(record.model)"
    }

    @ViewBuilder
    private var statusBadge: some View {
        if record.success {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
            if record.truncated {
                Label("Preview only — full text was not stored.", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            textSection(title: "Input", text: record.input)

            if record.success {
                textSection(title: "Output", text: record.output)
            } else {
                textSection(title: "Error", text: record.errorMessage ?? "Unknown error", tint: .red)
            }
        }
    }

    @ViewBuilder
    private func textSection(title: String, text: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    copy(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip("Copy \(title.lowercased())")
            }
            Text(text.isEmpty ? "—" : text)
                .font(.callout)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Preview

#Preview("History") {
    let store = HistoryStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("preview.PopGuy.history.json")
    )
    store.clearAll()
    store.record(actionName: "Improve", providerKind: .anthropic, model: "claude-sonnet-4-6",
                 sourceBundleID: "com.apple.Notes", sourceAppName: "Notes", durationMs: 842,
                 success: true, errorMessage: nil,
                 input: "teh quick brown fox", output: "The quick brown fox.", storeFullText: true)
    store.record(actionName: "Translate", providerKind: .deepL, model: "",
                 sourceBundleID: "com.apple.Safari", sourceAppName: "Safari", durationMs: 1203,
                 success: false, errorMessage: "Invalid API key.",
                 input: "Bonjour le monde", output: "", storeFullText: true)
    return HistoryView(
        history: store,
        settings: SettingsStore(
            defaults: UserDefaults(suiteName: "preview.PopGuy.HistoryView") ?? .standard
        ),
        licenseGate: LicenseGate()
    )
    .frame(width: 740, height: 520)
}
