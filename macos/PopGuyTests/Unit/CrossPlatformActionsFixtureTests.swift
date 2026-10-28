// CrossPlatformActionsFixtureTests.swift
// PopGuyTests
//
// Contract: the custom-action export/import file is shared with the Windows app.
// (A) writes macos-exported-actions.json (one action per type, the app's export
// encoder settings) when POPGUY_WRITE_FIXTURES=1; the Windows tests read it.
// (B) imports the Windows writer's windows-exported-actions.json through the app's
// import path (decode [CustomAction] + sanitizeImported).
//
// Both fixtures live in windows/tests/PopGuy.Tests/Fixtures. Regenerate: run the
// Windows tests, then this suite, both with POPGUY_WRITE_FIXTURES=1 (from xcodebuild:
// TEST_RUNNER_POPGUY_WRITE_FIXTURES=1).

import Foundation
import Testing
@testable import PopGuy

@Suite("CrossPlatformActionsFixture")
struct CrossPlatformActionsFixtureTests {

    private static let writeFixtures = ProcessInfo.processInfo.environment["POPGUY_WRITE_FIXTURES"] == "1"

    @Test("writes macos-exported-actions.json", .enabled(if: writeFixtures))
    func writeMacExportedActions() throws {
        func action(
            _ number: Int, _ title: String, _ type: CustomActionType, _ icon: ActionIcon, _ provider: ProviderKind
        ) -> CustomAction {
            // Fixed ids keep the committed fixture stable across writer runs.
            CustomAction(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!,
                title: title, icon: icon, type: type, systemPrompt: "", providerKind: provider
            )
        }

        var ai = action(1, "Mac AI", .ai, .emoji("🪄"), .anthropic)
        ai.systemPrompt = "Rewrite {{text}} plainly."
        var translate = action(2, "Mac Translate", .translation, .sfSymbol("character.bubble"), .deepL)
        translate.targetLanguage = "fr"
        translate.tone = .formal
        var speak = action(3, "Mac Speak", .speech, .sfSymbol("speaker.wave.2"), .openAI)
        speak.speakSettings.selectedEngine = .cloud(.openAITTS)
        speak.ttsConfig.voiceOverrides = ["fr": "marin"]
        var define = action(4, "Mac Define", .dictionary, .emoji("📖"), .gemini)
        define.dictionaryConfig.provider = .freeDictionaryAPI
        define.dictionaryConfig.definitionLanguage = "vi"
        var search = action(5, "Mac Search", .openURL, .sfSymbol("magnifyingglass"), .ollama)
        search.scriptSource = "https://example.com/search?q={text}"
        search.appliesWhenRegex = "^\\S+$"
        var shortcut = action(6, "Mac Shortcut", .runShortcut, .sfSymbol("square.stack.3d.up"), .glm)
        shortcut.scriptSource = "Make PDF"
        shortcut.afterRun = .showResult
        var appleScript = action(7, "Mac AppleScript", .appleScript, .emoji("🍎"), .openRouter)
        appleScript.scriptSource = "display dialog \"{text}\""
        appleScript.afterRun = .copyResult
        var shell = action(8, "Mac Shell", .shellScript, .sfSymbol("terminal"), .mlxLocal)
        shell.scriptSource = "echo \"$POPGUY_TEXT\" | wc -w"
        shell.afterRun = .pasteResult

        let actions = [ai, translate, speak, define, search, shortcut, appleScript, shell]
        #expect(Set(actions.map(\.type)) == Set(CustomActionType.allCases))

        // The encoder settings of ActionsView's export.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = try fixturesDirectory().appendingPathComponent("macos-exported-actions.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(actions).write(to: url, options: .atomic)
    }

    @Test("imports windows-exported-actions.json through the import path")
    func importWindowsExportedActions() throws {
        let url = try fixturesDirectory().appendingPathComponent("windows-exported-actions.json")
        guard FileManager.default.fileExists(atPath: url.path) || !Self.writeFixtures else {
            print("windows-exported-actions.json missing (writer run): skipping the reader")
            return
        }
        let data = try Data(contentsOf: url)
        // The Windows-only `shell` key is in the file; the macOS decoder ignores it.
        #expect(String(decoding: data, as: UTF8.self).contains("\"shell\": \"powershell\""))

        let decoded = try JSONDecoder().decode([CustomAction].self, from: data)
        let imported = decoded.compactMap { CustomAction.sanitizeImported($0, cloudAllowed: true) }
        try #require(imported.count == decoded.count, "sanitizeImported skipped an action")

        let expected: [(String, CustomActionType, ActionIcon, ProviderKind)] = [
            ("Windows AI", .ai, .emoji("✨"), .openAI),
            ("Windows Translate", .translation, .sfSymbol("globe"), .googleTranslate),
            ("Windows Speak", .speech, .sfSymbol("speaker.wave.3"), .anthropic),
            ("Windows Define", .dictionary, .emoji("📚"), .ollama),
            ("Windows Search", .openURL, .sfSymbol("safari"), .gemini),
            ("Windows Shortcut", .runShortcut, .sfSymbol("bolt"), .custom),
            ("Windows AppleScript", .appleScript, .emoji("📜"), .claudeCLI),
            ("Windows PowerShell", .shellScript, .sfSymbol("terminal.fill"), .codexCLI),
        ]
        try #require(imported.count == expected.count)
        for (action, (title, type, icon, provider)) in zip(imported, expected) {
            #expect(action.title == title)
            #expect(action.type == type, "\(title)")
            #expect(action.icon == icon, "\(title)")
            #expect(action.providerKind == provider, "\(title)")
            #expect(action.libraryPresetID == nil, "\(title)")
        }

        // The one action carrying a Library identity decodes with it; the import gate drops it.
        #expect(decoded.compactMap(\.libraryPresetID) == ["ai.humanize"])
        #expect(imported[0].model == "gpt-5")
        #expect(imported[1].targetLanguage == "de")
        #expect(imported[1].tone == .casual)
        #expect(imported[2].speakSettings.selectedEngine == .cloud(.azureTTS))
        #expect(imported[2].ttsConfig.region == "eastus")
        #expect(imported[3].dictionaryConfig.provider == .minhqnd)
        #expect(imported[4].scriptSource == "https://www.bing.com/search?q={text}")
        #expect(imported[7].scriptSource == "Get-Date")
        #expect(imported[7].afterRun == .showResult)
    }

    /// windows/tests/PopGuy.Tests/Fixtures, found by walking up to the `macos/` folder as HoverTooltipTests does.
    private func fixturesDirectory() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("PopGuy.xcodeproj").path) {
                return url.deletingLastPathComponent()
                    .appendingPathComponent("windows/tests/PopGuy.Tests/Fixtures")
            }
            url.deleteLastPathComponent()
        }

        throw CrossPlatformFixtureError.repositoryRootNotFound
    }
}

private enum CrossPlatformFixtureError: Error {
    case repositoryRootNotFound
}
