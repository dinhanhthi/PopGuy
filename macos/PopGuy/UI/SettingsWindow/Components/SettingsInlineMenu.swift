// SettingsInlineMenu.swift
// PopGuy — UI/SettingsWindow/Components
//
// Shared inline Menu styling for Settings dropdowns (form-row pickers),
// filter controls (Actions type filter, History action filter) and other
// list-style menus (floating-toolbar overflow). Uses a native Menu with an inline Picker or
// Button list — not a custom popover panel.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - Label chrome

/// Closed-state label for Settings picker menus: the title and a menu chevron.
/// `SettingsMenuPicker` and `SettingsInlinePickerMenu` draw it in an
/// input-color capsule.
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

// MARK: - Capsule chrome

extension View {
    /// The capsule trigger shared by the Settings picker menus: the label is
    /// drawn through `BottomBarButtonStyle` (input-color capsule, hover fill,
    /// dimmed when disabled; `menu` keeps it from looking stuck pressed while
    /// the menu is open), with no system indicator, at its ideal size.
    /// `outlined` adds the 1 pt surface edge.
    fileprivate func settingsMenuCapsule(height: CGFloat, horizontalPadding: CGFloat, outlined: Bool) -> some View {
        // A button-style menu draws the SwiftUI label through the button style;
        // a borderless one flattens it to AppKit's image + title and drops the
        // capsule.
        menuStyle(.button)
            .buttonStyle(BottomBarButtonStyle(height: height, horizontalPadding: horizontalPadding, menu: true))
            .menuIndicator(.hidden)
            .fixedSize()
            .overlay {
                if outlined {
                    Capsule().strokeBorder(Palette.surfaceBorder, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Form-row picker

/// A Settings dropdown drawn as a 24 pt capsule (title + chevron), matching
/// the row capsule buttons (`RowTextButtonStyle(formRow:)`), instead of the
/// system pop-up button. A Menu holding an inline Picker; the Menu's label
/// can't read the selected item, so the closed-state `title` is supplied by
/// the caller (or derived from `options`).
struct SettingsMenuPicker<Value: Hashable, Content: View>: View {
    private let label: String
    @Binding private var selection: Value
    private let title: String?
    private let options: [(value: Value, label: String)]?
    private let content: Content

    /// `label` is the accessibility label (what the old Picker title said);
    /// `title` is the closed-state text and should read like the selected item.
    init(_ label: String, selection: Binding<Value>, title: String, @ViewBuilder content: () -> Content) {
        self.label = label
        _selection = selection
        self.title = title
        self.options = nil
        self.content = content()
    }

    var body: some View {
        let shownTitle = title ?? options?.first { $0.value == selection }?.label ?? ""
        Menu {
            Picker("", selection: $selection) {
                if let options {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                } else {
                    content
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            SettingsInlineMenuLabel(title: shownTitle)
        }
        .settingsMenuCapsule(height: 24, horizontalPadding: 12, outlined: false)
        .accessibilityLabel(label)
        .accessibilityValue(shownTitle)
    }
}

extension SettingsMenuPicker where Content == EmptyView {
    /// A flat list of options; the closed-state title is the selected option's
    /// label ("" when none matches).
    init(_ label: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.label = label
        _selection = selection
        self.title = nil
        self.options = options
        self.content = EmptyView()
    }
}

// MARK: - Filter chip

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
        .settingsMenuCapsule(height: 26, horizontalPadding: 10, outlined: true)
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
