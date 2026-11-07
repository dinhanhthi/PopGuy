// TerminalComposerView.swift
// PopGuy — UI/SettingsWindow
//
// The Settings → Composer page (Terminal Composer): a one-line intro, the enable switch,
// the Compose shortcut, the `popguy-edit` command (install / re-install / remove), then
// "Set PopGuy as the editor": the shell setup (the PATH/VISUAL lines in the shell config,
// confirmed in a SettingsModal shown by SettingsView, with the how-it-works line) and
// copyable snippets, each with a caption, for shells, Claude Code and git.
//
// The command's and the shell's status are read and changed off the main thread (file
// system I/O); the buttons react at once and show a busy label until the work is done.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import SwiftUI

struct TerminalComposerView: View {

    @ObservedObject var settings: SettingsStore
    /// Non-nil while SettingsView shows the "Set up shell" confirm modal.
    @Binding var shellSetupConfirmation: ShellSetupConfirmation?

    /// Whether the Compose shortcut recorder is active.
    @State private var isRecordingShortcut = false
    /// The command's status; nil until first read.
    @State private var commandStatus: CommandInstallStatus?
    /// The running command operation, if any.
    @State private var runningOperation: Operation?
    /// Short inline error of the last failed operation.
    @State private var commandError: String?

    /// The shell config's status; nil until first read.
    @State private var shellStatus: ShellSetupStatus?
    /// The running shell setup operation, if any.
    @State private var shellOperation: Operation?
    /// Short inline error of the last failed shell operation.
    @State private var shellError: String?

    private enum Operation { case install, remove }

    /// Nil when the home folder cannot be found.
    private let installer = CommandInstaller.standard()
    /// Nil when the user record cannot be read.
    private let shellSetup = ShellSetup.standard()
    /// Gatekeeper runs a quarantined app from a temporary path: a link to it would dangle.
    private let isTranslocated = Bundle.main.bundlePath.contains("/AppTranslocation/")

    private static let snippets: [(title: String, caption: String, text: String)] = [
        ("zsh (~/.zshrc)",
         "Recommended. Adds popguy-edit to PATH and makes it the editor for Claude Code, Codex, Gemini CLI, git and more. Then open a new terminal.",
         "export PATH=\"$HOME/.local/bin:$PATH\"\nexport VISUAL=popguy-edit"),
        ("fish",
         "The same for fish shell.",
         "fish_add_path ~/.local/bin; set -Ux VISUAL popguy-edit"),
        ("Claude Code (~/.claude/settings.json)",
         "Only if you don't set VISUAL in your shell: makes just Claude Code use PopGuy.",
         "\"env\": { \"VISUAL\": \"popguy-edit\" }"),
        ("git",
         "Only if git has its own core.editor, or to use PopGuy for git only.",
         "git config --global core.editor popguy-edit"),
        ("zsh edit-command-line (Ctrl+X Ctrl+E)",
         "Optional: press Ctrl+X Ctrl+E at the zsh prompt to edit the current command in PopGuy.",
         "autoload -U edit-command-line; zle -N edit-command-line; bindkey '^x^e' edit-command-line"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                Text("Write long terminal prompts in a comfortable editor. When a terminal tool asks for an editor, PopGuy opens a Markdown window, then sends your text back to the terminal.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
                composerGroup
                snippetsGroup
            }
            .padding(SettingsMetrics.pagePadding)
        }
        .labeledContentStyle(.settingsRow)
        .task {
            await refreshStatus()
            await refreshShellStatus()
        }
        .onDisappear { isRecordingShortcut = false }
    }

    // MARK: - Groups

    /// No title: the page header already reads "Composer" (the sidebar title).
    private var composerGroup: some View {
        SettingsGroup(nil) {
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
        }
    }

