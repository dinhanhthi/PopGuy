// HistoryView.swift
// PopGuy — UI/SettingsWindow
//
// History tab: a search capsule (with an action filter) in the header row, a
// settings card with the two history toggles + Clear All, and a newest-first
// list of recorded action runs. Each row collapses to a summary and
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

    /// IDs of rows currently expanded to show input/output detail.
    @State private var expandedIDs: Set<UUID> = []

    /// Drives the Clear All confirmation dialog.
    @State private var showClearConfirm = false

    /// Free-text query matched against each record's input and output. Not
    /// empty at start → the header's search capsule starts open.
    @State private var searchText = HistoryView.initialSearchText

    /// Selected action-name filter; `nil` means all actions.
    @State private var actionFilter: String? = HistoryView.initialActionFilter

    var body: some View {
        // The page builds its own layout so its header-row search paints in
        // the click's frame; only the body below waits for the deferred turn.
        // The search text, action filter and expanded rows are read here and
        // passed down so the list depends on them explicitly
        // (DeferredSectionContent builds its content in this body anyway).
        let searchText = searchText
        let actionFilter = actionFilter
        let expandedIDs = expandedIDs
        return SettingsPageLayout(trailing: { headerSearch }) {
            DeferredSectionContent {
                pageBody(records: filteredRecords(searchText: searchText, actionFilter: actionFilter),
                         isSearching: Self.isSearching(searchText),
                         expandedIDs: expandedIDs)
            }
        }
    }

    /// The header row's search capsule, with the action filter while open.
    private var headerSearch: some View {
        HeaderSearchCapsule(
            text: $searchText,
            prompt: "Search input & output",
            isFilterActive: actionFilter != nil,
            onClose: { actionFilter = nil }
        ) {
            SettingsInlinePickerMenu(
                selection: $actionFilter,
                displayTitle: Self.chipTitle(actionFilter ?? "All actions"),
                options: [(.none, "All actions")]
                    + availableActions.map { (Optional.some($0), $0) },
                tooltip: "Filter history by action"
            )
        }
    }

    private func pageBody(records: [HistoryRecord], isSearching: Bool, expandedIDs: Set<UUID>) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy so rows materialize on scroll rather than all-at-once
                // (the list is capped at 500 records).
                LazyVStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    settingsCard

                    if history.records.isEmpty {
                        emptyState
                    } else if records.isEmpty {
                        noMatchesState
                    } else {
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
                .padding(SettingsMetrics.pagePadding)
            }
            #if DEBUG
            .onAppear { debugScroll(proxy, records: records) }
            #endif
        }
    }

    #if DEBUG
    /// DEBUG-only QA hook: `--history-scroll=N` scrolls the list to the Nth
    /// record when the page appears, for screenshots of a scrolled list.
    private func debugScroll(_ proxy: ScrollViewProxy, records: [HistoryRecord]) {
        let prefix = "--history-scroll="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
              let index = Int(arg.dropFirst(prefix.count)) else { return }
        guard !records.isEmpty else { return }
        let id = records[min(max(index, 0), records.count - 1)].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// DEBUG-only QA hook: `--history-search=<text>` prefills the search (the
    /// capsule starts open), for screenshots from a shell. Read at state init,
    /// because the capsule decides open/closed when it is created.
    private static var initialSearchText: String {
        let prefix = "--history-search="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return "" }
        return String(arg.dropFirst(prefix.count))
    }

    /// DEBUG-only QA hook: `--history-filter=<action name>` preselects the
    /// action filter (the capsule starts open).
    private static var initialActionFilter: String? {
        let prefix = "--history-filter="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(arg.dropFirst(prefix.count))
    }
    #else
    private static var initialSearchText: String { "" }
    private static var initialActionFilter: String? { nil }
    #endif

    // MARK: - Filtering

    /// True when a non-empty search query is active.
    private static func isSearching(_ searchText: String) -> Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Distinct action names present in the records, sorted for the filter menu.
    private var availableActions: [String] {
        Array(Set(history.records.map(\.actionName))).sorted()
    }

    /// Records narrowed by the action filter and a fuzzy search query that
    /// matches against the input and output text.
    private func filteredRecords(searchText: String, actionFilter: String?) -> [HistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.records.filter { record in
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

    /// The filter chip's title, cut short so a long custom action name never
    /// pushes the header past the window (the chip sizes to its title). The
    /// menu itself lists full names.
    private static func chipTitle(_ name: String) -> String {
        let limit = 20
        return name.count > limit ? String(name.prefix(limit - 1)) + "…" : name
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
                let shown = history.records.count
                Text("\(shown) record\(shown == 1 ? "" : "s")")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Text("Clear All")
                        .foregroundStyle(.red)
                }
                .buttonStyle(RowTextButtonStyle())
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
            LabeledContent {
                Toggle("Enable history", isOn: $settings.historyEnabled)
                    .toggleStyle(CompactSwitch())
                    .labelsHidden()
                    // Out of a Form the content sits right after the label; keep the switches in one trailing column.
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } label: {
                Text("Enable history")
            }

            LabeledContent {
                Toggle("Store full input & output text", isOn: $settings.historyStoreFullText)
                    .toggleStyle(CompactSwitch())
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } label: {
                Group {
                    Text("Store full input & output text")
                    Text("When off, only the beginning and end of each text are kept as a preview.")
                        .font(.settingsCaption)
                }
                .dimmedWhenDisabled()
            }
            .disabled(!settings.historyEnabled)
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
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
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
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(record.sourceAppName ?? "—")
                    Text("·")
                    Text(record.timestamp.formatted(.relative(presentation: .named)))
                    Text("·")
                    Text("\(record.durationMs) ms")
                }
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(RowIconButtonStyle())
            .foregroundStyle(.secondary)
            .hoverTooltip("Delete this record")

            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
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
                    .font(.settingsCaption)
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
                    .font(.settingsCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    copy(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(RowIconButtonStyle())
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
        )
    )
    .frame(width: 740, height: 520)
}
