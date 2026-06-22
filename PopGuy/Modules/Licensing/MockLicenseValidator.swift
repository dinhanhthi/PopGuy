// MockLicenseValidator.swift
// PopGuy — Licensing
//
// DEBUG-ONLY fake validator for exercising the Pro UX without a live Lemon
// Squeezy account (e.g. while the LS account is still pending verification).
//
// Enable it by setting the POPGUY_MOCK_PRO environment variable in the Xcode
// Run scheme (Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments ▸ Environment
// Variables ▸ add POPGUY_MOCK_PRO = 1). Then in Settings ▸ License, type ANY
// non-empty key and Activate — Pro unlocks. Unset the variable (or build for
// Release) to fall back to the real Lemon Squeezy validator.
//
// This whole file is compiled out of Release builds via `#if DEBUG`, so it can
// never ship — EXCEPT when the dev-distribution script (scripts/sign-and-share.sh)
// passes the `DEV_MOCK_PRO` compilation condition for a self-signed test build.
// That flag lives only in that script, never in the project's build settings.

#if DEBUG || DEV_MOCK_PRO
import Foundation

/// A fake `LicenseValidating` that grants Pro for any non-empty key. DEBUG only.
nonisolated struct MockLicenseValidator: LicenseValidating {
    func validate(licenseKey: String) async -> LicenseStatus {
        if licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalid(reason: "Enter any non-empty key to mock-activate Pro (DEBUG).")
        }
        return .valid(activatedKeyMasked: LicenseKeyMask.mask(licenseKey))
    }

    func deactivate(licenseKey: String) async {
        // No server seat to free in mock mode.
    }
}
#endif
