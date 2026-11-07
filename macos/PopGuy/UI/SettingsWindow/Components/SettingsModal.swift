// SettingsModal.swift
// PopGuy — UI/SettingsWindow/Components
//
// Reusable in-window modal for the Settings window: the Add/Edit Action
// panel, the Action Library gallery and the Local AI memory info panel.
//
// API:
//   SettingsModal(
//       isPresented: someFlag,
//       containerWidth: containerWidth,
//       minWidth: 560,       // optional floor (default 480)
//       dismissOnBackdropTap: false, // optional (default true)
//       onDismiss: { … }     // called when the scrim click or Esc dismisses
//   ) {
//       PanelContent()
//   }
//
// Place inside the Settings root ZStack. A dimming scrim (`Palette.scrim`)
// covers the whole window at zIndex 1 (the caller also blurs the page behind
// it lightly, see `SettingsModalBackdrop.blurRadius`); the card, a raised
// `GlassCard` on solid `Palette.surface`, sits centered in the window at
// zIndex 2. A custom overlay rather than a
// SwiftUI sheet, so it looks the same on every supported macOS version.
//
// Motion: fades in and scales from 0.96 with the caller's `Motion.sheet`,
// leaves with `Motion.exit`; opacity only under Reduce Motion. The scrim click
// and Esc dismiss with `Motion.sheet` here; callers wrap their own open/close
// calls (e.g. a Done button in the panel body) in `withAnimation(Motion.sheet)`.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - SettingsModalBackdrop

/// The page behind an open modal.
enum SettingsModalBackdrop {
    /// The blur of the page behind an open modal (the user asked for it): light, so the
    /// sidebar, cards and header stay faintly recognisable under the scrim. Applied by
    /// the caller to the page content, animated with the scrim.
    static let blurRadius: CGFloat = 2.5
}

// MARK: - SettingsModal

/// A centered in-window modal card with a dimmed scrim (tap to dismiss unless
/// `dismissOnBackdropTap` is false).
///
/// Renders as two layers inside the parent ZStack:
///   1. The scrim (zIndex 1) — `Palette.scrim` over the whole window, tap to dismiss.
///   2. The card (zIndex 2) — `min(window − 80, 760)` wide (floored at
///      `minWidth`), the window's height minus a 40 pt margin above and
///      below (centered in the window), corner radius 20.
struct SettingsModal<Content: View>: View {

    let isPresented: Bool
    /// Live window width — the card sizes itself from this value.
    let containerWidth: CGFloat
    /// Minimum card width (floor), the panel content's own minimum.
    var minWidth: CGFloat = 480
    /// When false, a click on the scrim does nothing (it still blocks the page):
    /// for a modal with unsaved input, closed only by its own buttons or Esc.
    var dismissOnBackdropTap: Bool = true
    /// Called when the user clicks the scrim (see `dismissOnBackdropTap`) or presses Esc.
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Margin between the card and the window's sides.
    private static var sideMargin: CGFloat { 40 }
    /// Margin between the card and the window's top and bottom edges: the card is centered in
    /// the window. 40 pt clears the traffic lights (they end at y ≈ 33), even when the card's
    /// left edge is under them at the window's minimum width.
    private static var verticalMargin: CGFloat { 40 }
    private static var maxWidth: CGFloat { 760 }
    private static var cornerRadius: CGFloat { 20 }

    var cardWidth: CGFloat {
        max(minWidth, min(containerWidth - 2 * Self.sideMargin, Self.maxWidth))
    }

    /// Fade in with the caller's animation and leave faster (`Motion.exit`).
    private var scrimTransition: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit))
    }

    /// Fade + scale from 0.96, centered; opacity only under Reduce Motion.
    private var cardTransition: AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit))
        }
        let fadeScale = AnyTransition.opacity.combined(with: .scale(scale: 0.96))
        return .asymmetric(insertion: fadeScale, removal: fadeScale.animation(Motion.exit))
    }

    private func dismiss() {
        withAnimation(Motion.sheet) { onDismiss() }
    }

    var body: some View {
        // Scrim
        if isPresented {
            Rectangle()
                .fill(Palette.scrim)
                .ignoresSafeArea()
                .onTapGesture {
                    if dismissOnBackdropTap { dismiss() }
                }
                .transition(scrimTransition)
                .zIndex(1)
        }

        // Card
        if isPresented {
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            content()
                .frame(width: cardWidth)
                .frame(maxHeight: .infinity)
                // Clip before the card's background: dividers and scroll views
                // stay inside the rounded corners, the shadow is not cut.
                .clipShape(shape)
                .modifier(GlassCard(cornerRadius: Self.cornerRadius, raised: true))
                .onExitCommand(perform: dismiss)
                // Centered in the window. The layer ignores the safe area (AppKit
                // reports a 66 pt top inset, taller than the 52 pt band) so the
                // margins are measured from the window's edges.
                .padding(.vertical, Self.verticalMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .transition(cardTransition)
                .zIndex(2)
        }
    }
}
