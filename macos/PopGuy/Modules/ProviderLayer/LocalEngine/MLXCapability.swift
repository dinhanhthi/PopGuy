// MLXCapability.swift
// PopGuy — ProviderLayer/LocalEngine
//
// Runtime capability gate for the on-device MLX feature.
//
// Requirements:
//   - Apple Silicon (arm64 CPU at runtime — checked via sysctlbyname, NOT
//     compile-time #if arch so the universal binary is correct on both architectures)
//   - macOS 14 or later (MLX requires Metal 3 features first available on macOS 14)
//
// The app target must remain macOS 13.0 compatible, so no macOS 14 symbols
// are used unconditionally. The macOS 14 check is wrapped in #available.
//
// Must compile and run safely on macOS 13 Intel — no crash, just returns false.

import Darwin
import Foundation

// MARK: - MLXCapability

/// Capability gate for the Local (MLX) provider.
///
/// Check `MLXCapability.isSupported` before showing any MLX UI or spawning
/// the helper process. On unsupported configurations (Intel, macOS 13) all
/// MLX entry points are disabled and the helper is never launched.
// nonisolated: all members must be accessible from nonisolated contexts (MLXHelperManager
// actor init, MLXLocalProvider) under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
public nonisolated enum MLXCapability {

    // MARK: - Apple Silicon detection

    /// Returns `true` when the process is running on Apple Silicon (arm64 CPU).
    ///
    /// Uses `sysctlbyname("hw.optional.arm64")` which returns 1 on arm64 hardware
    /// and is undefined (or 0) on Intel. This is a runtime check — safe for a
    /// universal binary where the architecture at launch time matters.
    public nonisolated static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        // result == 0 means the sysctl succeeded and arm64 is present.
        return result == 0 && value == 1
    }

    // MARK: - Combined gate

    /// Whether the MLX on-device feature is supported on this Mac.
    ///
    /// Returns `true` only when both conditions hold:
    ///  1. The Mac has Apple Silicon (arm64 CPU).
    ///  2. The OS is macOS 14 or later.
    ///
    /// The check is deliberately runtime-only so the same binary runs on
    /// macOS 13 Intel without importing or touching any MLX symbols.
    public nonisolated static var isSupported: Bool {
        guard isAppleSilicon else { return false }
        if #available(macOS 14, *) {
            return true
        } else {
            return false
        }
    }

    /// A user-facing explanation shown when `isSupported` is `false`.
    public static let unsupportedReason = "Requires Apple Silicon and macOS 14 or later."

    // MARK: - Pure logic helper (for testing)

    /// Pure function expressing the capability gate logic.
    ///
    /// Extracted so tests can verify all four combinations of (isAppleSilicon, isMacOS14)
    /// without depending on the actual hardware or OS version of the test host.
    /// Production code calls `isSupported` which delegates to the real sensors.
    public nonisolated static func supported(isAppleSilicon: Bool, isMacOS14OrLater: Bool) -> Bool {
        isAppleSilicon && isMacOS14OrLater
    }
}
