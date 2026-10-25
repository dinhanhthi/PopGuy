// PluginImportConsentView.swift
// PopGuy — UI/SettingsWindow
//
// Trust-boundary consent sheet shown before any imported plugin action is added.
// Displays actions to import (including full script bodies) and the skip report.
// Requires explicit user confirmation. Nothing executes here — pure presentation.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - PluginImportConsentView

struct PluginImportConsentView: View {

    let result: PluginImportResult
    let onConfirm: ([CustomAction]) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<UUID> = []

    private var selectedActions: [CustomAction] {
        result.imported.filter { selectedIDs.contains($0.id) }
    }

    private var allSelected: Bool {
        result.imported.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    securityNote
                    if !result.imported.isEmpty {
                        importedSection
                    }
                    if !result.skipped.isEmpty {
                        skippedSection
                    }
                }
                .padding(SettingsMetrics.pagePadding)
            }
            Divider()
            footerBar
        }
        .frame(minWidth: 540, minHeight: 480)
        .onAppear {
            selectedIDs = Set(result.imported.map { $0.id })
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import plugin")
                    .font(.headline)
                Text(result.sourceName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if !result.imported.isEmpty {
                    Label(
                        selectedIDs.count == result.imported.count
                            ? (result.imported.count == 1 ? "1 action to add" : "\(result.imported.count) actions to add")
                            : "\(selectedIDs.count) of \(result.imported.count) selected",
                        systemImage: "plus.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.primary)
                }
                if !result.skipped.isEmpty {
                    Label(
                        result.skipped.count == 1
                            ? "1 item skipped"
                            : "\(result.skipped.count) items skipped",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.cardPadding)
        .padding(.vertical, SettingsMetrics.cardPadding)
    }

    // MARK: - Security note

    private var securityNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.secondary)
                .font(.body)
            Text("Imported scripts run only when you click the action. Review them below — only add plugins you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Imported actions section

    private var importedSection: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
            HStack {
                Text("Actions to add")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(result.imported.map { $0.id })
                    }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundColor(.accentColor)
            }

            ForEach(result.imported) { action in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { selectedIDs.contains(action.id) },
                        set: { checked in
                            if checked { selectedIDs.insert(action.id) }
                            else { selectedIDs.remove(action.id) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .padding(.top, 10)

                    ImportedActionCard(action: action)
                }
            }
        }
    }

    // MARK: - Skipped items section

    private var skippedSection: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
            Text("Not imported")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(result.skipped.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, SettingsMetrics.cardPadding)
                    }
                    SkippedItemRow(item: item)
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
    }

    // MARK: - Footer buttons

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            Button("Add to PopGuy") {
                onConfirm(selectedActions)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, SettingsMetrics.cardPadding)
        .padding(.vertical, SettingsMetrics.cardPadding)
    }
}

// MARK: - ImportedActionCard

/// Displays one imported action in full detail for the user to review.
private struct ImportedActionCard: View {

    let action: CustomAction

    @State private var isExpanded = true

    var body: some View {
        SettingsCard(
            icon: action.icon,
            title: action.title,
            subtitle: action.actionDescription.isEmpty ? nil : action.actionDescription,
            isExpanded: $isExpanded,
            accessory: {
                Text(action.type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                    )
            },
            content: {
                executableContent
                metadataRows
            }
        )
    }

    // MARK: Executable content block

    @ViewBuilder
    private var executableContent: some View {
        let source = action.scriptSource
        if !source.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(executableLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView([.vertical, .horizontal]) {
                    Text(source)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
            }
        } else if action.type == .ai {
            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.vertical) {
                    Text(action.systemPrompt.isEmpty ? "(empty)" : action.systemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(action.systemPrompt.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
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

    private var executableLabel: String {
        switch action.type {
        case .openURL:     return "URL template"
        case .runShortcut: return "Shortcut name"
        case .appleScript: return "AppleScript"
        case .shellScript: return "Shell script"
        default:           return "Script"
        }
    }

    // MARK: Metadata rows

    @ViewBuilder
    private var metadataRows: some View {
        if action.isScriptable {
            MetadataRow(
                label: "After run",
                value: action.afterRun.displayName
            )
            if !action.appliesWhenRegex.isEmpty {
                MetadataRow(
                    label: "Shown when matches",
                    value: action.appliesWhenRegex,
                    valueFont: .system(.caption, design: .monospaced)
                )
            }
        }
    }
}

// MARK: - MetadataRow

private struct MetadataRow: View {
    let label: String
    let value: String
    var valueFont: Font = .callout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .leading)
            Text(value)
                .font(valueFont)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - SkippedItemRow

private struct SkippedItemRow: View {
    let item: SkippedItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.orange)
                .font(.callout)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, SettingsMetrics.cardPadding)
        .padding(.vertical, 8)
    }
}

// MARK: - Preview

#Preview {
    let imported: [CustomAction] = [
        CustomAction(
            id: UUID(),
            title: "Open in Browser",
            actionDescription: "Opens the selected text as a URL",
            icon: .sfSymbol("link"),
            type: .openURL,
            systemPrompt: "",
            providerKind: .anthropic,
            model: "",
            isEnabled: true,
            scriptSource: "https://example.com/search?q={popclip text}",
            afterRun: .closeToolbar,
            appliesWhenRegex: "^https?://"
        ),
        CustomAction(
            id: UUID(),
            title: "Count Words",
            actionDescription: "Counts words in the selection and shows the result",
            icon: .sfSymbol("number"),
            type: .shellScript,
            systemPrompt: "",
            providerKind: .anthropic,
            model: "",
            isEnabled: true,
            scriptSource: "echo \"$POPCLIP_TEXT\" | wc -w | tr -d ' '",
            afterRun: .showResult,
            appliesWhenRegex: ""
        ),
        CustomAction(
            id: UUID(),
            title: "Summarise",
            actionDescription: "Sends selected text to an AI model for summarisation",
            icon: .sfSymbol("sparkles"),
            type: .ai,
            systemPrompt: "Summarise the following text in 2-3 sentences. Be concise.",
            providerKind: .anthropic,
            model: "claude-sonnet-4-6",
            isEnabled: true,
            scriptSource: "",
            afterRun: .showResult,
            appliesWhenRegex: ""
        ),
    ]

    let skipped: [SkippedItem] = [
        SkippedItem(label: "Run JavaScript", reason: "JavaScript actions are not supported"),
        SkippedItem(label: "WebhookAction", reason: "Unknown action type in import file"),
    ]

    let result = PluginImportResult(
        sourceName: "My PopClip Extension v1.2",
        imported: imported,
        skipped: skipped
    )

    PluginImportConsentView(
        result: result,
        onConfirm: { actions in
            print("Confirmed \(actions.count) actions")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
