// LocalModelsView.swift
// PopGuy — UI/SettingsWindow
//
// SwiftUI view for managing on-device MLX models (download, delete, progress).
//
// Displayed inside the Providers tab (AI segment) as a SettingsCard at the
// bottom of the AI provider list. Shows the full LocalModelCatalog, gated by
// MLXCapability and the user's Pro status.
//
// API consumed (all from Phase 3 / Phase 4 — no new logic here):
//   - MLXCapability.isSupported / .unsupportedReason
//   - LocalModelCatalog.all
//   - SettingsStore.installedLocalModels, .localModelDownloadProgress,
//     .activeLocalModelDownloadID, .localModelDownloadError
//   - SettingsStore.availability(for:isPro:) → LocalModelAvailability
//   - SettingsStore.downloadLocalModel(_:isPro:)   (sync)
//   - SettingsStore.cancelLocalModelDownload()     (sync)
//   - SettingsStore.deleteLocalModel(_:)           (async — wrapped in Task)
//   - SettingsStore.refreshInstalledLocalModels()  (async — wrapped in Task)
//
// Isolation: @MainActor throughout — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
// SettingsStore is @MainActor ObservableObject; observed via @ObservedObject.

import SwiftUI

// MARK: - LocalModelsView

/// Full Local (MLX) model manager card: capability check, catalog list,
/// download / cancel / delete controls, and Pro-lock state.
struct LocalModelsView: View {

    @ObservedObject var settings: SettingsStore
    /// True when the user holds a Pro license or an active trial.
    let isPro: Bool
    /// Navigates to the License tab when the user taps "Get Pro" on a locked model.
    var onUpgrade: () -> Void = {}
    /// Called when the user taps "Read more: how models use memory".
    var onReadMore: () -> Void = {}

    /// Delete error message, distinct from download error.
    /// Surfaced in the same error-banner area as download errors.
    @State private var deleteError: String? = nil
    /// Model awaiting user confirmation before deletion.
    @State private var modelPendingDelete: LocalModel? = nil

    // MARK: - Body

