// EmojiGridView.swift
// PopGuy — EmojiPicker
//
// Tabs, category row, emoji grid and description footer of the emoji picker (ported from
// FastMoji), driven entirely by `EmojiPickerModel`. 360x288 (9 flexible columns of 32 pt
// tall cells); `EmojiPickerView` adds its search header on top (333 tall in the panel).
//
// Isolation: MainActor (SwiftUI).

import AppKit
import SwiftUI

struct EmojiGridView: View {
    @ObservedObject var model: EmojiPickerModel
    let skinTone: SkinTone

    /// Cells drawn by the lazy grids; `scrollTo` only reaches those (not observed: no redraws).
    @State private var realizedCells = RealizedCells()
    /// Sliding tab background and section underline.
    @Namespace private var namespace

    private static let cellSize: CGFloat = 32
    private static let rowHeight: CGFloat = 28
    private static let slide: Animation = .easeOut(duration: 0.2)

    var body: some View {
        VStack(spacing: 0) {
            if model.sections.isEmpty {
                emptyState
            } else {
                grid
            }
            Divider()
            footer
        }
        .frame(width: 360, height: 288)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Browsing only: a search lists one section per kind, whatever the tab.
                if model.query.isEmpty {
                    navigation(proxy)
                    Divider()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.sections.enumerated()), id: \.element.id) { sectionIndex, section in
                            sectionView(section, sectionIndex: sectionIndex)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onAppear { scrollToSelection(proxy, toTop: true) }
                .onChange(of: model.selection) { _ in scrollToSelection(proxy) }
                // Typing often keeps the selection at (0, 0); still jump back to the first result.
                .onChange(of: model.query) { _ in scrollToSelection(proxy, toTop: true) }
                // Same for a tab switch (the selection may stay at (0, 0)).
                .onChange(of: model.tab) { _ in scrollToSelection(proxy, toTop: true) }
                // Reopening keeps the selection at (0, 0) too; scroll back to the top on every reset.
                .onChange(of: model.resetCount) { _ in scrollToSelection(proxy, toTop: true) }
            }
        }
    }

    /// Header + its own grid (no grid spacing, the 32 pt cells space themselves). The id is the
    /// section's, so `scrollTo` reaches it even before the lazy stack has drawn it.
    private func sectionView(_ section: PickerSection, sectionIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .padding(.bottom, 2)
            // Flexible, not fixed: a legacy scroller takes ~15 pt of the width.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: section.columns),
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(Array(section.emojis.enumerated()), id: \.element.id) { index, emoji in
                    cell(emoji, section: section, sectionIndex: sectionIndex, index: index)
                }
            }
        }
        .id(section.id)
    }

    private func cell(_ emoji: Emoji, section: PickerSection, sectionIndex: Int, index: Int) -> some View {
        let isSelected = model.selection == PickerSelection(section: sectionIndex, index: index)
        let id = Self.cellID(section, emoji)
        return cellLabel(emoji)
            .frame(maxWidth: .infinity, minHeight: Self.cellSize, maxHeight: Self.cellSize)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.25))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.select(emoji, in: sectionIndex)
                model.confirm()
            }
            .onAppear { realizedCells.ids.insert(id) }
            .onDisappear { realizedCells.ids.remove(id) }
            .id(id)
    }

    /// Emoji keep their colors; symbols are text glyphs.
    @ViewBuilder
    private func cellLabel(_ emoji: Emoji) -> some View {
        switch emoji.kind {
        case nil:
            Text(emoji.toned(skinTone))
                .font(.system(size: 21))
        case .symbol:
            Text(emoji.emoji)
                .font(.system(size: 19))
                .foregroundStyle(.primary)
        }
    }

    // MARK: Navigation

    /// Tabs above one icon button per section of the current tab. Two rows: the tabs and up
    /// to 10 icons don't fit in 360 pt. Padded on every side so the Dividers above and below
    /// never touch the controls.
    private func navigation(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 4) {
            tabs
            sectionButtons(proxy)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 4)
    }

    /// Segmented control: equal segments on a rounded track, the selected background slides.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(PickerTab.allCases, id: \.self) { tab in
                TabSegment(title: tab.title, isSelected: tab == model.tab, namespace: namespace) {
                    model.tab = tab
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
        .animation(Self.slide, value: model.tab)
    }

    /// Each button selects the first cell of its section and scrolls its header to the top;
    /// an underline slides under the section holding the selection. Ids are positions, not the
    /// tab-prefixed section ids: the buttons survive a tab switch, so the underline slides too.
    private func sectionButtons(_ proxy: ScrollViewProxy) -> some View {
        let selectedSection = model.selection?.section
        return HStack(spacing: 4) {
            ForEach(Array(model.sections.enumerated()), id: \.offset) { sectionIndex, section in
                Button {
                    model.jump(to: sectionIndex)
                    // Also when its first cell was already selected (no selection change then).
                    proxy.scrollTo(section.id, anchor: .top)
                } label: {
                    sectionIcon(section.title)
                }
                .buttonStyle(SectionIconButtonStyle(isSelected: sectionIndex == selectedSection))
                .overlay(alignment: .bottom) {
                    if sectionIndex == selectedSection {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: 16, height: 2)
                            .matchedGeometryEffect(id: "underline", in: namespace)
                    }
                }
                .hoverTooltip(section.title)
            }
        }
        .animation(Self.slide, value: selectedSection)
    }

    /// The SF Symbol of `title`, else its first letter.
    @ViewBuilder
    private func sectionIcon(_ title: String) -> some View {
        if let symbol = Self.sectionSymbols[title] {
            Image(systemName: symbol)
        } else {
            Text(title.prefix(1))
                .font(.caption.weight(.semibold))
        }
    }

    /// Keyed by section title: emoji and symbol categories, plus "Frequently Used".
    private static let sectionSymbols: [String: String] = [
        "Frequently Used": "clock",
        // Emoji
        "Smileys & Emotion": "face.smiling",
        "People & Body": "person",
        "Animals & Nature": "pawprint",
        "Food & Drink": "fork.knife",
        "Travel & Places": "car",
        "Activities": "soccerball",
        "Objects": "lightbulb",
        "Symbols": "heart",
        "Flags": "flag",
        // Symbols
        "Keyboard": "command",
        "Arrows": "arrow.right",
        "Currency": "dollarsign.circle",
        "Math": "plus.forwardslash.minus",
        "Typography": "textformat",
        "Checkboxes": "checkmark.square",
    ]

    // MARK: Empty state, footer, scrolling

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
            Text("No emoji found")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        Text(model.selectedEmoji.map { Self.capitalizedFirst($0.description) } ?? "No results")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
    }

    /// `scrollTo` can't reach a cell the lazy grids haven't drawn (far away): scroll its section
    /// header to the top first (sections are always reachable), then the cell on the next run loop
    /// turn. `toTop` always does that (first result, tab switch, reopen).
    private func scrollToSelection(_ proxy: ScrollViewProxy, toTop: Bool = false) {
        guard let selection = model.selection else { return }
        let section = model.sections[selection.section]
        let cellID = Self.cellID(section, section.emojis[selection.index])
        if !toTop, realizedCells.ids.contains(cellID) {
            proxy.scrollTo(cellID, anchor: nil)
            return
        }
        proxy.scrollTo(section.id, anchor: .top)
        DispatchQueue.main.async { proxy.scrollTo(cellID, anchor: nil) }
    }

    /// Uppercases only the first letter so acronyms ("OK hand", "ZZZ") are kept.
    private static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Unique across sections (an emoji can be both "Frequently Used" and in its category).
    private static func cellID(_ section: PickerSection, _ emoji: Emoji) -> String {
        "\(section.id)-\(emoji.emoji)"
    }
}

