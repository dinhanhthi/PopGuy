// FloatingPanel.swift
// PopGuy
//
// A borderless, non-activating floating NSPanel that hosts the toolbar SwiftUI view.
//
// Design:
//   - .nonactivatingPanel: panel becomes key without activating PopGuy, so the
//     source application stays frontmost (no focus steal).
//   - canBecomeKey = true: necessary for the local Escape key monitor and the
//     Picker dropdown inside the SwiftUI view to work correctly.
//   - level = .floating (NSWindow.Level.floating): appears above normal windows
//     but below Spotlight / menus. Joined to all Spaces + fullscreen apps.
//   - Transparent background / isOpaque=false: let SwiftUI provide the visual.
//   - hidesOnDeactivate = false: prevent the panel from disappearing when the
//     user clicks in the source app (we manage dismiss ourselves in ToolbarController).

import AppKit

/// Borderless floating panel that hosts the PopGuy toolbar.
///
/// Isolation: @MainActor — NSPanel is main-thread-only.
@MainActor
final class FloatingPanel: NSPanel {

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        // Force the correct style mask regardless of what the caller passes.
        let panelStyle: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        super.init(contentRect: contentRect, styleMask: panelStyle, backing: .buffered, defer: false)
        configure()
    }

    // MARK: - Configuration

    private func configure() {
        // Appearance
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear

        // Floating above normal windows; below system UI (Spotlight, menus).
        level = .floating

        // Do NOT hide when another window activates — we control dismiss manually.
        hidesOnDeactivate = false

        // Show on all Spaces and fullscreen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The SwiftUI content draws its own rounded card + shadow. A second
        // NSPanel shadow would trace the panel's rectangular frame around the
        // rounded card (the "ugly border"), so disable the window shadow.
        hasShadow = false

        // Let the user drag the panel by its background. The SwiftUI material
        // fills the panel, so the draggable surface is the padding around the
        // buttons/text (buttons consume their own clicks). See `userHasMoved`.
        isMovableByWindowBackground = true
    }

    // MARK: - User-move tracking

    /// True once the user has manually dragged the panel. While set, the
    /// controller stops auto-positioning the panel near the selection and only
    /// nudges it back on-screen if a content resize would push it off-edge.
    private(set) var userHasMoved = false

    /// Programmatic moves (auto-positioning) must not set `userHasMoved`.
    /// Route them through this flag so the `setFrameOrigin` override can tell
    /// a user drag apart from a controller-driven move.
    private var isProgrammaticMove = false

    /// Move the panel without marking it as user-moved.
    func setFrameOriginProgrammatically(_ origin: NSPoint) {
        isProgrammaticMove = true
        setFrameOrigin(origin)
        isProgrammaticMove = false
    }

    /// AppKit routes window-background drags through `setFrameOrigin`. Any move
    /// not flagged as programmatic is therefore a user drag.
    override func setFrameOrigin(_ point: NSPoint) {
        if !isProgrammaticMove {
            userHasMoved = true
        }
        super.setFrameOrigin(point)
    }

    /// Reset move tracking when the panel is dismissed so the next selection
    /// starts fresh with auto-positioning.
    func resetMoveTracking() {
        userHasMoved = false
    }

    // MARK: - Key/Main status

    /// Allow the panel to become key (needed for Picker, local Esc monitor, button focus).
    /// Because the panel is .nonactivatingPanel it becomes key without activating PopGuy.
    override var canBecomeKey: Bool { true }

    /// Panels do not normally become main. Keep default.
    override var canBecomeMain: Bool { false }
}