    var body: some View {
        SettingsCard(
            title: "Local (On-Device) Models"
        ) {
            // Subtitle row with "Read more" link alongside it.
            HStack(spacing: 0) {
                Text("Run AI privately — no API key, no internet required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(" ")
                    .font(.caption)
                Button("Read more: how models use memory") {
                    onReadMore()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue.opacity(0.85))
                .hoverTooltip("Learn how on-device models load, use, and release memory")
                Spacer(minLength: 0)
            }

            if !MLXCapability.isSupported {
                unsupportedNotice
            } else {
                modelList
            }
        }
    }

    // MARK: - Unsupported notice

    /// Shown on Intel Macs or macOS 13: calm, intentional-looking notice.
    private var unsupportedNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Not available on your Mac")
                    .font(.callout)
                Text(MLXCapability.unsupportedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Model list

    private var modelList: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.contentSpacing) {
            // Show whichever error is most recent; download error takes priority
            // when both are set (a fresh download attempt clears deleteError anyway).
            if let errorMsg = settings.localModelDownloadError ?? deleteError {
                errorBanner(errorMsg)
            }

            ForEach(LocalModelCatalog.all, id: \.id) { model in
                modelRow(model)

                if model.id != LocalModelCatalog.all.last?.id {
                    Divider()
                }
            }

            Divider()

            idleTimeoutRow
        }
        .task {
            await settings.refreshInstalledLocalModels()
            await settings.refreshLoadedLocalModel()
        }
        // Periodic polling to keep the in-memory indicator current.
        .task(id: "mlx-polling") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await settings.refreshLoadedLocalModel()
            }
        }
        .alert(
            "Delete \(modelPendingDelete?.displayName ?? "model")?",
            isPresented: Binding(
                get: { modelPendingDelete != nil },
                set: { if !$0 { modelPendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let model = modelPendingDelete else { return }
                modelPendingDelete = nil
                deleteError = nil
                Task {
                    await settings.deleteLocalModel(model.id)
                    if settings.installedLocalModels.contains(model.id) {
                        deleteError = "Could not delete \(model.displayName). Check disk permissions and try again."
                    }
                    await settings.refreshLoadedLocalModel()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove the model files from your Mac. You can re-download it later.")
        }
    }

    // MARK: - Idle timeout row

    private static let idleOptions: [(label: String, seconds: Int)] = [
        ("Never", 0),
        ("1 min", 60),
        ("2 min", 120),
        ("5 min", 300),
        ("10 min", 600),
        ("30 min", 1800),
    ]

    private var idleTimeoutDisplayLabel: String {
        Self.idleOptions.first { $0.seconds == settings.localModelIdleSeconds }?.label ?? "5 min"
    }

    private var idleTimeoutRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Keep models in memory for:")
                    .font(.callout)

                Picker("", selection: $settings.localModelIdleSeconds) {
                    ForEach(Self.idleOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            Text("Idle models are unloaded and the background engine quits to free memory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Error banner

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

    // MARK: - Model row

    @ViewBuilder
    private func modelRow(_ model: LocalModel) -> some View {
        let availability = settings.availability(for: model, isPro: isPro)
        let isDownloading = settings.activeLocalModelDownloadID == model.id
        let isInstalled = settings.installedLocalModels.contains(model.id)
        let isInMemory = settings.loadedLocalModelID == model.id

        HStack(spacing: 10) {
            // Left: name + metadata
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.callout)
                        .lineLimit(1)

                    if !model.isFreeTier && !isPro {
                        ProBadge()
                            .hoverTooltip("Requires a Pro license")
                    }

                    // "In memory" indicator — shown when this model is currently
                    // loaded in the helper process and consuming RAM.
                    if isInMemory {
                        HStack(spacing: 3) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.green)
                            Text("In memory")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        .hoverTooltip("Loaded in memory and ready to use")
                    }
                }

                HStack(spacing: 10) {
                    Label(
                        formatBytes(model.approxSizeBytes),
                        systemImage: "internaldrive"
                    )
                    Label(
                        "needs \(formatRAM(model.minRAMBytes))",
                        systemImage: "memorychip"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 8)

            // Right: state-dependent control
            trailingControl(model: model, availability: availability, isDownloading: isDownloading, isInstalled: isInstalled, isInMemory: isInMemory)
        }

        // Progress indicator — shown below the row while this model downloads.
        // The helper streams a monotonic fraction (0–1) via the disk sampler and
        // Foundation progress. Show a determinate % bar when fraction > 0; fall
        // back to indeterminate "Preparing…" during the brief warm-up before the
        // total size is known.
        if isDownloading {
            downloadProgress(
                name: model.displayName,
                fraction: settings.localModelDownloadProgress[model.id]
            )
        }
    }

    // MARK: - Trailing control

    @ViewBuilder
    private func trailingControl(
        model: LocalModel,
        availability: LocalModelAvailability,
        isDownloading: Bool,
        isInstalled: Bool,
        isInMemory: Bool
    ) -> some View {
        switch availability {
        case .unsupported:
            // Should not reach here (whole list is hidden), but guard anyway.
            EmptyView()

        case .proLocked:
            // Pro-locked model.
            //
            // Delete is ALWAYS allowed when a model is already on disk — the user
            // must be able to reclaim space even after downgrading from Pro.
            //
            // Download/use stays gated behind the upgrade flow.
            if isInstalled {
                HStack(spacing: 8) {
                    // Lock badge signals the model can't be re-downloaded without Pro.
                    Button {
                        onUpgrade()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                            Text("Pro")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.proGold)
                    .hoverTooltip("Requires Pro to download or use. Tap to upgrade.")

                    deleteButton(for: model)
                }
            } else {
                // Not installed: upgrade button only.
                Button {
                    onUpgrade()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                        Text("Pro")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.proGold)
                .hoverTooltip("This model requires a Pro license. Tap to upgrade.")
            }

        case .available:
            if isDownloading {
                // Downloading: progress is shown below the row; Cancel button here.
                Button("Cancel") {
                    settings.cancelLocalModelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverTooltip("Cancel the download")

            } else if isInstalled {
                // Installed: indicator + optional Unload + Delete button
                HStack(spacing: 8) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)

                    if isInMemory {
                        Button("Unload") {
                            Task {
                                await settings.unloadLoadedLocalModel()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .hoverTooltip("Free this model's memory now")
                    }

                    deleteButton(for: model)
                }

            } else {
                // Not installed, not downloading: Download button
                let anyDownloadActive = settings.activeLocalModelDownloadID != nil
                Button("Download") {
                    deleteError = nil
                    settings.downloadLocalModel(model.id, isPro: isPro)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(anyDownloadActive)
                .hoverTooltip(anyDownloadActive
                    ? "Another model is downloading — wait for it to finish"
                    : "Download \(model.displayName)")
            }
        }
    }

    // MARK: - Download progress

    /// Only call with developer-controlled display name strings from `LocalModelCatalog`.
    /// Always shows an indeterminate animated bar so the user sees activity even when
    /// large files download via Xet (which streams to a system temp path before moving
    /// to the cache, giving no incremental on-disk progress). The percentage text shows
    /// the best-known fraction when one is available.
    fileprivate func downloadProgress(name: String, fraction: Double?) -> some View {
        let clamped = fraction.map { min(max($0, 0), 1) } ?? 0
        let label = clamped > 0
            ? "Downloading \(name)… \(Int((clamped * 100).rounded()))%"
            : "Preparing \(name)…"
        return VStack(alignment: .leading, spacing: 3) {
            ProgressView()
                .progressViewStyle(.linear)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Delete button

    /// Shared delete button used by both `.available` and `.proLocked` installed states.
    @ViewBuilder
    private func deleteButton(for model: LocalModel) -> some View {
        Button("Delete") {
            modelPendingDelete = model
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .hoverTooltip("Remove this model from disk")
    }

    // MARK: - Byte formatters

    /// Formats a byte count as a compact human-readable size (e.g. "1 GB", "2.2 GB").
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: bytes)
    }

    /// Formats a RAM byte count as a rounded GB value for the needs-RAM hint.
    /// All current catalog entries require ≥ 4 GB, so this always returns a GB string.
    private func formatRAM(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0  // 1024^3
        let rounded = Int(gb.rounded())
        return "\(rounded) GB RAM"
    }
}

// MARK: - Preview

#Preview("LocalModelsView — supported Mac, Pro") {
    ScrollView {
        LocalModelsView(
            settings: SettingsStore(),
            isPro: true,
            onUpgrade: {}
        )
        .padding()
    }
    .frame(width: 520)
}

#Preview("LocalModelsView — supported Mac, Free") {
    ScrollView {
        LocalModelsView(
            settings: SettingsStore(),
            isPro: false,
            onUpgrade: {}
        )
        .padding()
    }
    .frame(width: 520)
}

#Preview("downloadProgress — determinate 42%") {
    let view = LocalModelsView(settings: SettingsStore(), isPro: true)
    return view.downloadProgress(name: "Gemma 4 E2B", fraction: 0.42)
        .frame(width: 420)
        .padding()
}
