// OnboardingProviderPage.swift
// PopGuy — UI/Onboarding
//
// Provider chooser for first-launch onboarding: Local AI vs Cloud API key.
// Local branch downloads the free on-device model via SettingsStore (app-lifetime
// Task — this view only observes progress). Cloud branch picks a provider,
// validates the API key, stores it in Keychain, and maps matching actions.
//
// Isolation: @MainActor — all UI.

import AppKit
import SwiftUI

/// Local vs Cloud chooser for the onboarding provider page.
///
/// Held as `@State` on `OnboardingView` (not this page) so Back/Next
/// preserves the selection and so local-action mapping can outlive this view.
enum ProviderMode {
    case local
    case cloud
}

// MARK: - OnboardingProviderPage

/// Chooser + branch host for the onboarding provider page.
///
/// Callers inject:
///   - `settings`: the shared `SettingsStore` (download / action mapping).
///   - `keychain`: the shared `KeychainManager` (API keys stay in Keychain only).
///   - `mode`: binding to the parent-owned chooser selection.
@MainActor
struct OnboardingProviderPage: View {

    @ObservedObject var settings: SettingsStore
    let keychain: KeychainManager
    @Binding var mode: ProviderMode

    /// Cloud providers offered in onboarding (no CLI / GLM / OpenRouter / Custom).
    private static let cloudProviders: [ProviderKind] = [
        .openAI, .anthropic, .gemini, .deepL, .googleTranslate
    ]

    @State private var cloudProvider: ProviderKind = .openAI
    /// Draft only — the stored key is never loaded into this field.
    @State private var cloudDraftKey: String = ""
    @State private var cloudIsVerifying = false
    @State private var cloudVerifyError: String?
    @State private var cloudDidSave = false
    @State private var cloudHasSavedKey = false
    @State private var cloudKeyPreview: String?
    @State private var cloudVerifyTask: Task<Void, Never>?

    /// Free-tier catalog entry offered here (`ProConfig.freeLocalModelIDs`).
    private var freeLocalModel: LocalModel? {
        LocalModelCatalog.all.first { ProConfig.freeLocalModelIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            chooser
            branch
        }
        .onChange(of: mode) { newMode in
            guard newMode != .cloud else { return }
            cloudVerifyTask?.cancel()
            cloudVerifyTask = nil
            cloudIsVerifying = false
        }
    }

    // MARK: - Chooser

    private var chooser: some View {
        VStack(spacing: 10) {
            modeCard(
                .local,
                icon: "laptopcomputer",
                title: "Local AI",
                caption: "Private and free — it runs on your Mac with no API key. You'll download a model, and you need a modern Apple silicon Mac.",
                isEnabled: MLXCapability.isSupported,
                disabledReason: MLXCapability.isSupported ? nil : MLXCapability.unsupportedReason
            )
            modeCard(
                .cloud,
                icon: "cloud",
                title: "Cloud API key",
                caption: "Fast and top quality. Paste a small API key for OpenAI, Anthropic, Gemini, or DeepL — usage costs pennies.",
                isEnabled: true
            )
        }
    }

