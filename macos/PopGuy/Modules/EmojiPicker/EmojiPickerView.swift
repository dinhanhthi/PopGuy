// EmojiPickerView.swift
// PopGuy — EmojiPicker
//
// Content of the emoji picker panel (ported from FastMoji's hotkey picker): a search
// header with a Settings gear above the emoji grid. Keys go through a local key monitor
// (see `EmojiGridView.swift`), not view focus.
//
// Isolation: MainActor (SwiftUI).

import AppKit
import SwiftUI

struct EmojiPickerView: View {
    @ObservedObject var model: EmojiPickerModel
    @ObservedObject var settings: SettingsStore
    let onCancel: () -> Void
    let onOpenSettings: () -> Void

    @State private var window = EmojiPickerWindowBox()
    @FocusState private var searchFocused: Bool

    private static let cornerRadius: CGFloat = 12
    private static let headerHeight: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .frame(height: Self.headerHeight)
                // Tooltips hang below the header: draw them over the grid.
                .zIndex(1)
            Divider()
            EmojiGridView(model: model, skinTone: settings.emojiSkinTone)
        }
        .background(EmojiPickerWindowAccessor(box: window))
        // The vibrant background is an `NSVisualEffectView` (see `EmojiPickerPanel`).
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            // Return/Esc/arrows are handled by the key monitor (no .onSubmit, it would double-fire).
            TextField("Search emoji", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(EmojiPickerHoverCapsuleButtonStyle(isCircle: true))
            .hoverTooltip("Settings")
        }
        .emojiPickerKeyMonitor(model, window: window, onCancel: onCancel)
        // The panel is not key yet when onAppear runs; focus lands on the next runloop.
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
        // Every open (the hosting view is reused, onAppear may not run again).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let host = window.window, (note.object as? NSWindow) === host else { return }
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}

// MARK: - Hosting window

/// Weak reference to the window hosting the picker (read later from callbacks and the key monitor).
final class EmojiPickerWindowBox {
    weak var window: NSWindow?
}

struct EmojiPickerWindowAccessor: NSViewRepresentable {
    let box: EmojiPickerWindowBox

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        var box: EmojiPickerWindowBox?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { box?.window = window }
        }
    }
}

// MARK: - Button style

/// Capsule with hover and pressed feedback (`.bordered` has no hover state).
struct EmojiPickerHoverCapsuleButtonStyle: ButtonStyle {
    /// Icon-only buttons: a fixed square, which the capsule turns into a circle.
    var isCircle = false

    func makeBody(configuration: Configuration) -> some View {
        HoverCapsule(configuration: configuration, isCircle: isCircle)
    }

    private struct HoverCapsule: View {
        let configuration: ButtonStyleConfiguration
        let isCircle: Bool
        @State private var isHovered = false

        private static let circleSize: CGFloat = 26

        var body: some View {
            let fill = configuration.isPressed ? 0.24 : isHovered ? 0.16 : 0.07
            configuration.label
                .font(.callout)
                .padding(.horizontal, isCircle ? 0 : 11)
                .padding(.vertical, isCircle ? 0 : 4)
                .frame(width: isCircle ? Self.circleSize : nil, height: isCircle ? Self.circleSize : nil)
                .background(Capsule().fill(Color.primary.opacity(fill)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(isHovered ? 0.22 : 0.1), lineWidth: 1))
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}
