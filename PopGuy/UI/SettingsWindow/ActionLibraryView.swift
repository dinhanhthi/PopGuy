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

    /// False when the user is at the Pro custom-action limit.
    /// Browsing stays enabled; only the Install button is disabled.
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

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            searchBar
            if !canInstall {
                Divider()
                proLimitBanner
            }
            Divider()
            scrollContent
        }
        .frame(minWidth: 560, minHeight: 480)
        .ignoresSafeArea(.container, edges: .top)
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
            Spacer()
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, SettingsMetrics.cardPadding)
        .padding(.vertical, SettingsMetrics.cardPadding + 6)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search actions\u{2026}", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
        }
        .padding(.horizontal, SettingsMetrics.pagePadding)
        .padding(.vertical, 10)
    }

    // MARK: - Pro limit banner

    private var proLimitBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "crown")
                .foregroundStyle(Color.proGold)
                .font(.caption.weight(.semibold))
            Text("Free plan limit reached — upgrade to Pro to install more custom actions.")
                .font(.caption)
                .foregroundStyle(Color.proGold)
        }
        .padding(.horizontal, SettingsMetrics.pagePadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip(isExpanded ? "Hide script" : "Show script")
                }
            }
            .padding(SettingsMetrics.cardPadding)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isScriptableWithBody else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            // Collapsible script body
            if isScriptableWithBody && isExpanded {
                Divider()
                scriptBody
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

    // MARK: - Sub-views

    private var typeBadge: some View {
        Text(action.type.displayName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private var installButton: some View {
        if installed {
            // Already installed — show a disabled checkmark state.
            Label("Installed", systemImage: "checkmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.primary.opacity(0.06))
                )
        } else if canInstall {
            Button("Install", action: onInstall)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            // Limit reached — disabled button with explanation tooltip.
            Button("Install") {}
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(true)
                .hoverTooltip("Free plan limit reached. Upgrade to Pro to install more actions.")
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
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
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