    private var snippetsGroup: some View {
        SettingsGroup("Set PopGuy as the editor") {
            shellRow()

            SettingsDivider()

            Text("Set up shell does this for you. To do it by hand, paste one line into your shell config. Most people only need the first one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.snippets, id: \.title) { snippet in
                SettingsDivider()
                snippetRow(title: snippet.title, caption: snippet.caption, text: snippet.text)
            }
        }
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

    // MARK: - Shell

    private func shellRow() -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if case .notSetUp? = shellStatus {
                    Button(shellOperation == .install ? "Setting up\u{2026}" : "Set up shell\u{2026}") {
                        confirmShellSetup()
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(shellOperation != nil)
                }
                if case .setUp? = shellStatus {
                    Button(shellOperation == .remove ? "Removing\u{2026}" : "Remove") { runShell(.remove) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(shellOperation != nil)
                }
            }
        } label: {
            Text("Shell")
            Text(shellStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let shellError {
                Text(shellError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Adds the PATH and VISUAL lines to your shell config, between PopGuy markers. Open a new terminal afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\u{1F4A1} How it works: press Ctrl+G in Claude Code, Codex or Gemini CLI (or set it as git's editor). Done writes the text back and returns to the terminal; Cancel or Esc keeps the original.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var shellStatusText: String {
        guard let shellSetup else { return "Your home folder could not be found." }
        switch shellStatus {
        case nil: return "Checking\u{2026}"
        case .setUp(let file)?: return "Set up in \(shellSetup.displayPath(file))."
        case .notSetUp?: return "Not set up."
        case .unsupported(let name)?: return "Your shell (\(name)) isn't supported — use the lines below."
        }
    }

    private func refreshShellStatus() async {
        guard let shellSetup else { return }
        shellStatus = await Task.detached { shellSetup.status }.value
    }

    /// Opens the confirm modal; its confirm button runs the install.
    private func confirmShellSetup() {
        guard let preview = shellSetup?.preview, shellOperation == nil else { return }
        withAnimation(Motion.sheet) {
            shellSetupConfirmation = ShellSetupConfirmation(preview: preview) { runShell(.install) }
        }
    }

    /// Runs the shell install or remove off the main thread, then shows the new status (and a short error).
    private func runShell(_ operation: Operation) {
        guard let shellSetup, shellOperation == nil else { return }
        shellOperation = operation
        shellError = nil
        let isInstall = operation == .install
        Task {
            let (status, failure) = await Task.detached { () -> (ShellSetupStatus, (any Error)?) in
                do {
                    if isInstall { try shellSetup.install() } else { try shellSetup.remove() }
                    return (shellSetup.status, nil)
                } catch {
                    return (shellSetup.status, error)
                }
            }.value
            shellStatus = status
            if let failure {
                shellError = (isInstall ? "Couldn't set up the shell: " : "Couldn't remove the shell lines: ")
                    + failure.localizedDescription
            }
            shellOperation = nil
        }
    }

    // MARK: - Snippets

    private func snippetRow(title: String, caption: String, text: String) -> some View {
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
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Shell setup confirm modal

/// A pending "Set up shell" confirmation: what will be written and the page's install.
struct ShellSetupConfirmation {
    let preview: ShellSetupPreview
    let onConfirm: () -> Void
}

/// The confirm card shown in a SettingsModal: the target file and the exact lines.
struct ShellSetupConfirmView: View {

    let preview: ShellSetupPreview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// The card holds the keyboard focus (it has no field), so Esc reaches the modal.
    @FocusState private var cardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Set Up Shell")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(BottomBarButtonStyle(height: 28, horizontalPadding: 12))
                Button("Add to \(preview.file.lastPathComponent)", action: onConfirm)
                    .buttonStyle(BottomBarButtonStyle(height: 28, prominent: true, horizontalPadding: 12))
            }
            // At the top of the modal card, symmetric vertical padding.
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .padding(.vertical, SettingsMetrics.cardPadding + 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("PopGuy adds these lines to \(preview.displayPath), between PopGuy markers. Nothing else in the file changes.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(preview.lines)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("Open a new terminal afterwards. Remove takes the lines out again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(SettingsMetrics.cardPadding + 6)
            }
        }
        // No minimum height: the modal card sets the height.
        .frame(minWidth: 480)
        .focusable()
        .modifier(NoFocusRing())
        .focused($cardFocused)
        // Next run-loop turn, once the card is in the window.
        .onAppear { DispatchQueue.main.async { cardFocused = true } }
    }
}
