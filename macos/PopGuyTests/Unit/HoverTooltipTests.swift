// HoverTooltipTests.swift
// PopGuyTests
//
// Regression coverage for Settings hover tooltips. The shared modifier must
// keep the same material-pill tooltip style as the floating toolbar while
// presenting outside the normal layout tree so sidebar and ScrollView siblings
// cannot cover or clip the tooltip surface.

import AppKit
import Foundation
import Testing
@testable import PopGuy

@Suite("HoverTooltip")
struct HoverTooltipTests {

    @Test("settings hover tooltips use the toolbar-style floating pill")
    func settingsHoverTooltipsUseToolbarStyleFloatingPill() throws {
        let sourceURL = try repositoryRoot()
            .appendingPathComponent("PopGuy/UI/SettingsWindow/Components/HoverTooltip.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        guard
            let start = source.range(of: "private struct HoverTooltipModifier")?.lowerBound,
            let end = source.range(of: "extension View")?.lowerBound
        else {
            Issue.record("Could not locate HoverTooltipModifier in \(sourceURL.path)")
            return
        }

        let modifierSource = String(source[start..<end])

        #expect(
            source.contains("NSPanel"),
            "Expected hoverTooltip to present in a floating panel above the Settings sidebar."
        )
        #expect(
            !modifierSource.contains(".popover(isPresented:"),
            "Expected hoverTooltip not to use a native popover because that changes tooltip UX."
        )
        #expect(
            !modifierSource.contains(".overlay(alignment:"),
            "Expected hoverTooltip not to use an in-layout overlay that can be covered by the sidebar."
        )
        #expect(
            source.contains(".fill(.regularMaterial)"),
            "Expected hoverTooltip to keep the same regularMaterial pill style as the toolbar."
        )
        #expect(
            source.contains(".padding(.horizontal, 8)") && source.contains(".padding(.vertical, 4)"),
            "Expected hoverTooltip to keep the same compact padding as the toolbar tooltip."
        )
    }

    /// A tooltip whose hover timer fires after its window was hidden (e.g. the
    /// toolbar closed by an action's "Close toolbar") must not order that window
    /// back in: AppKit shows a hidden parent when its child panel orders front.
    @Test("a tooltip never re-shows its hidden window")
    @MainActor
    func tooltipNeverReshowsHiddenWindow() {
        let window = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        window.orderOut(nil)
        defer { HoverTooltipPanelPresenter.shared.hide(anchor: nil) }

        HoverTooltipPanelPresenter.shared.show(text: "YouTube", anchor: anchor)

        #expect(!window.isVisible, "Expected the hidden window to stay hidden when its tooltip fires late.")
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("PopGuy.xcodeproj").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw HoverTooltipTestError.repositoryRootNotFound
    }
}

private enum HoverTooltipTestError: Error {
    case repositoryRootNotFound
}
