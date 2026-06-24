// SettingsInlineMenu.swift
// PopGuy — UI/SettingsWindow/Components
//
// Shared inline Menu styling for Settings filter controls (Actions type
// filter, History action filter) and other list-style menus (Import plugin,
// floating-toolbar overflow). Uses a native Menu with an inline Picker or
// Button list — not a custom popover panel.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - Toolbar icon chrome

/// Shared pill chrome for the Actions toolbar icon controls (Export, Import,
/// Import plugin, Browse Library) so every trigger — Button or Menu — has the
/// exact same padding, corner radius, and height. Native `.bordered` button and
/// pull-down `Menu` bezels differ in height, so we render our own.
private let toolbarIconCornerRadius: CGFloat = 6
private let toolbarIconHPadding: CGFloat = 9
private let toolbarIconVPadding: CGFloat = 6

extension View {
    /// Applies the shared toolbar-icon pill background (resting state).
    /// Padding defaults match the bordered Button siblings; callers (e.g. the
    /// plugin Menu trigger) may override to fine-tune their own footprint.
    func toolbarIconChrome(
        pressed: Bool = false,
        hPadding: CGFloat = toolbarIconHPadding,
        vPadding: CGFloat = toolbarIconVPadding
    ) -> some View {
        self
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
            .background(
                RoundedRectangle(cornerRadius: toolbarIconCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.14 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: toolbarIconCornerRadius, style: .continuous))
    }
}

/// Button style matching `toolbarIconChrome` for the Actions toolbar row.
struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .toolbarIconChrome(pressed: configuration.isPressed)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Label chrome

/// Closed-state label for Settings filter menus (text + chevron + wash).
struct SettingsInlineMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
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
}

// MARK: - Picker menu

/// Inline Picker inside a borderless Menu — matches Actions → All Types.
struct SettingsInlinePickerMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let displayTitle: String
    let options: [(value: Value, label: String)]
    var tooltip: String? = nil

    var body: some View {
        inlineMenu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            SettingsInlineMenuLabel(title: displayTitle)
        }
        .fixedSize()
        .hoverTooltip(tooltip ?? "")
    }
}

// MARK: - Generic list menu

/// Borderless Menu wrapper for arbitrary menu content (Import plugin, toolbar overflow, …).
struct SettingsInlineMenu<Label: View, MenuContent: View>: View {
    /// When true, renders the trigger as a standard bordered toolbar icon button
    /// (Settings → Actions Import/Export/Library row). When false, borderless.
    var borderedToolbarTrigger: Bool = false
    @ViewBuilder let label: () -> Label
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        inlineMenu(
            borderedToolbarTrigger: borderedToolbarTrigger,
            content: menuContent,
            label: label
        )
    }
}

// MARK: - Shared modifiers

private func inlineMenu<Label: View, MenuContent: View>(
    borderedToolbarTrigger: Bool = false,
    @ViewBuilder content: @escaping () -> MenuContent,
    @ViewBuilder label: @escaping () -> Label
) -> some View {
    Group {
        if borderedToolbarTrigger {
            // Borderless menu (no native bezel), then wrap the whole trigger in the
            // shared pill chrome so background + height match the sibling
            // ToolbarIconButtonStyle buttons. (Applying chrome to the label inside a
            // borderless Menu does not render the background.)
            Menu(content: content, label: label)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                // The Menu trigger needs slightly tighter horizontal and taller
                // vertical padding than the bordered Button siblings to read as the
                // same footprint.
                .toolbarIconChrome(hPadding: 7, vPadding: 8)
        } else {
            Menu(content: content, label: label)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
        }
    }
}
