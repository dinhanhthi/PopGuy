// TerminalComposerSettingsSection.swift
// PopGuy — UI/SettingsWindow
//
// The "Terminal Composer" section of the Triggers page: the enable switch, the
// Compose shortcut, the `popguy-edit` command (install / re-install / remove) and
// copyable snippets that set it as the editor of shells, Claude Code and git.
//
// The command's status is read and changed off the main thread (file system I/O);
// the buttons react at once and show a busy label until the work is done.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import SwiftUI

struct TerminalComposerSettingsSection: View {

    @ObservedObject var settings: SettingsStore

    /// Whether the Compose shortcut recorder is active.
    @State private var isRecordingShortcut = false
    /// The command's status; nil until first read.
    @State private var commandStatus: CommandInstallStatus?
    /// The running command operation, if any.
    @State private var runningOperation: Operation?
    /// Short inline error of the last failed operation.
    @State private var commandError: String?

    private enum Operation { case install, remove }

    /// Nil when the home folder cannot be found.
    private let installer = CommandInstaller.standard()
    /// Gatekeeper runs a quarantined app from a temporary path: a link to it would dangle.
    private let isTranslocated = Bundle.main.bundlePath.contains("/AppTranslocation/")

    private static let snippets: [(title: String, text: String)] = [
        ("zsh (~/.zshrc)", "export PATH=\"$HOME/.local/bin:$PATH\"\nexport VISUAL=popguy-edit"),
        ("fish", "fish_add_path ~/.local/bin; set -Ux VISUAL popguy-edit"),
        ("Claude Code (~/.claude/settings.json)", "\"env\": { \"VISUAL\": \"popguy-edit\" }"),
        ("git", "git config --global core.editor popguy-edit"),
        ("zsh edit-command-line (Ctrl+X Ctrl+E)", "autoload -U edit-command-line; zle -N edit-command-line; bindkey '^x^e' edit-command-line"),
    ]

    var body: some View {
        SettingsGroup(
            "Terminal Composer",
            footer: "How it works: press Ctrl+G in Claude Code, Codex or Gemini CLI (or set it as git's editor). Done writes the text back and returns to the terminal; Cancel or Esc keeps the original."
        ) {
            LabeledContent {
                Toggle("Enable Terminal Composer", isOn: $settings.terminalComposerEnabled)
                    .toggleStyle(CompactSwitch())
                    .labelsHidden()
            } label: {
                Text("Enable Terminal Composer")
                Text("Edit terminal prompts in a PopGuy window. CLIs like Claude Code (Ctrl+G), git and zsh open it as their editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsDivider()

            composeShortcutRow()

            SettingsDivider()

            commandRow()

            ForEach(Self.snippets, id: \.title) { snippet in
                SettingsDivider()
                snippetRow(title: snippet.title, text: snippet.text)
            }
        }
        .task { await refreshStatus() }
        .onDisappear { isRecordingShortcut = false }
    }

    // MARK: - Compose shortcut

    private func composeShortcutRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 10 pt apart: the icon buttons' hover highlights reach 5 pt past each icon.
            HStack(spacing: 10) {
                Text("Compose shortcut")
                    .foregroundStyle(settings.terminalComposerEnabled ? .primary : .secondary)

                Spacer()

                if isRecordingShortcut {
                    ShortcutRecorder(
                        onCapture: { shortcut in
                            settings.composeShortcut = shortcut
                            isRecordingShortcut = false
                        },
                        onCancel: {
                            isRecordingShortcut = false
                        }
                    )
                } else {
                    if let shortcut = settings.composeShortcut {
                        ShortcutBadge(text: shortcut.displayString)

                        Button {
                            settings.composeShortcut = nil
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(RowIconButtonStyle())
                        .hoverTooltip("Remove shortcut")
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        isRecordingShortcut = true
                    } label: {
                        Image(systemName: "record.circle")
                    }
                    .buttonStyle(RowIconButtonStyle())
                    .hoverTooltip("Record shortcut")
                }
            }
            .disabled(!settings.terminalComposerEnabled)

            Text("Opens an empty composer from any app; Done pastes the text into the app you were in. Also available from the menu bar icon.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Command

    private func commandRow() -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if showsInstallButton {
                    Button(installButtonTitle) { run(.install) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(runningOperation != nil || isTranslocated)
                }
                if showsRemoveButton {
                    Button(runningOperation == .remove ? "Removing\u{2026}" : "Remove") { run(.remove) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(runningOperation != nil)
                }
            }
        } label: {
            Text("Command")
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let commandError {
                Text(commandError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Open a new terminal after installing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        guard installer != nil else { return "Your home folder could not be found." }
        switch commandStatus {
        case nil:
            return "Checking\u{2026}"
        case .installed?:
            return "Installed — popguy-edit is in ~/.local/bin."
        case .blockedByForeignFile?:
            return "~/.local/bin/popguy-edit is another file — PopGuy won't overwrite it."
        case _ where isTranslocated:
            return "Move PopGuy to the Applications folder first, then install the command."
        case .notInstalled?:
            return "Not installed."
        case .pointsElsewhere?:
            return "Points to another PopGuy copy."
        }
    }

    private var showsInstallButton: Bool {
        guard installer != nil else { return false }
        switch commandStatus {
        case .notInstalled?, .pointsElsewhere?: return true
        default: return false
        }
    }

    private var showsRemoveButton: Bool {
        switch commandStatus {
        case .installed?, .pointsElsewhere?: return true
        default: return false
        }
    }

    private var installButtonTitle: String {
        if runningOperation == .install { return "Installing\u{2026}" }
        if case .pointsElsewhere? = commandStatus { return "Re-install" }
        return "Install command"
    }

    private func refreshStatus() async {
        guard let installer else { return }
        commandStatus = await Task.detached { installer.status }.value
    }

    /// Runs install or remove off the main thread, then shows the new status (and a short error).
    private func run(_ operation: Operation) {
        guard let installer, runningOperation == nil else { return }
        runningOperation = operation
        commandError = nil
        let isInstall = operation == .install
        Task {
            let (status, failure) = await Task.detached { () -> (CommandInstallStatus, (any Error)?) in
                do {
                    if isInstall { try installer.install() } else { try installer.remove() }
                    return (installer.status, nil)
                } catch {
                    return (installer.status, error)
                }
            }.value
            commandStatus = status
            // A foreign file is already explained by the status line.
            if let failure, failure as? CommandInstallError != .blockedByForeignFile {
                commandError = (isInstall ? "Couldn't install the command: " : "Couldn't remove the command: ")
                    + failure.localizedDescription
            }
            runningOperation = nil
        }
    }

    // MARK: - Snippets

    private func snippetRow(title: String, text: String) -> some View {
        LabeledContent {
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(RowIconButtonStyle())
            .hoverTooltip("Copy")
        } label: {
            Text(title)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
