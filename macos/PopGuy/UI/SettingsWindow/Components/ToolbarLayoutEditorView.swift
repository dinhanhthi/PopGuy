// ToolbarLayoutEditorView.swift
// PopGuy — UI/SettingsWindow/Components
//
// Interactive drag-and-drop editor for the toolbar layout (Settings → Actions).
//
// It renders the REAL floating toolbar (`ToolbarView`, non-interactive) from an
// editor-owned view model, so metrics, zoom, labels, burger, and system buttons
// match the live toolbar exactly, and an editor-owned More card of icon chips
// beside it, top-aligned — wrapped to a second row only when both don't fit the
// preview's width. A "More actions" connector joins the two cards behind them: a
// straight line with the label in its middle side by side; wrapped, an elbow from
// the toolbar card's bottom into the More card's right edge, the label on its run. Both are draggable: reorder on the toolbar, reorder within
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

    /// Whether the More card fits on the toolbar's row: toolbar, gap and card
    /// together are no wider than `available`.
    static func moreFitsBesideToolbar(
        toolbarWidth: CGFloat,
        moreWidth: CGFloat,
        spacing: CGFloat,
        available: CGFloat
    ) -> Bool {
        toolbarWidth + spacing + moreWidth <= available
    }

    /// Whether a drag at `location` targets the More card. The card spans only its
    /// chips, so the zone is a whole band: side by side, everything right of the
    /// card's left edge; wrapped, everything at or below its top edge — so dragging
    /// straight down from any toolbar action reaches More. `slack` widens the zone
    /// toward the toolbar.
    static func isInMoreZone(location: CGPoint, moreFrame: CGRect, sideBySide: Bool, slack: CGFloat) -> Bool {
        sideBySide
            ? location.x >= moreFrame.minX - slack
            : location.y >= moreFrame.minY - slack
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
    /// The layout when the drag began, kept for the whole drag: the preview
    /// changes both widths, which must not flip the layout under the pointer.
    var sideBySide: Bool
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
    /// The toolbar row's frame (ToolbarView with its transparent insets).
    @State private var toolbarRowFrame: CGRect = .zero
    @State private var canvasHeight: CGFloat = 0
    /// Visible width of the preview (the horizontal ScrollView's own width).
    @State private var availableWidth: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    // Same scaled metrics as the real toolbar (ToolbarView's ToolbarMetrics).
    private var zoom: CGFloat { previewModel.toolbarZoom.scale }
    private var controlHeight: CGFloat { 26 * zoom }
    private var cardRadius: CGFloat { 10 * zoom }
    private var cardPadding: CGFloat { 4 * zoom }
    private var controlRadius: CGFloat { cardRadius - cardPadding }
    private var chipIconSize: CGFloat { NSFont.preferredFont(forTextStyle: .callout).pointSize * zoom }
    /// ToolbarView's transparent side inset around its card.
    private var toolbarInset: CGFloat { ToolbarView.outerHorizontalPadding * zoom }

    // Connector metrics. The label is measured with AppKit, not from layout, so
    // the fit decision below never waits on a layout pass.
    private static let connectorTitle = "More actions"
    private var connectorFontSize: CGFloat { NSFont.preferredFont(forTextStyle: .caption1).pointSize * zoom }
    private var connectorLabelSize: CGSize {
        let size = (Self.connectorTitle as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: connectorFontSize)])
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
    /// Visible line on each side of the label.
    private var connectorStub: CGFloat { 12 * zoom }
    /// Space between the line and the label.
    private var connectorLabelPad: CGFloat { 6 * zoom }
    /// The run that carries the label (stub, pad, label, pad, stub): the gap
    /// between the cards side by side.
    private var connectorRun: CGFloat { connectorLabelSize.width + 2 * (connectorStub + connectorLabelPad) }
    /// The gap between the rows when wrapped: the label sits beside the More
    /// card, so the gap is the preview's own side space.
    private var wrappedGap: CGFloat { toolbarInset }
    /// Wrapped, whether the toolbar card ends too soon for the elbow to drop from
    /// its bottom edge (More card plus run wider than it): the elbow then leaves
    /// from its right edge, right of both cards, which needs room on the right.
    private var wrappedElbowPastToolbar: Bool {
        moreRowFrame.maxX + connectorRun > toolbarCardFrame.maxX - cardRadius
    }
    private var connectorColor: Color { .white.opacity(0.8) }

    /// The toolbar card inside the toolbar row (less ToolbarView's insets).
    private var toolbarCardFrame: CGRect {
        CGRect(
            x: toolbarRowFrame.minX + toolbarInset,
            y: toolbarRowFrame.minY + ToolbarView.outerTopPadding * zoom,
            width: toolbarRowFrame.width - 2 * toolbarInset,
            height: toolbarRowFrame.height - (ToolbarView.outerTopPadding + ToolbarView.outerBottomPadding) * zoom
        )
    }

    /// Whether the More card sits beside the toolbar (latched during a drag).
    private var sideBySide: Bool { dragSession?.sideBySide ?? measuredSideBySide }

    /// Fit decision from measurements that do not depend on the layout (the
    /// toolbar is fixed-size, the More card hugs its chips, the available width
    /// is measured outside the ScrollView), so it cannot feed back on itself.
    /// Wrapped until everything is measured.
    private var measuredSideBySide: Bool {
        #if DEBUG
        if Self.forceWrap { return false }
        #endif
        guard availableWidth > 0, cardWidth > 0, moreRowFrame.width > 0 else { return false }
        return ToolbarLayoutEditMath.moreFitsBesideToolbar(
            toolbarWidth: toolbarInset + cardWidth,
            moreWidth: moreRowFrame.width + toolbarInset, // room for the card's shadow
            spacing: connectorRun,
            available: availableWidth
        )
    }

    #if DEBUG
    /// DEBUG-only QA hook: `--preview-force-wrap` keeps More on its own row.
    private static let forceWrap = ProcessInfo.processInfo.arguments.contains("--preview-force-wrap")
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                canvas
            }
            .frame(height: canvasHeight > 0 ? canvasHeight : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { availableWidth = geo.size.width }
                        .onChange(of: geo.size.width) { availableWidth = $0 }
                }
            )
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

    /// Toolbar and More card plus hover targets and the drag ghost, in one named
    /// coordinate space shared by every frame reader and the drag gesture.
    /// `AnyLayout` switches side by side / wrapped while keeping view identity,
    /// so frames, hover targets and the drag gesture survive the switch.
    private var canvas: some View {
        let layout = sideBySide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        return layout {
            toolbarRow
            moreRow
                // Side by side: level with the toolbar card (below ToolbarView's
                // top inset), the connector's run as the gap (ToolbarView's
                // trailing inset is part of it), room for the shadow on the right.
                // Wrapped: aligned with the toolbar card, `wrappedGap` below it
                // (into ToolbarView's bottom shadow inset), room on the right for
                // the elbow when it passes the toolbar card.
                .padding(.top, sideBySide
                         ? ToolbarView.outerTopPadding * zoom
                         : wrappedGap - ToolbarView.outerBottomPadding * zoom)
                .padding(.leading, sideBySide ? connectorRun - toolbarInset : toolbarInset)
                .padding(.trailing, sideBySide
                         ? toolbarInset
                         : (wrappedElbowPastToolbar ? connectorRun + toolbarInset : 0))
                // The same space below the card as left of the toolbar card.
                .padding(.bottom, toolbarInset)
        }
        // The same space on every side of the cards: ToolbarView's side inset
        // (`toolbarInset`). Its top inset is smaller, its bottom inset larger
        // (shadow room): side by side the toolbar row is the tallest, so trim
        // the difference below; wrapped, the More row is last and already ends
        // `toolbarInset` below its card.
        .padding(.bottom, sideBySide
                 ? -(ToolbarView.outerBottomPadding - ToolbarView.outerHorizontalPadding) * zoom
                 : 0)
        .padding(.top, (ToolbarView.outerHorizontalPadding - ToolbarView.outerTopPadding) * zoom)
        .background(alignment: .topLeading) { connector }
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
        // Card width = the toolbar's size minus its root horizontal padding
        // (`toolbarInset` per side). Measured here with GeometryReader + onAppear/onChange:
        // ToolbarView's own onContentResize (its internal size preference) was
        // found not to fire when embedded like this.
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named(ToolbarView.previewCoordinateSpace))
                Color.clear
                    .onAppear {
                        cardWidth = max(0, geo.size.width - 2 * toolbarInset)
                        toolbarRowFrame = frame
                    }
                    .onChange(of: geo.size.width) { cardWidth = max(0, $0 - 2 * toolbarInset) }
                    .onChange(of: frame) { toolbarRowFrame = $0 }
            }
        )
    }

    // MARK: Connector

    /// The "More actions" line between the toolbar card and the More card, drawn
    /// behind both. Side by side: straight, from the toolbar card's right edge to
    /// the More card's left edge. Wrapped: an elbow from the toolbar card's bottom
    /// down to the More card's middle, then left into its right edge. The label
    /// sits in a break of the last run (no fill behind it, so the backdrop shows
    /// through).
    @ViewBuilder
    private var connector: some View {
        if toolbarRowFrame != .zero, moreRowFrame != .zero {
            let (points, labelCenter) = connectorGeometry(toolbar: toolbarCardFrame, more: moreRowFrame)
            let half = connectorLabelSize.width / 2 + connectorLabelPad
            ZStack(alignment: .topLeading) {
                Path { path in
                    // The line, broken around the label on the run that carries it.
                    let breakIndex = points.count - 2
                    let direction: CGFloat = points[breakIndex + 1].x >= points[breakIndex].x ? 1 : -1
                    let before = CGPoint(x: labelCenter.x - direction * half, y: labelCenter.y)
                    let after = CGPoint(x: labelCenter.x + direction * half, y: labelCenter.y)
                    addPolyline(Array(points[...breakIndex]) + [before], to: &path)
                    addPolyline([after] + Array(points[(breakIndex + 1)...]), to: &path)
                }
                .stroke(connectorColor, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

                Text(Self.connectorTitle)
                    .font(.system(size: connectorFontSize))
                    .foregroundStyle(connectorColor)
                    .fixedSize()
                    .position(labelCenter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The connector's corner points and the label's center, in the canvas space.
    private func connectorGeometry(toolbar: CGRect, more: CGRect) -> ([CGPoint], CGPoint) {
        if sideBySide {
            // Level with the toolbar card's middle, kept within the More card.
            let y = min(max(toolbar.midY, more.minY + controlRadius), more.maxY - controlRadius)
            return ([CGPoint(x: toolbar.maxX, y: y), CGPoint(x: more.minX, y: y)],
                    CGPoint(x: (toolbar.maxX + more.minX) / 2, y: y))
        }
        // Wrapped: the run ends at the More card's right edge, level with its
        // middle, and starts `connectorRun` to the right, where the line drops
        // from the toolbar card's bottom; or, when the toolbar card ends before
        // that, from its right edge (room reserved on the right).
        let y = more.midY
        let end = CGPoint(x: more.maxX, y: y)
        if wrappedElbowPastToolbar {
            // Clear of the toolbar card's right edge by at least a stub.
            let x = max(more.maxX + connectorRun, toolbar.maxX + connectorStub)
            return ([CGPoint(x: toolbar.maxX, y: toolbar.midY), CGPoint(x: x, y: toolbar.midY),
                     CGPoint(x: x, y: y), end],
                    CGPoint(x: (more.maxX + x) / 2, y: y))
        }
        let x = more.maxX + connectorRun
        return ([CGPoint(x: x, y: toolbar.maxY), CGPoint(x: x, y: y), end],
                CGPoint(x: (more.maxX + x) / 2, y: y))
    }

    /// Adds a line through `points` with rounded corners.
    private func addPolyline(_ points: [CGPoint], to path: inout Path) {
        guard let first = points.first else { return }
        path.move(to: first)
        for index in points.indices.dropFirst().dropLast() {
            path.addArc(tangent1End: points[index], tangent2End: points[index + 1], radius: 4 * zoom)
        }
        if let last = points.last { path.addLine(to: last) }
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
        // Titled by the connector's "More actions" label, not inside the card.
        HStack(spacing: cardPadding) {
            if previewModel.overflowActions.isEmpty {
                emptyMoreSlot
            } else {
                ForEach(previewModel.overflowActions, id: \.self) { id in
                    moreChip(for: id)
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
            // The other actions slide to open the drop slot; they jump there under Reduce Motion.
            withAnimation(reduceMotion ? nil : Motion.drag) {
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
                    location: location,
                    sideBySide: measuredSideBySide
                )
            }
        }
        return nil
    }

    /// See `ToolbarLayoutEditMath.isInMoreZone`; uses the layout on screen.
    private func isInMoreZone(_ location: CGPoint) -> Bool {
        moreRowFrame != .zero && ToolbarLayoutEditMath.isInMoreZone(
            location: location,
            moreFrame: moreRowFrame,
            sideBySide: sideBySide,
            // Up to the middle of the gap (the connector's run or the row gap).
            slack: sideBySide ? connectorRun / 2 : wrappedGap / 2
        )
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
