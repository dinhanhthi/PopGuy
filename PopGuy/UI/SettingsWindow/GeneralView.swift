// GeneralView.swift
// PopGuy — UI/SettingsWindow

import ServiceManagement
import SwiftUI

struct GeneralView: View {
    @ObservedObject var settings: SettingsStore

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
            }

            Section(header: Text("Closing the Toolbar")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Confirm before closing a finished result", isOn: $settings.confirmCloseAfterResult)
                    Text("When on, clicking outside or pressing Escape after a result is ready asks for confirmation, so you don't dismiss it by accident.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
