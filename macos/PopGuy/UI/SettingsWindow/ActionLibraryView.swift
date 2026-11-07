// ActionLibraryView.swift
// PopGuy — UI/SettingsWindow
//
// Gallery sheet for the Action Library preset catalog.
// Browsing — search + category sections + per-preset detail.
// Install — calls the caller-supplied closure; no direct SettingsStore access.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - ResolvedPreset

/// A preset with its `CustomAction` resolved exactly once at view init.
///
/// The resolved `action` is used for display (title, description, icon) and
/// for the collapsible script body — so `make()` is never called again during
/// filtering or rendering. The `preset` is forwarded to `onInstall` and
/// `isInstalled` so install wiring remains on the stable catalog identity.
private struct ResolvedPreset: Identifiable {
    let preset: LibraryPreset
    let action: CustomAction

    var id: String { preset.id }
}

// MARK: - ActionLibraryView

struct ActionLibraryView: View {

    /// When false, the Install button is disabled (browsing stays enabled).
    let canInstall: Bool

    /// Returns true when a preset is already installed.
    let isInstalled: (LibraryPreset) -> Bool

    /// Called when the user taps Install on a preset.
    let onInstall: (LibraryPreset) -> Void

    /// Called when the user taps Done / close.
    let onClose: () -> Void

    /// All presets resolved once at init — `make()` is called exactly once
    /// per preset for the lifetime of the sheet.
    private let rows: [ResolvedPreset]

    init(
        canInstall: Bool,
        isInstalled: @escaping (LibraryPreset) -> Bool,
        onInstall: @escaping (LibraryPreset) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.canInstall = canInstall
        self.isInstalled = isInstalled
        self.onInstall = onInstall
        self.onClose = onClose
        self.rows = ActionLibrary.allPresets().map { preset in
            ResolvedPreset(preset: preset, action: preset.make())
        }
    }

    @State private var query = ""

    /// The search field takes the keyboard focus when the modal opens.
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            scrollContent
        }
        // No minimum height: the modal card sets the height, the list scrolls.
        .frame(minWidth: 560)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Action Library")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Ready-made actions — install with one click.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            // The search shrinks to its minimum before the title truncates.
            .layoutPriority(1)
            Spacer(minLength: 8)
            searchField
            // No Return shortcut: the search field has focus when the modal
            // opens, and Return there closed the Library mid-search. Esc closes.
            Button("Done", action: onClose)
                .buttonStyle(BottomBarButtonStyle(height: 28, prominent: true, horizontalPadding: 12))
        }
        // At the top of the modal card, symmetric vertical padding.
        .padding(.horizontal, SettingsMetrics.cardPadding)
        .padding(.vertical, SettingsMetrics.cardPadding + 6)
    }

    // MARK: - Search field

    /// Always-open search in the header row, styled like the Settings header
    /// search when it is open: an input capsule with a magnifier.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search actions\u{2026}", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                // The capsule's accent edge shows the focus instead.
                .modifier(NoFocusRing())
                .accessibilityLabel("Search actions")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .accessibilityLabel("Clear search")
                .hoverTooltip("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(minWidth: 180, maxWidth: 320)
        .background(
            Capsule()
                .fill(Palette.inputSurface)
                // Accent edge while focused, like the Settings text inputs.
                .overlay(
                    Capsule().strokeBorder(
                        searchFocused ? Color.accentColor : Palette.surfaceBorder,
                        lineWidth: searchFocused ? 1.5 : 1)
                )
                .animation(Motion.hover, value: searchFocused)
        )
        // Esc clears the text first; with an empty field it closes the modal.
        .onExitCommand {
            if query.isEmpty { onClose() } else { query = "" }
        }
        // Next run-loop turn, once the modal card is in the window.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    // MARK: - Scrollable content

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing, pinnedViews: []) {
                ForEach(ActionLibrary.categories) { category in
                    let categoryRows = filteredRows(in: category)
                    if !categoryRows.isEmpty {
                        categorySection(category: category, rows: categoryRows)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.pagePadding)
            .padding(.vertical, SettingsMetrics.pagePadding)
        }
    }

    // MARK: - Category section

    @ViewBuilder
    private func categorySection(category: LibraryCategory, rows: [ResolvedPreset]) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
            Text(category.displayName)
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                LibraryPresetRow(
                    preset: row.preset,
                    action: row.action,
                    installed: isInstalled(row.preset),
                    canInstall: canInstall,
                    onInstall: { onInstall(row.preset) }
                )
            }
        }
    }

    // MARK: - Filter

    /// Returns cached rows for `category`, filtered by the current query.
    /// Uses already-resolved `action.title`/`actionDescription` — no new `make()` calls.
    private func filteredRows(in category: LibraryCategory) -> [ResolvedPreset] {
        let q = trimmedQuery
        let categoryRows = rows.filter { $0.preset.category == category }
        guard !q.isEmpty else { return categoryRows }
        return categoryRows.filter { row in
            row.action.title.localizedCaseInsensitiveContains(q)
                || row.action.actionDescription.localizedCaseInsensitiveContains(q)
        }
    }
}

