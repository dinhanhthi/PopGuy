// HoverTooltip.swift
// PopGuy — UI/SettingsWindow/Components
//
// Fast custom hover tooltip for Settings controls, mirroring the floating
// toolbar's tooltip (regularMaterial pill, ~120 ms delay) instead of the
// system `.help()` tooltip, which has a non-configurable ~1–2 s delay.
//
// Usage:
//   Button { … } label: { … }
//       .hoverTooltip("Export custom actions")
//
// When `text` is empty the modifier is a no-op.
//
// Tooltips intentionally use a floating panel instead of an in-layout overlay.
// The Settings window has a fixed sidebar next to a scrollable detail pane,
// and overlays inside the detail pane can be covered by those sibling views.
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import SwiftUI

private struct HoverTooltipModifier: ViewModifier {
    let text: String

    /// Delay before the tooltip becomes visible (~120 ms feels instant but avoids
    /// flicker when the cursor just passes through).
    private static let delay: UInt64 = 120_000_000 // nanoseconds

    @State private var isHovered = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var anchorView: NSView?
    @State private var clickMonitor: Any?

    @ViewBuilder
    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        installClickMonitor()
                        hoverTask?.cancel()
                        hoverTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: Self.delay)
                            guard !Task.isCancelled else { return }
                            if isHovered, let anchorView {
                                HoverTooltipPanelPresenter.shared.show(text: text, anchor: anchorView)
                            }
                        }
                    } else {
                        teardown()
                    }
                }
                .background {
                    HoverTooltipAnchorView { anchorView = $0 }
                }
                .onDisappear {
                    teardown()
                }
        }
    }

    /// Hide the tooltip on any mouse-down (e.g. clicking the button to open its
    /// dropdown). The monitor returns the event unmodified so the button/menu
    /// action is unaffected. While the pointer stays over the control no new
    /// `onHover` fires, so the tooltip stays hidden until the pointer re-enters.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            hoverTask?.cancel()
            hoverTask = nil
            HoverTooltipPanelPresenter.shared.hide(anchor: anchorView)
            return event
        }
    }

    private func teardown() {
        hoverTask?.cancel()
        hoverTask = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        HoverTooltipPanelPresenter.shared.hide(anchor: anchorView)
    }
}

private struct HoverTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            )
    }
}

private struct HoverTooltipAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView) }
    }
}

@MainActor
private final class HoverTooltipPanelPresenter {
    static let shared = HoverTooltipPanelPresenter()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<HoverTooltipBubble>?
    private weak var owner: NSView?

    private init() {}

    func show(text: String, anchor: NSView) {
        guard let parentWindow = anchor.window else { return }

        let panel = panel ?? makePanel()
        let hostingController = NSHostingController(rootView: HoverTooltipBubble(text: text))
        hostingController.view.frame = NSRect(origin: .zero, size: hostingController.view.fittingSize)

        self.panel = panel
        self.hostingController = hostingController
        owner = anchor

        panel.contentView = hostingController.view
        panel.setContentSize(hostingController.view.fittingSize)
        position(panel, near: anchor)

        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFrontRegardless()
    }

    func hide(anchor: NSView?) {
        guard anchor == nil || owner === anchor else { return }
        owner = nil
        if let panel {
            panel.orderOut(nil)
            panel.parent?.removeChildWindow(panel)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }

    private func position(_ panel: NSPanel, near anchor: NSView) {
        guard let parentWindow = anchor.window else { return }

        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorOnScreen = parentWindow.convertToScreen(anchorInWindow)
        let tooltipSize = panel.frame.size
        var origin = NSPoint(
            x: anchorOnScreen.maxX - tooltipSize.width,
            y: anchorOnScreen.minY - 28
        )

        if let visibleFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX + 4), visibleFrame.maxX - tooltipSize.width - 4)
            origin.y = min(max(origin.y, visibleFrame.minY + 4), visibleFrame.maxY - tooltipSize.height - 4)
        }

        panel.setFrameOrigin(origin)
    }
}

extension View {
    /// Attaches a fast custom hover tooltip, matching the floating toolbar's style.
    func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}
