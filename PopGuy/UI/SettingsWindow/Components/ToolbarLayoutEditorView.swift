// ToolbarLayoutEditorView.swift
// PopGuy — UI/SettingsWindow/Components
//
// Interactive drag-and-drop editor for the principal toolbar row.
// Overflow (More menu) chips are read-only; use the Toolbar checkbox on
// action cards to move items in or out of More.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import SwiftUI

// MARK: - Drag session

private struct ToolbarDragSession: Equatable {
    var id: ActionIdentifier
    var targetPrincipal: Bool
    var targetIndex: Int
    var translation: CGSize = .zero
}

// MARK: - Frame preferences

private struct LayoutRowFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct LayoutChipFramesKey: PreferenceKey {
    static var defaultValue: [ActionIdentifier: CGRect] = [:]
    static func reduce(value: inout [ActionIdentifier: CGRect], nextValue: () -> [ActionIdentifier: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - ToolbarLayoutEditorView

struct ToolbarLayoutEditorView: View {
    @ObservedObject var settings: SettingsStore

    @State private var dragSession: ToolbarDragSession?
    @State private var rejectionMessage: String?

    @State private var principalRowFrame: CGRect = .zero
    @State private var overflowRowFrame: CGRect = .zero
    @State private var burgerFrame: CGRect = .zero
    @State private var principalChipFrames: [ActionIdentifier: CGRect] = [:]

    private let chipSize: CGFloat = 28
    private let chipIconSize: CGFloat = 12
    private let logoSize: CGFloat = 26
    private let chipSpacing: CGFloat = 5
    private let dragAnimation = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.86)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image("ToolbarLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .accessibilityHidden(true)

                principalChipStrip

                if showsOverflowSection {
                    burgerDivider
                    burgerMarker
                    overflowChipStrip
                }

                Spacer(minLength: 8)
            }

            if let rejectionMessage {
                Text(rejectionMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.12))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .coordinateSpace(name: "layoutEditor")
    }

    // MARK: Zones

    private var showsOverflowSection: Bool {
        !settings.overflowOrderedIdentifiers.isEmpty
            || dragSession?.targetPrincipal == false
    }

    private var displayPrincipalIDs: [ActionIdentifier] {
        guard let session = dragSession else {
            return settings.principalOrderedIdentifiers
        }
        if session.targetPrincipal {
            return Self.previewOrder(
                settings.principalOrderedIdentifiers,
                dragging: session.id,
                at: session.targetIndex
            )
        }
        return settings.principalOrderedIdentifiers.filter { $0 != session.id }
    }

    private var displayOverflowIDs: [ActionIdentifier] {
        let actual = settings.overflowOrderedIdentifiers
        guard let session = dragSession, !session.targetPrincipal else { return actual }
        var preview = actual.filter { $0 != session.id }
        if !preview.contains(session.id) {
            preview.append(session.id)
        }
        return preview
    }

    private static func previewOrder(
        _ ids: [ActionIdentifier],
        dragging: ActionIdentifier,
        at index: Int
    ) -> [ActionIdentifier] {
        var result = ids.filter { $0 != dragging }
        let clamped = min(max(0, index), result.count)
        result.insert(dragging, at: clamped)
        return result
    }

    // MARK: Principal strip

    private var principalChipStrip: some View {
        HStack(spacing: chipSpacing) {
            if displayPrincipalIDs.isEmpty, dragSession == nil {
                emptyPrincipalSlot
            } else {
                ForEach(displayPrincipalIDs, id: \.self) { id in
                    draggableChip(for: id, isDragged: dragSession?.id == id)
                        .background(chipFrameReader(for: id))
                }
            }
        }
        .animation(dragAnimation, value: displayPrincipalIDs)
        .background(rowFrameReader())
        .onPreferenceChange(LayoutRowFrameKey.self) { principalRowFrame = $0 }
        .onPreferenceChange(LayoutChipFramesKey.self) { principalChipFrames = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: Overflow strip (read-only)

    private var overflowChipStrip: some View {
        HStack(spacing: chipSpacing) {
            ForEach(displayOverflowIDs, id: \.self) { id in
                staticChip(for: id)
            }
        }
        .animation(dragAnimation, value: displayOverflowIDs)
        .background(rowFrameReader())
        .onPreferenceChange(LayoutRowFrameKey.self) { overflowRowFrame = $0 }
    }

    private var burgerDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: chipSize - 4)
    }

    private var burgerMarker: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: chipIconSize, weight: .medium))
            .frame(width: chipSize, height: chipSize)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(dragSession?.targetPrincipal == false ? 0.18 : 0.10))
            )
            .hoverTooltip("More menu")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: LayoutRowFrameKey.self,
                        value: geo.frame(in: .named("layoutEditor"))
                    )
                }
            )
            .onPreferenceChange(LayoutRowFrameKey.self) { burgerFrame = $0 }
    }

    private var emptyPrincipalSlot: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: chipSize, height: chipSize)
    }

    private func rowFrameReader() -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: LayoutRowFrameKey.self,
                value: geo.frame(in: .named("layoutEditor"))
            )
        }
    }

    private func chipFrameReader(for id: ActionIdentifier) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: LayoutChipFramesKey.self,
                value: [id: geo.frame(in: .named("layoutEditor"))]
            )
        }
    }

    // MARK: Chips

    @ViewBuilder
    private func draggableChip(for id: ActionIdentifier, isDragged: Bool) -> some View {
        chipContent(for: id)
            .scaleEffect(isDragged ? 1.06 : 1)
            .shadow(color: .black.opacity(isDragged ? 0.35 : 0), radius: isDragged ? 6 : 0, y: 2)
            .offset(isDragged ? (dragSession?.translation ?? .zero) : .zero)
            .zIndex(isDragged ? 1 : 0)
            .background(chipBackground(isDragged: isDragged))
            .hoverTooltip(chipLabel(for: id))
            .contentShape(Rectangle())
            .gesture(principalDragGesture(for: id))
    }

    @ViewBuilder
    private func staticChip(for id: ActionIdentifier) -> some View {
        chipContent(for: id)
            .background(chipBackground(isDragged: false))
            .hoverTooltip(chipLabel(for: id))
    }

    @ViewBuilder
    private func chipContent(for id: ActionIdentifier) -> some View {
        chipIcon(for: id)
            .font(.system(size: chipIconSize, weight: .medium))
            .frame(width: chipSize, height: chipSize)
    }

    private func chipBackground(isDragged: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(isDragged ? 0.22 : 0.12))
    }

    private func principalDragGesture(for id: ActionIdentifier) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("layoutEditor"))
            .onChanged { value in
                if dragSession == nil {
                    let startIndex = settings.principalOrderedIdentifiers.firstIndex(of: id) ?? 0
                    dragSession = ToolbarDragSession(
                        id: id,
                        targetPrincipal: true,
                        targetIndex: startIndex,
                        translation: value.translation
                    )
                }
                updateDragSession(value)
            }
            .onEnded { value in
                updateDragSession(value)
                commitDragSession()
            }
    }

    // MARK: Drag logic

    private func updateDragSession(_ value: DragGesture.Value) {
        guard var session = dragSession else { return }

        let location = value.location
        let targetPrincipal = resolveTargetPrincipal(at: location, session: session)
        let targetIndex: Int
        if targetPrincipal {
            targetIndex = insertionIndex(
                at: location.x,
                orderedIDs: displayPrincipalIDs,
                frames: principalChipFrames,
                dragging: session.id
            )
        } else {
            targetIndex = settings.overflowOrderedIdentifiers.count
        }

        let changed = session.targetPrincipal != targetPrincipal
            || session.targetIndex != targetIndex
            || session.translation != value.translation

        session.targetPrincipal = targetPrincipal
        session.targetIndex = targetIndex
        session.translation = value.translation

        if changed, session.targetPrincipal != targetPrincipal || session.targetIndex != targetIndex {
            withAnimation(dragAnimation) {
                dragSession = session
            }
        } else {
            dragSession = session
        }
    }

    private func resolveTargetPrincipal(at location: CGPoint, session: ToolbarDragSession) -> Bool {
        // More zone (burger + overflow chips) takes priority over the principal row.
        if showsOverflowSection, burgerFrame.width > 0, location.x >= burgerFrame.minX - 6 {
            return false
        }
        if overflowRowFrame.contains(location) || burgerFrame.contains(location) {
            return false
        }
        if principalRowFrame.contains(location) {
            return true
        }
        return session.targetPrincipal
    }

    private func insertionIndex(
        at pointerX: CGFloat,
        orderedIDs: [ActionIdentifier],
        frames: [ActionIdentifier: CGRect],
        dragging: ActionIdentifier
    ) -> Int {
        let order = orderedIDs.filter { $0 != dragging }
        guard !order.isEmpty else { return 0 }

        for (offset, id) in order.enumerated() {
            guard let frame = frames[id] else { continue }
            if pointerX < frame.midX { return offset }
        }
        return order.count
    }

    private func commitDragSession() {
        guard let session = dragSession else { return }

        let wasPrincipal = settings.isPrincipal(session.id)
        let sourceIndex = settings.principalOrderedIdentifiers.firstIndex(of: session.id) ?? 0
        let unchanged = session.targetPrincipal == wasPrincipal
            && (session.targetPrincipal ? session.targetIndex == sourceIndex : true)

        defer { dragSession = nil }

        guard !unchanged else { return }

        if settings.moveAction(session.id, toZone: session.targetPrincipal, atIndex: session.targetIndex) {
            rejectionMessage = nil
            return
        }

        rejectionMessage = session.targetPrincipal
            ? "Toolbar row is full (\(ProConfig.maxPrincipalActions)/\(ProConfig.maxPrincipalActions)). Free a slot first."
            : "More menu is full (\(ProConfig.maxBurgerActions)/\(ProConfig.maxBurgerActions)). Free a slot first."

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if rejectionMessage != nil { rejectionMessage = nil }
        }
    }

    // MARK: Action metadata

    private func chipLabel(for id: ActionIdentifier) -> String {
        switch id {
        case .builtin(.improve):   return "Improve"
        case .builtin(.shorten):   return "Shorten"
        case .builtin(.proofread): return "Proofread"
        case .builtin(.prompt):    return "Prompt"
        case .builtin(.translate): return "Translate"
        case .speak:               return "Speak"
        case .dictionary:          return "Look up"
        case .custom(let uuid):
            return settings.customActions.first(where: { $0.id == uuid })?.title ?? "Custom"
        }
    }

    @ViewBuilder
    private func chipIcon(for id: ActionIdentifier) -> some View {
        switch id {
        case .builtin(.improve):
            Image(systemName: "wand.and.stars")
        case .builtin(.shorten):
            Image(systemName: "text.badge.minus")
        case .builtin(.proofread):
            Image(systemName: "checkmark.bubble")
        case .builtin(.prompt):
            Image(systemName: "bubble.and.pencil")
        case .builtin(.translate):
            Image(systemName: "character.bubble")
        case .speak:
            Image(systemName: "speaker.wave.2")
        case .dictionary:
            Image(systemName: "character.book.closed")
        case .custom(let uuid):
            if let action = settings.customActions.first(where: { $0.id == uuid }) {
                ActionIconView(icon: action.icon, font: .system(size: chipIconSize))
            } else {
                Image(systemName: "sparkles")
            }
        }
    }
}
