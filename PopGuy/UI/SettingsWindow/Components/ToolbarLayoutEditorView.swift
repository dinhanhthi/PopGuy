// ToolbarLayoutEditorView.swift
// PopGuy — UI/SettingsWindow/Components
//
// Interactive drag-and-drop editor for the toolbar layout (Settings → Actions).
//
// Row 1 renders the REAL floating toolbar (`ToolbarView`, non-interactive) from an
// editor-owned view model, so metrics, zoom, labels, burger, and system buttons
// match the live toolbar exactly. Row 2 is an editor-owned "More actions" card of
// icon chips. Both rows are draggable: reorder on the toolbar, reorder within
// More, and move actions between the two. There are no action-count caps; a soft
// warning appears when the toolbar card grows wider than
// `ToolbarLimits.toolbarWidthWarningThreshold`.
//
// One container-level drag gesture resolves the dragged action from the frames the
// toolbar reports (`ToolbarActionFramesKey`) and the More chip frames, and previews
// the drop by rewriting the preview view model's order (never from `body`).
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
// `ToolbarLayoutEditMath` is nonisolated pure math.

import AppKit
import Combine
import SwiftUI

// MARK: - Drag math

/// Pure index math for the layout editor's drag preview.
nonisolated enum ToolbarLayoutEditMath {

    /// Insertion index of `dragging` among the other items of a row, using
    /// neighbour-swap with hysteresis: the index steps right only once the pointer
    /// passes the midX of the next neighbour, and left only once it passes the midX
    /// of the previous one. Robust to uneven widths (labeled vs icon-only controls).
    ///
    /// - Parameters:
    ///   - current: the dragged item's current index among the others. Pass 0 when
    ///     the item is entering a row it is not displayed in yet.
    ///   - orderedIDs: the row's displayed order (may include `dragging`).
    ///   - frames: the displayed frames; a missing neighbour frame stops stepping.
    static func insertionIndex(
        pointerX: CGFloat,
        current: Int,
        orderedIDs: [ActionIdentifier],
        frames: [ActionIdentifier: CGRect],
        dragging: ActionIdentifier
    ) -> Int {
        let others = orderedIDs.filter { $0 != dragging }
        var index = min(max(0, current), others.count)
        while index < others.count, let next = frames[others[index]], pointerX > next.midX {
            index += 1
        }
        while index > 0, let previous = frames[others[index - 1]], pointerX < previous.midX {
            index -= 1
        }
        return index
    }

    /// `ids` with `dragging` moved (or inserted) at `index`, clamped.
    static func previewOrder(
        _ ids: [ActionIdentifier],
        dragging: ActionIdentifier,
        at index: Int
    ) -> [ActionIdentifier] {
        var result = ids.filter { $0 != dragging }
        result.insert(dragging, at: min(max(0, index), result.count))
        return result
    }
}

// MARK: - Drag session

private struct ToolbarDragSession: Equatable {
    var id: ActionIdentifier
    var sourcePrincipal: Bool
    var sourceIndex: Int
    var targetPrincipal: Bool
    var targetIndex: Int
    var location: CGPoint
}

// MARK: - Frame preferences

