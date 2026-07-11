// OCRCaptureController.swift
// PopGuy
//
// Orchestrates a single screen-text-capture: permission check -> region
// selection -> screenshot -> OCR -> hand the text off via `onText`.

import AppKit

/// Orchestrates one OCR screen-text capture from start to finish.
///
/// Decoupled from FloatingToolbar/ActionEngine on purpose (per the module
/// boundary rule): the recognized text is handed off through the injectable
/// `onText` closure rather than by importing those modules directly.
///
/// Isolation: @MainActor — drives AppKit UI (`RegionSelectionOverlay`, `NSAlert`).
@MainActor
final class OCRCaptureController {

    private let permission: ScreenRecordingPermission
    private var isCapturing = false
    private var activeOverlay: RegionSelectionOverlay?

    /// Called with the recognized text and the mouse-up point (GLOBAL Quartz
    /// coordinates, used as the toolbar anchor) once a capture succeeds.
    var onText: (@MainActor (String, CGPoint) -> Void)?

    init(permission: ScreenRecordingPermission) {
        self.permission = permission
    }

    /// Begin a capture. No-ops if a capture is already in flight.
    func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        Task { @MainActor [weak self] in
            await self?.runCapture()
            self?.isCapturing = false
        }
    }

    private func runCapture() async {
        if !ensurePermission() {
            return
        }

        guard let result = await presentOverlay() else {
            return
        }

        do {
            let image = try await ScreenshotCapturer.captureImage(of: result.rect, on: result.screen)
            let text = try await OCRTextRecognizer.recognizeText(in: image)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                showNoTextFoundAlert()
                return
            }
            onText?(trimmed, result.mouseUpPoint)
        } catch {
            showCaptureFailedAlert()
        }
    }

    /// Re-checks/requests Screen Recording permission. Returns `true` only
    /// once `permission.isGranted` is confirmed; otherwise shows an alert
    /// pointing to System Settings and returns `false`.
    private func ensurePermission() -> Bool {
        permission.refresh()
        if permission.isGranted {
            return true
        }

        permission.request()
        permission.refresh()
        if permission.isGranted {
            return true
        }

        showPermissionAlert()
        return false
    }

    private func presentOverlay() async -> RegionSelectionResult? {
        await withCheckedContinuation { continuation in
            let overlay = RegionSelectionOverlay()
            activeOverlay = overlay
            overlay.present { [weak self] result in
                self?.activeOverlay = nil
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Alerts

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "PopGuy needs Screen Recording permission to capture screen text. If you just granted it, quit and reopen PopGuy for the change to take effect."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permission.openSystemSettings()
        }
    }

    private func showNoTextFoundAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "No Text Found"
        alert.informativeText = "No text found in the selected area."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCaptureFailedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Capture Failed"
        alert.informativeText = "Screen capture failed."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
