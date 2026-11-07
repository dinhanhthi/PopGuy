// GeneralView.swift
// PopGuy — UI/SettingsWindow

import ServiceManagement
import SwiftUI

struct GeneralView: View {
    @ObservedObject var settings: SettingsStore
    let onReplayOnboarding: () -> Void

    @State private var launchAtLogin = false
    @State private var loginItemError: String? = nil
    /// The section the header-row tabs show.
    @State private var tab: GeneralTab = .app

    var body: some View {
        // The page builds its own layout so its tabs paint in the click's
        // frame; only the body below waits for the deferred turn. The tab is
        // read here and passed down so the body depends on it explicitly
        // (DeferredSectionContent builds its content in this body anyway).
        let tab = tab
        return SettingsPageLayout(leading: {
            CapsuleTabs(selection: $tab, tabs: GeneralTab.allCases, title: { Text($0.title) })
                .fixedSize()
        }) {
            DeferredSectionContent { pageBody(tab) }
        }
        #if DEBUG
        .onAppear(perform: applyDebugTab)
        #endif
    }

    #if DEBUG
    /// DEBUG-only QA hook: `--general-tab=app|globalPrompt|formatting|closingToolbar`
    /// selects a tab when the page appears, for screenshots from a shell.
    private func applyDebugTab() {
        let prefix = "--general-tab="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
              let value = GeneralTab(rawValue: String(arg.dropFirst(prefix.count))) else { return }
        tab = value
    }
    #endif

    private func pageBody(_ tab: GeneralTab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                switch tab {
                case .app:
                    // No title: the header-row tab already names the section.
                    SettingsGroup(nil) {
                        LabeledContent {
                            Toggle("Enable PopGuy", isOn: $settings.popGuyEnabled)
                                .toggleStyle(CompactSwitch())
                                .labelsHidden()
                        } label: {
                            Text("Enable PopGuy")
                            Text("When off, every trigger — text selection, double-click, Cmd+C+C, and hotkeys — is suppressed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        SettingsDivider()

                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent {
                                Toggle("Start at login", isOn: $launchAtLogin)
                                    .toggleStyle(CompactSwitch())
                                    .labelsHidden()
                                    .onChange(of: launchAtLogin) { newValue in
                                        applyLoginItem(newValue)
                                    }
                            } label: {
                                Text("Start at login")
                                Text("Automatically launch PopGuy when you log in.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let error = loginItemError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        SettingsDivider()

                        LabeledContent {
                            Toggle("Show app icon on the Dock while Settings is open", isOn: $settings.showDockIconWithSettings)
                                .toggleStyle(CompactSwitch())
                                .labelsHidden()
                        } label: {
                            Text("Show app icon on the Dock while Settings is open")
                            Text("Normally PopGuy lives in the menu bar only. Turn this on to also show a Dock icon while the Settings window is open.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        SettingsDivider()

                        VStack(alignment: .leading, spacing: 8) {
                            Button("Setup Guide\u{2026}") {
                                onReplayOnboarding()
                            }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                            .hoverTooltip("Replay the first-run setup guide")
                            Text("Opens the first-run walkthrough again. Settings stays open.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .globalPrompt:
                    // No title: the header-row tab already names the section.
                    SettingsGroup(nil) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $settings.globalPrompt)
                                .font(.body)
                                .frame(minHeight: 80)
                                .settingsTextEditor()
                            Text("Added to the beginning of every AI action's prompt — Improve, Shorten, Proofread, Translate, the Prompt action, and custom actions — so you don't repeat the same instruction in each one. Leave empty to disable. Available: {{app}}, {{date}}, {{language}}, {{domain}} (only when Ignored Domains is on).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .formatting:
                    // No title: the header-row tab already names the section.
                    SettingsGroup(nil) {
                        LabeledContent {
                            Toggle("Preserve & render formatting", isOn: $settings.preserveFormatting)
                                .toggleStyle(CompactSwitch())
                                .labelsHidden()
                        } label: {
                            Text("Preserve & render formatting")
                            Text("Render Markdown text styles and lists in the result. Bold, italic, strikethrough, inline code, and lists are supported.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .closingToolbar:
                    // No title: the header-row tab already names the section.
                    SettingsGroup(nil) {
                        LabeledContent {
                            Toggle("Confirm before closing a finished result", isOn: $settings.confirmCloseAfterResult)
                                .toggleStyle(CompactSwitch())
                                .labelsHidden()
                        } label: {
                            Text("Confirm before closing a finished result")
                            Text("When on, clicking outside or pressing Escape after a result is ready asks for confirmation, so you don't dismiss it by accident.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        SettingsDivider()

                        LabeledContent {
                            Picker("Enter on a result", selection: $settings.enterResultAction) {
                                ForEach(EnterResultAction.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        } label: {
                            Text("Enter on a result")
                            Text("What pressing Enter does while a result shows. When a result it applies to appears while the source app is in front, the toolbar takes the keyboard, so your typing does not reach the source app until it closes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        SettingsDivider()

                        LabeledContent {
                            Picker("If that isn't available", selection: $settings.enterResultFallback) {
                                ForEach(EnterResultAction.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        } label: {
                            Text("If that isn't available")
                            Text("Used when the first choice does not apply to the result: Paste back needs an editable text field, and Regenerate needs an action that can run again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .disabled(settings.enterResultAction == .nothing)
                    }
                }
            }
            .padding(SettingsMetrics.pagePadding)
        }
        .labeledContentStyle(.settingsRow)
        .onAppear {
            syncLoginItemState()
        }
    }

    private func syncLoginItemState() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            launchAtLogin = true
        case .requiresApproval:
            launchAtLogin = true
            loginItemError = "Pending approval — open Login Items in System Settings to allow it."
        default:
            launchAtLogin = false
        }
    }

    /// Returns true when the login item is effectively active (registered or pending approval).
    private var isLoginItemActive: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    private func applyLoginItem(_ enable: Bool) {
        // Guard against redundant calls: if the desired state already matches
        // the actual service status, do nothing. This also breaks the re-entrant
        // loop caused by the error-recovery path setting launchAtLogin = !enable.
        guard isLoginItemActive != enable else { return }
        loginItemError = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
                // macOS may defer the registration to user approval.
                if SMAppService.mainApp.status == .requiresApproval {
                    loginItemError = "Pending approval — open Login Items in System Settings to allow it."
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enable
            loginItemError = "Could not \(enable ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
    }
}

// MARK: - GeneralTab

/// The General page's tabs, one per section.
private enum GeneralTab: String, CaseIterable {
    case app, globalPrompt, formatting, closingToolbar

    var title: String {
        switch self {
        case .app:            "App"
        case .globalPrompt:   "Global prompt"
        case .formatting:     "Formatting"
        case .closingToolbar: "Closing the toolbar"
        }
    }
}