private struct MoreChipFramesKey: PreferenceKey {
    static let defaultValue: [ActionIdentifier: CGRect] = [:]
    static func reduce(value: inout [ActionIdentifier: CGRect], nextValue: () -> [ActionIdentifier: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - ToolbarLayoutEditorView

struct ToolbarLayoutEditorView: View {
    @ObservedObject var settings: SettingsStore

    /// Drives the embedded real toolbar. Seeded from settings, and rewritten by the
    /// drag gesture to preview the drop; mutated only from event handlers.
    @StateObject private var previewModel = ToolbarViewModel()

    @State private var dragSession: ToolbarDragSession?
    /// True while the drag gesture is active. Unlike `onEnded`, a `@GestureState`
    /// also resets when SwiftUI cancels the gesture, so it catches stale sessions.
    @GestureState private var isDragActive = false
    @State private var toolbarFrames: [ActionIdentifier: CGRect] = [:]
    @State private var moreFrames: [ActionIdentifier: CGRect] = [:]
    @State private var moreRowFrame: CGRect = .zero
    @State private var cardWidth: CGFloat = 0
    @State private var canvasHeight: CGFloat = 0

    private let dragAnimation = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.86)

    /// Pointer slack (pt) above the More card that still counts as the More zone.
    private let moreZoneSlack: CGFloat = 8

    // Same scaled metrics as the real toolbar (ToolbarView's ToolbarMetrics).
    private var zoom: CGFloat { previewModel.toolbarZoom.scale }
    private var controlHeight: CGFloat { 26 * zoom }
    private var cardRadius: CGFloat { 10 * zoom }
    private var cardPadding: CGFloat { 4 * zoom }
    private var controlRadius: CGFloat { cardRadius - cardPadding }
    private var chipIconSize: CGFloat { NSFont.preferredFont(forTextStyle: .callout).pointSize * zoom }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                canvas
            }
            .frame(height: canvasHeight > 0 ? canvasHeight : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ToolbarPreviewBackdrop())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if cardWidth > ToolbarLimits.toolbarWidthWarningThreshold {
                widthWarning
            }
        }
        .onAppear(perform: reseed)
        // objectWillChange fires before the new value is stored, so reseed on the
        // next main-actor turn. Skipped while dragging (the gesture owns the
        // preview order then); the drag's end reseeds explicitly.
        .onReceive(settings.objectWillChange) { _ in
            DispatchQueue.main.async {
                guard dragSession == nil else { return }
                reseed()
            }
        }
    }

    // MARK: Canvas

    /// Both rows plus hover targets and the drag ghost, in one named coordinate
    /// space shared by every frame reader and the drag gesture.
    private var canvas: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbarRow
            moreRow
                // Align with the toolbar card (ToolbarView's root horizontal padding).
                .padding(.leading, 12 * zoom)
                // Room for the card shadow.
                .padding(.bottom, 16)
        }
        .padding(.top, 8)
        .overlay(alignment: .topLeading) { toolbarHoverTargets }
        .overlay(alignment: .topLeading) { dragGhost }
        .coordinateSpace(name: ToolbarView.previewCoordinateSpace)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onChange(of: isDragActive) { active in
            guard !active else { return }
            // A cancelled drag skips `onEnded` and leaves a stale session. Defer to
            // the next main-actor turn so a normal `onEnded` in the same update
            // always commits the move first; then the nil-check makes this a no-op.
            DispatchQueue.main.async {
                guard !isDragActive, dragSession != nil else { return }
                dragSession = nil
                reseed()
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { canvasHeight = geo.size.height }
                    .onChange(of: geo.size.height) { canvasHeight = $0 }
            }
        )
    }

    // MARK: Row 1 — the real toolbar

    private var toolbarRow: some View {
        ToolbarView(
            viewModel: previewModel,
            outputHandler: OutputHandler(),
            onContentResize: { _ in },
            onOpenSettings: {},
            onIgnoreApp: {},
            onIgnoreDomain: {},
            onDismiss: {},
            onDisableCloseConfirmation: {},
            onActivatePromptInput: {}
        )
        .allowsHitTesting(false)
        .onPreferenceChange(ToolbarActionFramesKey.self) { toolbarFrames = $0 }
        // Card width = the toolbar's size minus its root horizontal padding (12pt
        // per side, zoomed). Measured here with GeometryReader + onAppear/onChange:
        // ToolbarView's own onContentResize (its internal size preference) was
        // found not to fire when embedded like this.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardWidth = max(0, geo.size.width - 24 * zoom) }
                    .onChange(of: geo.size.width) { cardWidth = max(0, $0 - 24 * zoom) }
            }
        )
    }

    /// Transparent hover targets over each toolbar action: the real toolbar has
    /// hit-testing disabled, which also disables its own tooltips. They carry no
    /// gesture, so drags starting on them reach the container gesture.
    private var toolbarHoverTargets: some View {
        ZStack(alignment: .topLeading) {
            ForEach(previewModel.orderedActions, id: \.self) { id in
                if let frame = toolbarFrames[id] {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .hoverTooltip(chipLabel(for: id))
                        .padding(.leading, frame.minX)
                        .padding(.top, frame.minY)
                }
            }
        }
    }

    // MARK: Row 2 — More actions

    private var moreRow: some View {
        VStack(alignment: .leading, spacing: cardPadding) {
            HStack(spacing: 3 * zoom) {
                Text("More actions")
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .font(.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize * zoom))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5 * zoom)
            .padding(.top, 2 * zoom)

            HStack(spacing: cardPadding) {
                if previewModel.overflowActions.isEmpty {
                    emptyMoreSlot
                } else {
                    ForEach(previewModel.overflowActions, id: \.self) { id in
                        moreChip(for: id)
                    }
                }
            }
        }
        .padding(cardPadding)
        .background(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .onPreferenceChange(MoreChipFramesKey.self) { moreFrames = $0 }
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named(ToolbarView.previewCoordinateSpace))
                Color.clear
                    .onAppear { moreRowFrame = frame }
                    .onChange(of: frame) { moreRowFrame = $0 }
            }
        )
    }

    private func moreChip(for id: ActionIdentifier) -> some View {
        chipIcon(for: id)
            .font(.system(size: chipIconSize))
            .frame(width: controlHeight, height: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: MoreChipFramesKey.self,
                        value: [id: geo.frame(in: .named(ToolbarView.previewCoordinateSpace))]
                    )
                }
            )
            .hoverTooltip(chipLabel(for: id))
    }

    private var emptyMoreSlot: some View {
        RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
            .strokeBorder(
                Color.secondary.opacity(0.5),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .frame(width: controlHeight * 2, height: controlHeight)
    }

    // MARK: Ghost and warning

    @ViewBuilder
    private var dragGhost: some View {
        if let session = dragSession {
            chipIcon(for: session.id)
                .font(.system(size: chipIconSize))
                .frame(width: controlHeight, height: controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                .position(session.location)
                .allowsHitTesting(false)
        }
    }

    private var widthWarning: some View {
        Label {
            Text("Your toolbar is getting wide and may cover more of your work. Consider moving some actions to More actions or turning off labels.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Seeding

    private func reseed() {
        ToolbarPreviewView.seed(
            previewModel,
            from: settings,
            principal: settings.principalOrderedIdentifiers,
            overflow: settings.overflowOrderedIdentifiers
        )
    }

    // MARK: Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(ToolbarView.previewCoordinateSpace))
            .updating($isDragActive) { _, state, _ in state = true }
            .onChanged(dragChanged)
            .onEnded(dragEnded)
    }

    private func dragChanged(_ value: DragGesture.Value) {
        if dragSession == nil {
            // A drag that doesn't start on an action is ignored.
            guard let session = beginSession(at: value.startLocation, location: value.location) else { return }
            dragSession = session
        }
        guard var session = dragSession else { return }

        let targetPrincipal = !isInMoreZone(value.location)
        let sameZone = targetPrincipal == session.targetPrincipal
        let targetIndex = ToolbarLayoutEditMath.insertionIndex(
            pointerX: value.location.x,
            current: sameZone ? session.targetIndex : 0,
            orderedIDs: targetPrincipal ? previewModel.orderedActions : previewModel.overflowActions,
            frames: targetPrincipal ? toolbarFrames : moreFrames,
            dragging: session.id
        )
        let slotChanged = !sameZone || targetIndex != session.targetIndex

        session.targetPrincipal = targetPrincipal
        session.targetIndex = targetIndex
        session.location = value.location
        dragSession = session

        if slotChanged {
            withAnimation(dragAnimation) {
                applyPreview(of: session)
            }
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        guard dragSession != nil else { return }
        dragChanged(value)
        guard let session = dragSession else { return }

        let unchanged = session.targetPrincipal == session.sourcePrincipal
            && session.targetIndex == session.sourceIndex
        if !unchanged {
            settings.moveAction(session.id, toZone: session.targetPrincipal, atIndex: session.targetIndex)
        }
        dragSession = nil
        reseed()
    }

    private func beginSession(at start: CGPoint, location: CGPoint) -> ToolbarDragSession? {
        let rows: [(principal: Bool, ids: [ActionIdentifier], frames: [ActionIdentifier: CGRect])] = [
            (true, previewModel.orderedActions, toolbarFrames),
            (false, previewModel.overflowActions, moreFrames)
        ]
        for row in rows {
            if let index = row.ids.firstIndex(where: { row.frames[$0]?.contains(start) == true }) {
                return ToolbarDragSession(
                    id: row.ids[index],
                    sourcePrincipal: row.principal,
                    sourceIndex: index,
                    targetPrincipal: row.principal,
                    targetIndex: index,
                    location: location
                )
            }
        }
        return nil
    }

    /// The More card spans only its chips' width, so the zone is the whole band at
    /// or below its top edge (minus a little slack), not just the card's rect —
    /// dragging straight down from any toolbar action reaches More.
    private func isInMoreZone(_ location: CGPoint) -> Bool {
        moreRowFrame != .zero && location.y >= moreRowFrame.minY - moreZoneSlack
    }

    /// Shows the dragged action at its target slot in the preview.
    private func applyPreview(of session: ToolbarDragSession) {
        var principal = previewModel.orderedActions.filter { $0 != session.id }
        var overflow = previewModel.overflowActions.filter { $0 != session.id }
        if session.targetPrincipal {
            principal = ToolbarLayoutEditMath.previewOrder(principal, dragging: session.id, at: session.targetIndex)
        } else {
            overflow = ToolbarLayoutEditMath.previewOrder(overflow, dragging: session.id, at: session.targetIndex)
        }
        if previewModel.orderedActions != principal { previewModel.orderedActions = principal }
        if previewModel.overflowActions != overflow { previewModel.overflowActions = overflow }
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
