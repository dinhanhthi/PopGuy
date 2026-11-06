// SettingsHeader.swift
// PopGuy — UI/SettingsWindow/Components
//
// Shared controls of a Settings page's header row (see SettingsPageLayout): a
// capsule group of icon buttons, and a search capsule that grows out of its
// magnifier button. Both are as tall as the header's tab capsule (34 pt).
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

/// Height of a header-row capsule group (as tall as a `CapsuleTabs` group).
private let headerGroupHeight: CGFloat = 34

// MARK: - HeaderButtonGroup

/// Header-row buttons (`HeaderIconButton`s, a `Menu` styled with
/// `HeaderIconButtonStyle`) side by side in one `HeaderCapsule`.
struct HeaderButtonGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 2)
        .frame(height: headerGroupHeight)
        .headerCapsule()
    }
}

// MARK: - HeaderSearchCapsule

/// The header row's search: a magnifier button in its own `HeaderCapsule`
/// that grows into an input capsule with a text field, the `accessory` (a
/// filter menu, shown only while open) and a close button. Esc or the close
/// button clears the text, resets the page's filter (`onClose`) and shrinks it
/// back, so a filter is never active while hidden. Cmd-F opens it and focuses
/// the field, except while a Settings slide-over panel is open
/// (`settingsPanelOpen`). It starts open when the bound text is not empty or
/// a filter is active (`isFilterActive`).
///
/// The open field grows into the header's free space, up to 280 pt. Its 80 pt
/// minimum keeps the capsule (with a "Run Shortcut" filter chip) and the
/// Actions page's 5-button group inside the header at the 720 pt window minimum.
struct HeaderSearchCapsule<Accessory: View>: View {
    @Binding var text: String
    let prompt: String
    /// True while the page's filter (the accessory) is not at its default.
    let isFilterActive: Bool
    /// Resets the page's filter when the search closes.
    let onClose: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    @State private var expanded: Bool
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsPanelOpen) private var panelOpen

    init(
        text: Binding<String>,
        prompt: String,
        isFilterActive: Bool = false,
        onClose: @escaping () -> Void = {},
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        _text = text
        self.prompt = prompt
        self.isFilterActive = isFilterActive
        self.onClose = onClose
        self.accessory = accessory
        _expanded = State(initialValue: !text.wrappedValue.isEmpty || isFilterActive)
    }

    var body: some View {
        // One stack in both states, so the capsule's width animates and the
        // magnifier slides with its leading edge instead of being replaced.
        HStack(spacing: 0) {
            HeaderIconButton(systemImage: "magnifyingglass", tooltip: "Search", action: open)
                // Off behind a slide-over panel: the page stays in the tree.
                .keyboardShortcut(panelOpen ? nil : SwiftUI.KeyboardShortcut("f", modifiers: .command))

            if expanded {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .frame(minWidth: 80, idealWidth: 240, maxWidth: 280)
                    .accessibilityLabel(prompt)

                accessory()
                    .padding(.leading, 6)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.body)
                        .imageScale(.large)
                        .frame(width: headerGroupHeight - 16, height: headerGroupHeight - 16)
                }
                .buttonStyle(RowIconButtonStyle())
                .frame(width: headerGroupHeight, height: headerGroupHeight)
                .accessibilityLabel("Close search")
                .hoverTooltip("Close search (Esc)")
            }
        }
        .padding(.horizontal, 2)
        .frame(height: headerGroupHeight)
        // Clip before the backgrounds: the views coming in or going out stay
        // inside the growing or shrinking capsule, and the fallback capsule's
        // shadow is not cut.
        .clipShape(Capsule())
        .background {
            // Closed: the header button capsule. Open: an input capsule.
            ZStack {
                Color.clear
                    .headerCapsule()
                    .opacity(expanded ? 0 : 1)
                Capsule()
                    .fill(Palette.inputSurface)
                    .overlay(Capsule().strokeBorder(Palette.surfaceBorder, lineWidth: 1))
                    .opacity(expanded ? 1 : 0)
            }
            .allowsHitTesting(false)
        }
        .onExitCommand(perform: close)
        // A panel slid over the page: the hidden field gives up the focus.
        .onChange(of: panelOpen) { open in
            if open { fieldFocused = false }
        }
        // A filter set while closed opens the capsule, so it is never hidden.
        .onChange(of: isFilterActive) { active in
            if active && !expanded { withAnimation(animation) { expanded = true } }
        }
    }

    /// Grows and shrinks the capsule; nothing moves under Reduce Motion.
    private var animation: Animation? { reduceMotion ? nil : Motion.sheet }

    /// Opens the field (the magnifier or Cmd-F) and focuses it on the next
    /// run-loop turn, once the field is in the view tree.
    private func open() {
        if !expanded {
            withAnimation(animation) { expanded = true }
        }
        DispatchQueue.main.async { fieldFocused = true }
    }

    /// Clears the text, resets the filter and shrinks back to the magnifier
    /// (Esc or the close button).
    private func close() {
        guard expanded else { return }
        fieldFocused = false
        text = ""
        onClose()
        withAnimation(animation) { expanded = false }
    }
}

// MARK: - settingsPanelOpen

private struct SettingsPanelOpenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a Settings slide-over panel (Add/Edit Action, Action
    /// Library, memory info) covers the page; set by `SettingsView`.
    var settingsPanelOpen: Bool {
        get { self[SettingsPanelOpenKey.self] }
        set { self[SettingsPanelOpenKey.self] = newValue }
    }
}
