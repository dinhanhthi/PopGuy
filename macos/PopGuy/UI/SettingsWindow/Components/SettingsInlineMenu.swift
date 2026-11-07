// SettingsInlineMenu.swift
// PopGuy — UI/SettingsWindow/Components
//
// Shared inline Menu styling for Settings filter controls (Actions type
// filter, History action filter) and other list-style menus (floating-toolbar
// overflow). Uses a native Menu with an inline Picker or
// Button list — not a custom popover panel.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - Label chrome

/// Closed-state label for Settings filter menus: the title and a menu chevron.
/// `SettingsInlinePickerMenu` draws it in an input-color capsule.
struct SettingsInlineMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .lineLimit(1)
            MenuChevron()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Picker menu

/// Inline Picker inside a Menu whose trigger is a small input-color capsule
/// (title + chevron), e.g. Actions → All Types. It reads as a chip on the
/// window glass and inside a header search capsule (same fill, so the 1 pt
/// edge outlines it there).
struct SettingsInlinePickerMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let displayTitle: String
    let options: [(value: Value, label: String)]
    var tooltip: String? = nil

    var body: some View {
        Menu {
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
        // A button-style menu draws the SwiftUI label through the button style;
        // a borderless one flattens it to AppKit's image + title and drops the
        // capsule.
        .menuStyle(.button)
        .buttonStyle(BottomBarButtonStyle(height: 26, horizontalPadding: 10, menu: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay(Capsule().strokeBorder(Palette.surfaceBorder, lineWidth: 1).allowsHitTesting(false))
        .hoverTooltip(tooltip ?? "")
    }
}

// MARK: - Generic list menu

/// Borderless Menu wrapper for arbitrary menu content (e.g. the floating toolbar's overflow menu).
struct SettingsInlineMenu<Label: View, MenuContent: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu(content: menuContent, label: label)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
    }
}