    private func modeCard(
        _ cardMode: ProviderMode,
        icon: String,
        title: String,
        caption: String,
        isEnabled: Bool,
        disabledReason: String? = nil
    ) -> some View {
        let isSelected = mode == cardMode
        return Button {
            mode = cardMode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let disabledReason {
                        Text(disabledReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.07),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Branch

    @ViewBuilder
    private var branch: some View {
        switch mode {
        case .local:
            localBranch
        case .cloud:
            cloudBranch
        }
    }

    // MARK: - Local branch

    @ViewBuilder
    private var localBranch: some View {
        if let model = freeLocalModel {
            localModelCard(model)
        } else {
            Text("The free on-device model is unavailable.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func localModelCard(_ model: LocalModel) -> some View {
        let isDownloading = settings.activeLocalModelDownloadID == model.id
        let isInstalled = settings.installedLocalModels.contains(model.id)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.headline)
                    Text("~\(formatBytes(model.approxSizeBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                trailingControl(model: model, isDownloading: isDownloading, isInstalled: isInstalled)
            }

            if isDownloading {
                downloadProgress(
                    name: model.displayName,
                    fraction: settings.localModelDownloadProgress[model.id]
                )
            }

            if let error = settings.localModelDownloadError {
                errorBanner(error)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func trailingControl(
        model: LocalModel,
        isDownloading: Bool,
        isInstalled: Bool
    ) -> some View {
        if isDownloading {
            Button("Cancel") {
                settings.cancelLocalModelDownload()
            }
            .buttonStyle(.bordered)
            .hoverTooltip("Cancel the download")
        } else if isInstalled {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            let anyDownloadActive = settings.activeLocalModelDownloadID != nil
            Button("Download") {
                settings.downloadLocalModel(model.id, isPro: false)
                if settings.activeLocalModelDownloadID == model.id {
                    settings.markPendingOnboardingLocalMap(modelID: model.id)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(anyDownloadActive)
            .hoverTooltip(anyDownloadActive
                ? "Another model is downloading — wait for it to finish"
                : "Download \(model.displayName)")
        }
    }

    /// Determinate bar when `SettingsStore` has a known fraction; otherwise
    /// an indeterminate bar until the first progress event.
    private func downloadProgress(name: String, fraction: Double?) -> some View {
        let clamped = fraction.map { min(max($0, 0), 1) } ?? 0
        let label = clamped > 0
            ? "Downloading \(name)… \(Int((clamped * 100).rounded()))%"
            : "Preparing \(name)…"
        return VStack(alignment: .leading, spacing: 3) {
            Group {
                if clamped > 0 {
                    ProgressView(value: clamped)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Formats a byte count as a compact size (e.g. "1 GB").
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Cloud branch

    private var cloudActionNote: String {
        switch cloudProvider {
        case .openAI, .anthropic, .gemini:
            return "Powers Improve, Shorten, Proofread, and Prompt."
        case .deepL, .googleTranslate:
            return "Powers Translate."
        case .ollama, .glm, .openRouter, .custom, .claudeCLI, .codexCLI, .geminiCLI, .mlxLocal:
            return ""
        }
    }

    @ViewBuilder
    private var cloudBranch: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Provider")
                    .font(.subheadline)
                Picker("Provider", selection: $cloudProvider) {
                    ForEach(Self.cloudProviders, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(cloudActionNote)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = cloudProvider.apiKeyURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text("Get an API key")
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                .buttonStyle(.bordered)
                .hoverTooltip("Open \(cloudProvider.displayName) to create an API key")

                Text("Register an account, create a new API key, then paste it below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                SecureField("API key", text: $cloudDraftKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(cloudIsVerifying)
                    .onSubmit { saveAndVerifyCloudKey() }

                Button("Save & Verify") {
                    saveAndVerifyCloudKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    cloudDraftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || cloudIsVerifying
                )
                .hoverTooltip(
                    cloudIsVerifying
                        ? "Verifying the API key…"
                        : "Verify the key with the provider and save it"
                )
            }

            if cloudIsVerifying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if cloudHasSavedKey, !cloudDidSave {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A key is already saved. Paste a new one to replace it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let cloudKeyPreview {
                        Text(cloudKeyPreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    }
                }
            }

            if cloudDidSave {
                Label("API key saved", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }

            if let cloudVerifyError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    Text(cloudVerifyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("For everyday selections, usage costs only a few cents per month — most users spend under a dollar. You pay the provider directly; PopGuy adds nothing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .onAppear { refreshCloudKeyState() }
        .onChange(of: cloudProvider) { _ in
            cloudVerifyTask?.cancel()
            cloudVerifyTask = nil
            cloudDraftKey = ""
            cloudIsVerifying = false
            cloudVerifyError = nil
            cloudDidSave = false
            refreshCloudKeyState()
        }
    }

    /// Read Keychain only to derive a masked preview; never put the raw key in the field.
    private func refreshCloudKeyState() {
        let stored = keychain.key(for: cloudProvider)
        cloudHasSavedKey = stored != nil
        cloudKeyPreview = maskedKeyPreview(stored)
    }

    private func saveAndVerifyCloudKey() {
        let trimmed = cloudDraftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !cloudIsVerifying else { return }

        cloudVerifyTask?.cancel()
        cloudIsVerifying = true
        cloudVerifyError = nil
        cloudDidSave = false

        let kind = cloudProvider
        let keychain = self.keychain
        let settings = self.settings

        cloudVerifyTask = Task { @MainActor in
            do {
                try await ProviderKeyValidator.validate(kind: kind, apiKey: trimmed)
                guard !Task.isCancelled else { return }
                guard mode == .cloud else {
                    cloudIsVerifying = false
                    return
                }
                let saved = keychain.setKey(trimmed, for: kind)
                if saved {
                    cloudDraftKey = ""
                    cloudHasSavedKey = true
                    cloudKeyPreview = maskedKeyPreview(trimmed)
                    cloudDidSave = true
                    Self.pointActionsAtCloudProvider(kind, settings: settings)
                    settings.clearPendingOnboardingLocalMap()
                } else {
                    cloudVerifyError = "Could not save the API key. Please try again."
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard mode == .cloud else {
                    cloudIsVerifying = false
                    return
                }
                cloudVerifyError = Self.validationMessage(for: error)
            }
            if !Task.isCancelled {
                cloudIsVerifying = false
            }
        }
    }

    /// Map a validation failure to a user-facing message, distinguishing an
    /// invalid key (401/403) from a network problem (don't claim "invalid").
    private static func validationMessage(for error: Error) -> String {
        // URLSession surfaces connectivity failures as URLError (HTTPClient
        // does not wrap these), so handle them before the ProviderError cases.
        if error is URLError {
            return "Could not connect to the server. Check your network connection and try again."
        }
        guard let providerError = error as? ProviderError else {
            return "Could not verify your API key. Please try again."
        }
        switch providerError {
        // The validation request carries only the key (no body), so a
        // 400/401/403 from it means the key was rejected. Google Translate
        // returns 400 (API_KEY_INVALID); the others return 401/403.
        case .httpError(let code, _) where code == 400 || code == 401 || code == 403:
            return "Invalid API key. Please check and try again."
        case .httpError(let code, _):
            return "Could not verify your API key (HTTP \(code))."
        case .transport:
            return "Could not connect to the server. Check your network connection and try again."
        default:
            return "Could not verify your API key. Please try again."
        }
    }

    // MARK: - Action mapping

    /// Point matching actions at the verified cloud provider. AI providers
    /// update Improve / Shorten / Proofread / Prompt; translation providers
    /// update Translate only. Preserves `customPrompt` and `tone`.
    private static func pointActionsAtCloudProvider(_ provider: ProviderKind, settings: SettingsStore) {
        switch provider {
        case .openAI, .anthropic, .gemini:
            let model = provider.curatedModels.first ?? ""
            for kind in [ActionKind.improve, .shorten, .proofread, .prompt] {
                let current = settings.config(for: kind)
                if current.providerKind == provider, current.model == model {
                    continue
                }
                settings.setConfig(
                    ActionConfig(
                        id: kind,
                        providerKind: provider,
                        model: model,
                        customPrompt: current.customPrompt,
                        tone: current.tone
                    ),
                    for: kind
                )
            }
        case .deepL, .googleTranslate:
            let current = settings.config(for: .translate)
            let model = provider.curatedModels.first ?? current.model
            if current.providerKind == provider, current.model == model {
                return
            }
            settings.setConfig(
                ActionConfig(
                    id: .translate,
                    providerKind: provider,
                    model: model,
                    customPrompt: current.customPrompt,
                    tone: current.tone
                ),
                for: .translate
            )
        case .ollama, .glm, .openRouter, .custom, .claudeCLI, .codexCLI, .geminiCLI, .mlxLocal:
            break
        }
    }
}
