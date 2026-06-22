// IconPickerView.swift
// PopGuy — UI/SettingsWindow/Components
//
// Reusable icon picker for choosing a custom action icon.
// Supports SF Symbols (from a curated list with search) and emoji quick-picks.
//
// Isolation: @MainActor throughout (implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor).

import AppKit
import SwiftUI

// MARK: - IconPickerMode

private enum IconPickerMode: String, CaseIterable {
    case sfSymbol = "SF Symbol"
    case emoji    = "Emoji"
}

// MARK: - IconPickerView

/// A two-tab icon picker: SF Symbol grid (with search) and emoji grid + input.
///
/// Initializes the tab from the current `selection`:
/// `.emoji` → Emoji tab; `.sfSymbol` → SF Symbol tab.
struct IconPickerView: View {

    @Binding var selection: ActionIcon

    @State private var mode: IconPickerMode
    @State private var symbolSearch: String = ""
    @FocusState private var emojiFieldFocused: Bool

    // MARK: - Curated symbol list

    nonisolated static let curatedSymbols: [String] = [
        // Writing / text
        "sparkles",
        "wand.and.stars",
        "wand.and.rays",
        "pencil",
        "pencil.line",
        "pencil.and.outline",
        "square.and.pencil",
        "highlighter",
        "textformat",
        "textformat.abc",
        "textformat.size",
        "textformat.alt",
        "character",
        "character.cursor.ibeam",
        "abc",
        "text.bubble",
        "character.bubble",
        "quote.bubble",
        "quote.opening",
        "quote.closing",
        "text.quote",
        "captions.bubble",
        "bubble.left",
        "bubble.right",
        "bubble.left.and.bubble.right",
        "text.alignleft",
        "text.aligncenter",
        "text.alignright",
        "text.justify",
        "text.append",
        "text.insert",
        "text.badge.plus",
        "text.badge.checkmark",
        // Organisation
        "list.bullet",
        "list.number",
        "list.dash",
        "list.bullet.indent",
        "checklist",
        "checkmark",
        "checkmark.circle",
        "checkmark.seal",
        "tag",
        "tag.fill",
        "bookmark",
        "bookmark.fill",
        "flag",
        "flag.fill",
        "tray",
        "tray.full",
        "folder",
        "folder.fill",
        "archivebox",
        "square.grid.2x2",
        "rectangle.grid.1x2",
        // Navigation / actions
        "arrow.right",
        "arrow.left",
        "arrow.up",
        "arrow.down",
        "arrow.uturn.left",
        "arrow.uturn.right",
        "arrow.triangle.2.circlepath",
        "arrow.clockwise",
        "arrow.up.arrow.down",
        "arrow.left.arrow.right",
        "arrow.right.circle",
        "arrowshape.turn.up.right",
        "chevron.right",
        "chevron.up.chevron.down",
        "magnifyingglass",
        "magnifyingglass.circle",
        "link",
        "paperclip",
        "command",
        "option",
        "return",
        // Documents
        "doc",
        "doc.on.doc",
        "doc.text",
        "doc.text.magnifyingglass",
        "doc.append",
        "doc.richtext",
        "doc.plaintext",
        "clipboard",
        "list.clipboard",
        "note.text",
        "newspaper",
        "book",
        "book.closed",
        "text.book.closed",
        // Coding / technical
        "terminal",
        "chevron.left.forwardslash.chevron.right",
        "curlybraces",
        "curlybraces.square",
        "function",
        "number",
        "numbersign",
        "percent",
        "plus.forwardslash.minus",
        "x.squareroot",
        "sum",
        "chevron.left.slash.chevron.right",
        "cpu",
        "memorychip",
        "externaldrive",
        "server.rack",
        "network",
        "ladybug",
        "hammer",
        "wrench.and.screwdriver",
        "gearshape",
        "gearshape.2",
        "slider.horizontal.3",
        // Communication
        "envelope",
        "envelope.open",
        "paperplane",
        "paperplane.fill",
        "message",
        "message.fill",
        "phone",
        "bell",
        "bell.fill",
        "megaphone",
        "at",
        "person",
        "person.2",
        "person.crop.circle",
        "globe.americas",
        "globe.europe.africa",
        // Knowledge / learning
        "lightbulb",
        "lightbulb.fill",
        "brain",
        "brain.head.profile",
        "graduationcap",
        "books.vertical",
        "character.book.closed",
        "studentdesk",
        "questionmark.circle",
        "exclamationmark.circle",
        "info.circle",
        "eye",
        "eyeglasses",
        // Time / calendar
        "calendar",
        "calendar.badge.clock",
        "clock",
        "clock.arrow.circlepath",
        "alarm",
        "timer",
        "hourglass",
        "stopwatch",
        // Creative / misc
        "paintbrush",
        "paintbrush.pointed",
        "paintpalette",
        "scissors",
        "star",
        "star.fill",
        "heart",
        "heart.fill",
        "bolt",
        "bolt.fill",
        "flame",
        "flame.fill",
        "leaf",
        "leaf.fill",
        "drop",
        "sparkle",
        "globe",
        "hand.thumbsup",
        "hand.thumbsup.fill",
        "hand.raised",
        "face.smiling",
        "gift",
        "crown",
        "trophy",
        "rosette",
        "wand.and.stars.inverse",
        "scope",
        "target",
        "scalemass",
        "gauge",
        "speedometer",
        "lock",
        "lock.open",
        "key",
        "shield",
        "trash",
        "pin",
        "mappin",
        "location",
        "camera",
        "photo",
        "mic",
        "speaker.wave.2",
        "music.note",
        "play",
        "waveform",
        "character.book.closed.fill",
        "text.magnifyingglass",
    ]

