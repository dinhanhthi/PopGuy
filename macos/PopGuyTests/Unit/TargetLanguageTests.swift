// TargetLanguageTests.swift
// PopGuyTests
//
// Ensures TargetLanguage enum covers every language the SettingsView
// TranslateTab offers — guards against silent English fallback for any
// language code that appears in the Settings picker.

import Testing
@testable import PopGuy

@Suite("TargetLanguage")
struct TargetLanguageTests {

    // The exact set of bcp47 codes offered by SettingsView.TranslateTab.
    // Keep this list in sync with the `languages` array in SettingsView.swift.
    private let settingsPickerCodes: [(name: String, bcp47: String)] = [
        ("English",              "en"),
        ("Vietnamese",           "vi"),
        ("French",               "fr"),
        ("Spanish",              "es"),
        ("German",               "de"),
        ("Japanese",             "ja"),
        ("Chinese (Simplified)", "zh"),
        ("Korean",               "ko"),
        ("Portuguese",           "pt"),
        ("Italian",              "it"),
    ]

    // MARK: - Alignment tests

    @Test("every non-English picker code maps to a non-.english TargetLanguage case")
    func noSilentEnglishFallback() {
        for entry in settingsPickerCodes where entry.bcp47 != "en" {
            let lang = TargetLanguage(bcp47: entry.bcp47)
            #expect(lang != .english,
                    "bcp47 '\(entry.bcp47)' (\(entry.name)) silently fell back to .english")
        }
    }

    @Test("'en' maps to .english")
    func englishMapsCorrectly() {
        #expect(TargetLanguage(bcp47: "en") == .english)
    }

    @Test("each picker code round-trips through TargetLanguage.bcp47")
    func bcp47RoundTrips() {
        for entry in settingsPickerCodes {
            let lang = TargetLanguage(bcp47: entry.bcp47)
            #expect(lang.bcp47 == entry.bcp47,
                    "bcp47 '\(entry.bcp47)' round-trip failed: got '\(lang.bcp47)'")
        }
    }

    // MARK: - New cases

    @Test("Korean (ko) maps to .korean")
    func koreanCase() {
        #expect(TargetLanguage(bcp47: "ko") == .korean)
        #expect(TargetLanguage.korean.bcp47 == "ko")
    }

    @Test("Portuguese (pt) maps to .portuguese")
    func portugueseCase() {
        #expect(TargetLanguage(bcp47: "pt") == .portuguese)
        #expect(TargetLanguage.portuguese.bcp47 == "pt")
    }

    @Test("Italian (it) maps to .italian")
    func italianCase() {
        #expect(TargetLanguage(bcp47: "it") == .italian)
        #expect(TargetLanguage.italian.bcp47 == "it")
    }

    @Test("unknown code falls back to .english")
    func unknownCodeFallback() {
        #expect(TargetLanguage(bcp47: "xx") == .english)
        #expect(TargetLanguage(bcp47: "") == .english)
    }

    @Test("allCases count matches settings picker count")
    func caseCountMatchesPicker() {
        #expect(TargetLanguage.allCases.count == settingsPickerCodes.count,
                "TargetLanguage.allCases has \(TargetLanguage.allCases.count) cases but settings picker has \(settingsPickerCodes.count) entries")
    }
}
