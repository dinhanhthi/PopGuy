// ToolbarPreviewView.swift
// PopGuy — UI/SettingsWindow/Components
//
// A static, pixel-faithful preview of the floating toolbar, driven by SettingsStore.
// Reuses the real ToolbarView so compactActions (icon-only flip at >=4 buttons),
// dividers, pickers, and utility buttons match the live toolbar exactly.
//
// The view model is seeded fresh on every body evaluation — acceptable here
// because .allowsHitTesting(false) means no interactive state is preserved.
//
// Overflow: the bar can exceed the panel width (up to 7 actions + utility buttons).
// A horizontal ScrollView with a GeometryReader-bound minWidth centers when the
// bar fits and scrolls horizontally when it overflows.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import SwiftUI

// MARK: - ToolbarPreviewView

struct ToolbarPreviewView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let viewModel = ToolbarViewModel()

        // Seed a non-nil source so the "Ignore this app" utility button renders enabled.
        // A self-targeting AX element (this process) — the preview is static and never pastes back,
        // but if that ever changed the dummy targets PopGuy itself, not the foreground app.
        viewModel.update(
            text: "Preview",
            sourceElement: SourceElementRef(element: AXUIElementCreateApplication(getpid())),
            screenRect: nil,
            sourceBundleID: "com.popguy.preview"
        )

        // Mirror the toolbar view-model seed block in ToolbarController verbatim.
        viewModel.targetLanguage    = TargetLanguage(bcp47: settings.defaultTargetLanguage)
        viewModel.improveEnabled    = settings.improveEnabled
        viewModel.shortenEnabled    = settings.shortenEnabled
        viewModel.proofreadEnabled  = settings.proofreadEnabled
        viewModel.translateEnabled  = settings.translateEnabled
        viewModel.promptEnabled     = settings.promptEnabled
        viewModel.dictionaryEnabled = settings.dictionaryConfig.isEnabled
        viewModel.customActions     = settings.customActions.filter(\.isEnabled)
        viewModel.resultFontSize    = settings.resultFontSize
        viewModel.toolbarZoom       = settings.toolbarZoom
        viewModel.includeFontInZoom = settings.zoomIncludesFontSize
        viewModel.preserveFormatting = settings.preserveFormatting
        viewModel.speakEnabled      = settings.speakEnabled
        viewModel.speakSettings     = settings.speakSettings
        if case .cloud(let kind) = settings.speakSettings.selectedEngine {
            viewModel.ttsConfig = settings.ttsConfig(for: kind)
        } else {
            viewModel.ttsConfig = .default
        }
        viewModel.orderedActions = settings.enabledOrderedIdentifiers

        // The preview renders the toolbar at its real on-screen size, so the
        // backdrop and optical-centering nudge scale with the configured zoom
        // to keep the larger bar from clipping at 1.2x / 1.3x.
        let scale = settings.toolbarZoom.scale

        return GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                ToolbarView(
                    viewModel: viewModel,
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
                .frame(
                    minWidth: geo.size.width,
                    minHeight: geo.size.height,
                    alignment: .center
                )
                // ToolbarView's own padding is asymmetric (8pt top, 24pt bottom for
                // shadow/tooltip room); centering it leaves the visible bar sitting
                // ~8pt high. Nudge down by half that difference to optically center it.
                .offset(y: 8 * scale)
            }
        }
        .frame(height: 84 * scale)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.12))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
