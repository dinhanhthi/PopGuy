// LocalModelMemoryInfoView.swift
// PopGuy — UI/SettingsWindow
//
// Slide-over panel content explaining how on-device MLX models load, use,
// and release memory. Triggered by the "Read more: how models use memory"
// link in LocalModelsView.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - LocalModelMemoryInfoView

struct LocalModelMemoryInfoView: View {

    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            scrollContent
        }
        .frame(minWidth: 480, minHeight: 520)
        // Match the ActionLibraryView baseline: extend to the panel's top edge so the
        // header's top gap stays fixed (and equal to its bottom gap) as the window resizes.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("How Models Use Memory")
                .font(.title2.weight(.semibold))
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .hoverTooltip("Close")
        }
        // Symmetric vertical padding, matching the ActionLibraryView baseline
        // so the header sits the same distance from the panel's top and bottom edges.
        .padding(.horizontal, SettingsMetrics.cardPadding)
        .padding(.vertical, SettingsMetrics.cardPadding + 6)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                infoSection(
                    symbol: "memorychip",
                    title: "What \"Needs X GB RAM\" means?"
                ) {
                    Text(
                        "The RAM figure is the recommended unified memory for that model on Apple Silicon. " +
                        "Apple Silicon shares the same memory pool between the CPU and GPU — on-device AI " +
                        "models use it directly, without a separate VRAM pool. The number is guidance for " +
                        "deciding which model suits your Mac, not a live usage counter."
                    )
                }

                infoSection(
                    symbol: "clock.arrow.circlepath",
                    title: "When a model loads — cold start?"
                ) {
                    Text(
                        "A model is not loaded when you download it or when PopGuy launches. It loads the " +
                        "first time you run an action that uses it."
                    )
                    .padding(.bottom, 4)

                    Text("That first run is a cold start:")
                        .font(.callout.weight(.medium))

                    bulletList([
                        "The multi-gigabyte weight file is read from disk into unified memory.",
                        "Metal shaders are compiled and the inference engine initialises.",
                        "This takes a few seconds for small models and longer for large ones.",
                    ])

                    Text(
                        "Once loaded, every subsequent action with the same model is warm and fast."
                    )
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }

                infoSection(
                    symbol: "1.square",
                    title: "One model at a time"
                ) {
                    Text(
                        "Only the model you are currently using occupies memory. If you run an action with a " +
                        "different model, the previous one is unloaded automatically before the new one loads. " +
                        "You will not have two models in memory simultaneously."
                    )
                }

                infoSection(
                    symbol: "internaldrive",
                    title: "Downloaded does not mean in memory"
                ) {
                    Text(
                        "Downloading several models only uses disk space — it does not consume RAM. A model " +
                        "occupies memory only while it is actually running an action."
                    )
                    .padding(.bottom, 4)

                    Text(
                        "The row of the currently-resident model shows a green \u{25CF} In memory badge so " +
                        "you always know what is loaded."
                    )
                    .foregroundStyle(.secondary)
                }

                infoSection(
                    symbol: "timer",
                    title: "Automatic release"
                ) {
                    Text(
                        "After the idle period you configure (default: 5 minutes), the model is unloaded and " +
                        "the background helper process quits, freeing all of its RAM."
                    )
                    .padding(.bottom, 4)

                    Text(
                        "Set the timer to Never to keep the model loaded between actions — useful if you run " +
                        "many actions in a session and want to avoid repeated cold starts."
                    )
                    .foregroundStyle(.secondary)
                }

                infoSection(
                    symbol: "eject",
                    title: "Manual release"
                ) {
                    Text(
                        "The Unload button next to an installed model frees it from memory immediately, " +
                        "without waiting for the idle timer. Use it any time you want to reclaim RAM right now."
                    )
                }

            }
            .padding(.horizontal, SettingsMetrics.pagePadding)
            .padding(.vertical, SettingsMetrics.pagePadding)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func infoSection(
        symbol: String,
        title: String,
        @ViewBuilder body: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                body()
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 28)
        }
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Preview

#Preview("LocalModelMemoryInfoView") {
    LocalModelMemoryInfoView(onClose: {})
        .frame(width: 480, height: 600)
}