// MARK: - Reset without animation

extension EmojiPickerModel {
    /// `reset()` for a reopen: no underline or tab background sliding in while the panel
    /// appears. `disablesAnimations` also stops the `.animation(_:value:)` modifiers, which
    /// `Transaction(animation: nil)` doesn't.
    func resetWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { reset() }
    }
}

/// One tab of the segmented control: hover tints the segment, the selected one carries the
/// sliding background.
private struct TabSegment: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected || isHovered ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "tab", in: namespace)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// Plain section icon: secondary at rest, primary when hovered or holding the selection.
private struct SectionIconButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SectionIcon(configuration: configuration, isSelected: isSelected)
    }

    private struct SectionIcon: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.callout)
                .foregroundStyle(isSelected || isHovered ? .primary : .secondary)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

/// Ids of the cells the lazy grids have drawn. A plain class: updating it never redraws the grid.
private final class RealizedCells {
    var ids: Set<String> = []
}

// MARK: - Keyboard

extension View {
    /// Arrows move the selection, Return/Enter confirms, Esc calls `onCancel`.
    /// Only key events sent to `window` (the hosting window) are handled; every other window
    /// is untouched.
    func emojiPickerKeyMonitor(
        _ model: EmojiPickerModel,
        window: EmojiPickerWindowBox,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(EmojiPickerKeyMonitor(model: model, window: window, onCancel: onCancel))
    }
}

private struct EmojiPickerKeyMonitor: ViewModifier {
    let model: EmojiPickerModel
    let window: EmojiPickerWindowBox
    let onCancel: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: install)
            .onDisappear(perform: uninstall)
    }

    private func install() {
        uninstall()
        let model = model
        let box = window
        let onCancel = onCancel
        // Local monitors are called on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handle(event, host: box.window, model: model, onCancel: onCancel) ? nil : event
        }
    }

    private func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Returns true when the key was handled (and must be swallowed).
    private static func handle(
        _ event: NSEvent,
        host: NSWindow?,
        model: EmojiPickerModel,
        onCancel: () -> Void
    ) -> Bool {
        guard let host, event.window === host else { return false }
        // Shortcuts (cmd+A, shift+arrows, ...) keep their text-field meaning.
        // Not "flags are empty": arrow keys always carry .numericPad and .function.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.shift, .option, .command, .control]) else { return false }
        // IME composition (e.g. Vietnamese Telex) owns Return/arrows/Esc until it commits.
        if let editor = host.firstResponder as? NSTextView, editor.hasMarkedText() { return false }

        switch event.keyCode {
        case 123: model.move(.left)
        case 124: model.move(.right)
        case 125: model.move(.down)
        case 126: model.move(.up)
        case 36, 76: model.confirm()
        case 53: onCancel()
        default: return false
        }
        return true
    }
}
