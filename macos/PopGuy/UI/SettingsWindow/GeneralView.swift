// GeneralView.swift
// PopGuy — UI/SettingsWindow

import ServiceManagement
import SwiftUI

struct GeneralView: View {
    @ObservedObject var settings: SettingsStore
    let onReplayOnboarding: () -> Void

    @State private var launchAtLogin = false
    @State private var loginItemError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                SettingsGroup("App") {
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

                SettingsGroup("Global Prompt") {
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

                SettingsGroup("Formatting") {
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

                SettingsGroup("Closing the Toolbar") {
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
