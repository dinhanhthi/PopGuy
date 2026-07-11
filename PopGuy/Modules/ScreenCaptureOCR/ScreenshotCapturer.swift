// ScreenshotCapturer.swift
// PopGuy
//
// Captures a region of the screen into a CGImage for OCR.

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Errors thrown while capturing a screen region.
enum ScreenshotError: Error {
    case displayNotFound
    case captureFailed
}

/// Captures a region of the screen into a `CGImage`.
///
/// Holds no state; trivially `Sendable`.
enum ScreenshotCapturer {

    /// Captures the region `rect` on `screen`.
    ///
    /// `rect` must be in GLOBAL Quartz display coordinates: origin top-left,
    /// y increasing downward. This is NOT AppKit/Cocoa's screen coordinate
    /// space (origin bottom-left of the primary display).
    static func captureImage(of rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        guard let displayID = displayID(for: screen) else {
            throw ScreenshotError.displayNotFound
        }

        if #available(macOS 14.0, *) {
            return try await captureWithScreenCaptureKit(rect: rect, displayID: displayID)
        } else {
            return try await captureWithCoreGraphics(rect: rect)
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    // MARK: - macOS 14+ (ScreenCaptureKit)

    @available(macOS 14.0, *)
    private static func captureWithScreenCaptureKit(
        rect: CGRect,
        displayID: CGDirectDisplayID
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = CGDisplayPixelsWide(displayID)
        configuration.height = CGDisplayPixelsHigh(displayID)
        configuration.showsCursor = false

        let fullImage: CGImage
        do {
            fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenshotError.captureFailed
        }

        // `CGDisplayBounds` is in the same global Quartz coordinate space
        // (points, top-left origin) as the `rect` this function receives.
        let displayBoundsGlobal = CGDisplayBounds(displayID)
        let localRect = rect.offsetBy(dx: -displayBoundsGlobal.origin.x, dy: -displayBoundsGlobal.origin.y)

        // Derive the points→pixels scale from the actual captured image
        // rather than trusting NSScreen.backingScaleFactor to be uniform,
        // so the crop stays correct regardless of capture resolution.
        let scaleX = CGFloat(fullImage.width) / displayBoundsGlobal.width
        let scaleY = CGFloat(fullImage.height) / displayBoundsGlobal.height
        let pixelRect = CGRect(
            x: localRect.origin.x * scaleX,
            y: localRect.origin.y * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        ).integral

        guard let cropped = fullImage.cropping(to: pixelRect) else {
            throw ScreenshotError.captureFailed
        }
        return cropped
    }

    // MARK: - macOS 13 fallback (CoreGraphics)

    private static func captureWithCoreGraphics(rect: CGRect) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            // CGWindowListCreateImage is deprecated on macOS 14+; this
            // fallback only runs on macOS 13, where it's the supported API.
            guard let image = CGWindowListCreateImage(
                rect,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
            ) else {
                throw ScreenshotError.captureFailed
            }
            return image
        }.value
    }
}