    // MARK: - Curated emoji list

    private static let curatedEmoji: [String] = [
        "✨", "🔧", "🌍", "📝", "✅", "❤️", "⭐️", "🔥",
        "💡", "📋", "🔍", "🎯", "🚀", "📌", "🏷️", "🔗",
        "✉️", "💬", "🧠", "🎓", "📚", "🔤", "🔢", "⚡️",
        "🎨", "✂️", "👍", "😊", "🌟", "📖",
    ]

    // MARK: - Init

    init(selection: Binding<ActionIcon>) {
        _selection = selection
        let initialMode: IconPickerMode
        if case .emoji = selection.wrappedValue {
            initialMode = .emoji
        } else {
            initialMode = .sfSymbol
        }
        _mode = State(initialValue: initialMode)
    }

    // MARK: - Body

    var body: some View {
        // No outer padding — the host (a SettingsCard) supplies it.
        VStack(spacing: 12) {
            modePicker
            Divider()
            switch mode {
            case .sfSymbol:
                sfSymbolContent
            case .emoji:
                emojiContent
            }
        }
    }

    // MARK: - Mode segmented picker

    private var modePicker: some View {
        Picker("Icon Type", selection: $mode) {
            ForEach(IconPickerMode.allCases, id: \.self) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - SF Symbol tab

    private var sfSymbolContent: some View {
        VStack(spacing: 8) {
            TextField("Search", text: $symbolSearch)
                .textFieldStyle(.roundedBorder)

            let filtered = filteredSymbols
            if filtered.isEmpty {
                Text("No results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                symbolGrid(symbols: filtered)
            }
        }
    }

    private var filteredSymbols: [String] {
        guard !symbolSearch.isEmpty else { return Self.curatedSymbols }
        let query = symbolSearch.lowercased()
        return Self.curatedSymbols.filter { $0.lowercased().contains(query) }
    }

    private func symbolGrid(symbols: [String]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 6)], spacing: 6) {
                ForEach(symbols, id: \.self) { name in
                    symbolCell(name: name)
                }
            }
            .padding(4)
        }
        .frame(minHeight: 120, maxHeight: 220)
    }

    private func symbolCell(name: String) -> some View {
        let isSelected = selection == .sfSymbol(name)
        return Image(systemName: name)
            .font(.system(size: 18))
            .frame(width: 36, height: 36)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { selection = .sfSymbol(name) }
    }

    // MARK: - Emoji tab

    private var emojiContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Computed binding: get the emoji string from selection; set on change.
            let emojiBinding = Binding<String>(
                get: {
                    if case .emoji(let e) = selection { return e }
                    return ""
                },
                set: { newValue in
                    if let last = newValue.last {
                        selection = .emoji(String(last))
                    } else {
                        selection = .default
                    }
                }
            )

            HStack {
                Text("Custom")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("Type or paste emoji", text: emojiBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    .focused($emojiFieldFocused)

                // Open macOS's full emoji & symbols picker. It inserts the chosen
                // character into the current first responder, so focus the field
                // first; the binding then keeps only the last character.
                Button {
                    emojiFieldFocused = true
                    Task { @MainActor in
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    Label("More…", systemImage: "face.smiling")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            Text("Quick pick")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 6)], spacing: 6) {
                    ForEach(Self.curatedEmoji, id: \.self) { emoji in
                        emojiCell(emoji: emoji)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 100, maxHeight: 200)
        }
    }

    private func emojiCell(emoji: String) -> some View {
        let isSelected = selection == .emoji(emoji)
        return Text(emoji)
            .font(.system(size: 20))
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { selection = .emoji(emoji) }
    }
}

// MARK: - ActionIconView

/// Renders an `ActionIcon` as a SwiftUI view.
/// SF Symbol → `Image(systemName:)`; emoji → `Text`.
/// UI-layer only — do NOT use this in model/engine code.
struct ActionIconView: View {
    let icon: ActionIcon
    var font: Font = .body

    var body: some View {
        switch icon {
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(font)
        case .emoji(let character):
            Text(character)
                .font(font)
        }
    }
}
