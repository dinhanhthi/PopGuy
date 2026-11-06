// SlideOverPanel.swift
// PopGuy — UI/SettingsWindow/Components
//
// Reusable slide-over panel component for the Settings window.
//
// Encapsulates the backdrop + trailing-edge slide-in pattern used by the
// Add/Edit Action panel, the Action Library gallery, and the Local AI memory
// info panel.
//
// API:
//   SlideOverPanel(
//       isPresented: $someFlag,
//       containerWidth: containerWidth,
//       minWidth: 560,       // optional floor (default 560)
//       onDismiss: { … }     // called when backdrop or Esc dismisses
//   ) {
//       PanelContent()
//   }
//
// Place inside the parent's ZStack(alignment: .trailing). A dimming scrim
// (`Palette.scrim`, a solid wash: the window keeps its single glass) covers
// zIndex 1; the panel, a solid `Palette.surface`, sits at zIndex 2. Both
// animate with `Motion.sheet`, none under Reduce Motion.
//
// The backdrop click and Esc dismiss with that animation here. Callers must
// wrap their own open/close calls (e.g. a Done button in the panel body) in
// `withAnimation(reduceMotion ? nil : Motion.sheet)` too, so every path slides
// the same way.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - SlideOverPanel

/// A trailing-edge slide-over panel with a dimmed tap-to-dismiss backdrop.
///
/// Renders as two layers inside the parent ZStack:
///   1. A backdrop (zIndex 1) — `Palette.scrim`, tap to dismiss.
///   2. The panel (zIndex 2) — 2/3 of `containerWidth` (floored at `minWidth`),
///      full-height, `Palette.surface`, drop shadow, transitions with
///      `.move(edge: .trailing)`.
///
/// Use inside the same `ZStack(alignment: .trailing)` that holds all Settings
/// slide-over panels so z-ordering stays consistent.
struct SlideOverPanel<Content: View>: View {

    let isPresented: Bool
    /// Live window width — the panel sizes itself to `widthFraction` of this value.
    let containerWidth: CGFloat
    /// Fraction of `containerWidth` to use for the panel. Defaults to 2/3.
    var widthFraction: CGFloat = 2.0 / 3.0
    /// Minimum panel width (floor). Defaults to 560.
    var minWidth: CGFloat = 560
    /// Called when the user taps the backdrop or presses Esc.
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The slide, the same as the callers' `Motion.sheet`; none under Reduce Motion.
    private var animation: Animation? { reduceMotion ? nil : Motion.sheet }

    var panelWidth: CGFloat {
        max(containerWidth * widthFraction, minWidth)
    }

    var body: some View {
        // Backdrop
        if isPresented {
            Rectangle()
                .fill(Palette.scrim)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture {
                    withAnimation(animation) { onDismiss() }
                }
                .zIndex(1)
        }

        // Panel
        if isPresented {
            content()
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .background(Palette.surface.ignoresSafeArea())
                .shadow(color: Palette.cardShadow, radius: 12, x: -3, y: 0)
                .transition(.move(edge: .trailing))
                .zIndex(2)
                .onExitCommand {
                    withAnimation(animation) { onDismiss() }
                }
        }
    }
}
