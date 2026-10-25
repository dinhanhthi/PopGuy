// BrowserURLReader.swift
// PopGuy — BrowserContext
//
// Reads the URL of the frontmost browser tab via Apple Events (AppleScript).
// Used to suppress the floating toolbar when the active page's host matches
// a domain the user has chosen to ignore.
//
// Design: a stateless namespace enum marked @MainActor because Apple Events
// (NSAppleScript) must be driven from the main thread. ToolbarController
// already runs on the main actor, so call sites incur no extra hops.
//
// Failure contract: every public method returns nil rather than throwing.
// Automation-permission denials, missing front windows, and parse errors all
// collapse to nil — the caller treats nil as "not ignored" and proceeds
// normally without blocking the toolbar.

import AppKit
import Foundation

// MARK: - BrowserURLReader

/// Stateless namespace for browser-tab URL capture and domain normalization.
///
/// All URL reads are performed via Apple Events and require the user to grant
/// Automation permission for each target browser the first time PopGuy runs.
@MainActor
enum BrowserURLReader {

    // MARK: - Supported browsers

    /// Bundle identifiers for Apple Safari variants.
    static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    /// Bundle identifiers for Chromium-family browsers.
    static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// Returns `true` when `bundleID` belongs to a browser whose active-tab URL
    /// can be read via Apple Events.
    static func isSupportedBrowser(bundleID: String) -> Bool {
        safariBundleIDs.contains(bundleID) || chromiumBundleIDs.contains(bundleID)
    }

    // MARK: - Apple Events URL capture

    /// Returns the normalized host of the frontmost tab in the given browser,
    /// or `nil` on any failure (permission denied, no open window, parse error).
    ///
    /// The AppleScript source differs slightly between Safari and Chromium:
    /// Safari exposes `current tab`; Chromium exposes `active tab`.
    /// Both are driven through Apple Events (NSAppleScript).
    ///
    /// **Intentionally synchronous.** The plan requires a single blocking read
    /// right before the toolbar is shown so that the caller always has the host
    /// available, even when the ignore list is currently empty.  The call site
    /// (ToolbarController) is @MainActor, which is the correct thread for Apple
    /// Events, so no extra context switch is needed.  If perceptible lag appears
    /// in testing, the documented follow-up is a per-(pid, window) cache — not a
    /// migration to async.  See docs/plans/2026-06-16-ignored-domains/README.md,
    /// "Apple Events latency on the toolbar critical path".
    static func currentHost(forBundleID bundleID: String) -> String? {
        let script: String
        if safariBundleIDs.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to get URL of current tab of front window"
        } else if chromiumBundleIDs.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to get URL of active tab of front window"
        } else {
            return nil
        }

        guard let appleScript = NSAppleScript(source: script) else { return nil }

        var errorInfo: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&errorInfo)

        guard errorInfo == nil, let urlString = descriptor.stringValue else { return nil }

        return normalizeHost(of: urlString)
    }

    // MARK: - Normalization helpers

    /// Extracts and lowercases the host from a URL string, stripping a single
    /// leading `www.` prefix.
    ///
    /// Returns `nil` for non-web URLs and host-less URLs such as `about:blank`,
    /// `chrome://newtab`, `edge://settings`, or `file:///path`.
    ///
    /// Only `http`/`https` URLs yield a host. Chromium internal pages like
    /// `chrome://newtab` parse to a bogus single-label host (`newtab`); rejecting
    /// them here keeps the "Ignore this site" button from appearing on pages that
    /// are not real websites.
    nonisolated static func normalizeHost(of urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        let normalized = stripTrailingDot(stripWWW(host.lowercased()))
        // Apply the same IDNA/Punycode encoding as normalizeDomain so a live
        // Unicode host (e.g. "münchen.de") matches a stored entry that was
        // encoded on input ("xn--mnchen-3ya.de"). URLComponents.host leaves
        // Unicode unencoded; URL.host performs IDNA on macOS 13+. ASCII hosts
        // and already-encoded hosts pass through unchanged (idempotent).
        return URL(string: "https://" + normalized)?.host ?? normalized
    }

    /// Normalizes a raw domain string entered by the user into a bare,
    /// lowercased host suitable for storage and matching.
    ///
    /// Handles all common paste formats:
    /// - bare host:            `notion.so`        → `notion.so`
    /// - trailing slash:       `notion.so/`        → `notion.so`
    /// - www prefix:           `www.notion.so`     → `notion.so`
    /// - full URL:             `https://notion.so` → `notion.so`
    /// - full URL with path:   `https://www.notion.so/foo/bar` → `notion.so`
    /// - whitespace + caps:    `  Notion.SO/  `    → `notion.so`
    ///
    /// Returns `nil` for empty input, scheme-only strings (`https://`), or
    /// path-only strings (`/`).
    nonisolated static func normalizeDomain(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }

        // Decide which string to feed URLComponents. If the input contains no
        // "://" separator, prepend https:// so the parser treats the first
        // token as a host rather than as a path segment.
        let forParsing = trimmed.contains("://") ? trimmed : "https://" + trimmed

        var host: String?
        if let components = URLComponents(string: forParsing) {
            host = components.host
        }

        // URLComponents returns nil or empty host for inputs like "https://" or
        // a bare scheme. Fall back to splitting on "/" and taking the first
        // non-empty, non-scheme piece.
        if (host ?? "").isEmpty {
            // Strip any scheme prefix (e.g. "https://") then split on "/"
            let withoutScheme: String
            if let range = trimmed.range(of: "://") {
                withoutScheme = String(trimmed[range.upperBound...])
            } else {
                withoutScheme = trimmed
            }
            let segment = withoutScheme.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
            host = segment
        }

        guard let rawHost = host, !rawHost.isEmpty else { return nil }

        let normalized = stripTrailingDot(stripWWW(rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        guard !normalized.isEmpty else { return nil }

        // Reject strings that look like a bare word with no dot (e.g. just
        // "localhost" is intentionally allowed, but "/" or "" are not).
        // A plausible host either contains a "." or is exactly "localhost".
        guard normalized.contains(".") || normalized == "localhost" else { return nil }

        // Apply IDNA/Punycode encoding so that user-typed Unicode domains
        // (e.g. "münchen.de") are stored in the same ASCII-compatible-encoding
        // form that Apple Events returns ("xn--mnchen-3ya.de").  Foundation's
        // URL initializer performs IDNA encoding on macOS 13+, so a round-trip
        // through a dummy URL is the most reliable way to obtain the encoded
        // host without pulling in a third-party library.  ASCII-only domains
        // pass through unchanged.
        let idnaHost = URL(string: "https://" + normalized)?.host ?? normalized

        return idnaHost
    }

    /// Returns `true` when `host` is equal to `domain` or is a subdomain of
    /// `domain`.
    ///
    /// Both arguments must already be normalized (lowercased, `www.` stripped).
    /// Subdomain semantics: adding `notion.so` also ignores `www.notion.so`,
    /// `team.notion.so`, and any deeper subdomains.
    nonisolated static func hostMatches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    // MARK: - Private

    private nonisolated static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Strips a single trailing DNS root dot so FQDN (`notion.so.`) and
    /// non-FQDN (`notion.so`) forms normalize to the same canonical host.
    private nonisolated static func stripTrailingDot(_ host: String) -> String {
        host.hasSuffix(".") ? String(host.dropLast()) : host
    }
}