// MARK: - LibraryPresetRow

/// Displays one library preset with icon, title, description, type badge,
/// optional collapsible script body, and an Install / Installed button.
///
/// Receives the already-resolved `CustomAction` from the parent (resolved
/// once in `ActionLibraryView.init`) so `make()` is never called here.
private struct LibraryPresetRow: View {

    let preset: LibraryPreset
    let action: CustomAction
    let installed: Bool
    let canInstall: Bool
    let onInstall: () -> Void

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True when the action has a non-empty scriptSource (shell / applescript / url / shortcut).
    private var hasScriptBody: Bool {
        !action.scriptSource.isEmpty
    }

    /// Whether this action type shows a collapsible script body.
    ///
    /// Scoped to `.shellScript` and `.appleScript` — the arbitrary-code-execution
    /// types where showing what will run is the security-transparency point. `.openURL`
    /// presets are numerous (all web/search/maps/apps catalog entries are URL templates)
    /// and showing a chevron on every one of them would clutter the gallery; URL templates
    /// are lower-risk and their content is self-explanatory from the action title.
    private var isScriptableWithBody: Bool {
        switch action.type {
        case .shellScript, .appleScript:
            return hasScriptBody
        default:
            return false
        }
    }

    /// Label for the script body label.
    private var scriptLabel: String {
        switch action.type {
        case .openURL:     return "URL template"
        case .runShortcut: return "Shortcut name"
        case .appleScript: return "AppleScript"
        case .shellScript: return "Shell script"
        default:           return "Script"
        }
    }

    /// Shows or hides the script body; instant under Reduce Motion (the card's height changes).
    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : Motion.toggle) { isExpanded.toggle() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack(spacing: 8) {
                // Action icon
                ActionIconView(icon: action.icon, font: .system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                // Title + description
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.body)
                    if !action.actionDescription.isEmpty {
                        Text(action.actionDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                // Type badge
                typeBadge

                // Install / Installed button
                installButton

                // Script disclosure chevron (only when there is a body to show)
                if isScriptableWithBody {
                    Button(action: toggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(RowIconButtonStyle())
                    .hoverTooltip(isExpanded ? "Hide script" : "Show script")
                }
            }
            .padding(SettingsMetrics.cardPadding)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isScriptableWithBody else { return }
                toggleExpanded()
            }

            // Collapsible script body
            if isScriptableWithBody && isExpanded {
                Divider()
                scriptBody
                    .padding(SettingsMetrics.cardPadding)
            }
        }
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
    }

    // MARK: - Sub-views

    private var typeBadge: some View {
        Text(action.type.displayName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.inputSurface))
    }

    @ViewBuilder
    private var installButton: some View {
        if installed {
            // Already installed — a non-interactive chip, the size of a row button.
            Label("Installed", systemImage: "checkmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Palette.inputSurface))
        } else if canInstall {
            Button("Install", action: onInstall)
                .buttonStyle(RowTextButtonStyle(prominent: true))
        } else {
            Button("Install") {}
                .buttonStyle(RowTextButtonStyle(prominent: true))
                .disabled(true)
        }
    }

    private var scriptBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scriptLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(action.scriptSource.contains("\n") ? [.vertical, .horizontal] : .horizontal) {
                Text(action.scriptSource)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.top, 8)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.inputSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Palette.surfaceBorder, lineWidth: 1)
            )
        }
    }
}

// MARK: - Preview

#Preview {
    ActionLibraryView(
        canInstall: true,
        isInstalled: { _ in false },
        onInstall: { preset in
            print("Install: \(preset.id)")
        },
        onClose: {
            print("Close")
        }
    )
}
