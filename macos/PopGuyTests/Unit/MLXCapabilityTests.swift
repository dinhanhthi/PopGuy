// MLXCapabilityTests.swift
// PopGuyTests
//
// Tests for MLXCapability — runtime gate for the on-device MLX feature.
//
// Tests fall into two groups:
//   1. Hardware-independent logic (four combinations via the pure helper)
//   2. Host-level smoke tests (actual sysctlbyname + #available result)

import Foundation
import Testing
@testable import PopGuy

@Suite("MLXCapability")
struct MLXCapabilityTests {

    // MARK: - Pure logic (all four combos)

    @Test("not Apple Silicon → not supported regardless of macOS version")
    func notAppleSiliconAlwaysUnsupported() {
        #expect(MLXCapability.supported(isAppleSilicon: false, isMacOS14OrLater: false) == false)
        #expect(MLXCapability.supported(isAppleSilicon: false, isMacOS14OrLater: true)  == false)
    }

    @Test("Apple Silicon + macOS < 14 → not supported")
    func appleSiliconButOldMacOS() {
        #expect(MLXCapability.supported(isAppleSilicon: true, isMacOS14OrLater: false) == false)
    }

    @Test("Apple Silicon + macOS 14 → supported")
    func appleSiliconAndMacOS14() {
        #expect(MLXCapability.supported(isAppleSilicon: true, isMacOS14OrLater: true) == true)
    }

    // MARK: - Host smoke tests

    @Test("isAppleSilicon returns a Bool without crashing")
    func isAppleSiliconDoesNotCrash() {
        let result: Bool = MLXCapability.isAppleSilicon
        _ = result  // suppress unused-variable note
    }

    @Test("isSupported returns a Bool without crashing")
    func isSupportedDoesNotCrash() {
        let result: Bool = MLXCapability.isSupported
        _ = result
    }

    @Test("isSupported implies isAppleSilicon")
    func isSupportedImpliesAppleSilicon() {
        if MLXCapability.isSupported {
            #expect(MLXCapability.isAppleSilicon,
                    "isSupported=true on a non-Apple-Silicon host violates the gate logic")
        }
    }

    @Test("not Apple Silicon implies not supported (contrapositive)")
    func notAppleSiliconImpliesNotSupported() {
        if !MLXCapability.isAppleSilicon {
            #expect(!MLXCapability.isSupported,
                    "isSupported=true despite isAppleSilicon=false violates the gate logic")
        }
    }

    // MARK: - unsupportedReason content

    @Test("unsupportedReason mentions Apple Silicon")
    func unsupportedReasonMentionsAppleSilicon() {
        let reason = MLXCapability.unsupportedReason
        #expect(reason.localizedCaseInsensitiveContains("apple silicon"),
                "Expected 'Apple Silicon' in unsupportedReason; got: \(reason)")
    }

    @Test("unsupportedReason mentions macOS")
    func unsupportedReasonMentionsMacOS() {
        let reason = MLXCapability.unsupportedReason
        #expect(reason.localizedCaseInsensitiveContains("macos"),
                "Expected 'macOS' in unsupportedReason; got: \(reason)")
    }
}
