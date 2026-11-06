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
        Form {
            Section(header: Text("App")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable PopGuy", isOn: $settings.popGuyEnabled)
                    Text("When off, every trigger — text selection, double-click, Cmd+C+C, and hotkeys — is suppressed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Start at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            applyLoginItem(newValue)
                        }
                    if let error = loginItemError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("Automatically launch PopGuy when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show app icon on the Dock while Settings is open", isOn: $settings.showDockIconWithSettings)
                    Text("Normally PopGuy lives in the menu bar only. Turn this on to also show a Dock icon while the Settings window is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button("Setup Guide\u{2026}") {
                        onReplayOnboarding()
                    }
                    .hoverTooltip("Replay the first-run setup guide")
                    Text("Opens the first-run walkthrough again. Settings stays open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Global Prompt")) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $settings.globalPrompt)
                        .font(.body)
                        // Keep the editor's own text background: the page-wide
                        // `.scrollContentBackground(.hidden)` would clear it on macOS 13–15.
                        .scrollContentBackground(.visible)
                        .frame(minHeight: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.separator, lineWidth: 1)
                        )
                    Text("Added to the beginning of every AI action's prompt — Improve, Shorten, Proofread, Translate, the Prompt action, and custom actions — so you don't repeat the same instruction in each one. Leave empty to disable. Available: {{app}}, {{date}}, {{language}}, {{domain}} (only when Ignored Domains is on).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Formatting")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Preserve & render formatting", isOn: $settings.preserveFormatting)
                    Text("Render Markdown text styles and lists in the result. Bold, italic, strikethrough, inline code, and lists are supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("Closing the Toolbar")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Confirm before closing a finished result", isOn: $settings.confirmCloseAfterResult)
                    Text("When on, clicking outside or pressing Escape after a result is ready asks for confirmation, so you don't dismiss it by accident.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Enter on a result", selection: $settings.enterResultAction) {
                        ForEach(EnterResultAction.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Text("What pressing Enter does while a result shows. When a result it applies to appears while the source app is in front, the toolbar takes the keyboard, so your typing does not reach the source app until it closes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Picker("If that isn't available", selection: $settings.enterResultFallback) {
                        ForEach(EnterResultAction.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Text("Used when the first choice does not apply to the result: Paste back needs an editable text field, and Regenerate needs an action that can run again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(settings.enterResultAction == .nothing)
            }
        }
        .formStyle(.grouped)
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
