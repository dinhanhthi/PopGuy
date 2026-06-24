// ToolbarView.swift
// PopGuy
//
// SwiftUI view hosted inside FloatingPanel via NSHostingView.
//
// Layout: compact pill-shaped card with two action buttons (Improve, Translate)
// and an inline target-language Picker next to Translate.
// When an action is running/complete an expandable result area appears below.
//
// Phase 3 wires ActionEngine via the `ToolbarActionHandling` protocol seam on
// the view model — this file does NOT need to change in Phase 3.
//
// OutputHandler is injected at construction time (owned by ToolbarController).

import AppKit
import SwiftUI

// MARK: - ResultFontSize → Font

extension ResultFontSize {
    /// SwiftUI font for the toolbar result body. `normal` uses the headline
    /// size at regular weight, so the body reads at headline scale without the
    /// semibold emphasis.
    var font: Font {
        switch self {
        case .small:  return .subheadline
        case .normal: return .headline.weight(.regular)
        case .big:    return .title2.weight(.regular)
        }
    }

    /// AppKit equivalent of `font`, used by the edit-mode NSTextView. Mirrors the
    /// SwiftUI sizes: subheadline / headline-size (regular weight) / title2-size.
    var nsFont: NSFont {
        switch self {
        case .small:  return NSFont.preferredFont(forTextStyle: .subheadline)
        case .normal: return NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize)
        case .big:    return NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize)
        }
    }

    /// Point size for each size class, taken from the matching text style.
    /// Used to derive zoom-scaled fonts that keep the same visual proportions.
    var basePointSize: CGFloat {
        switch self {
        case .small:  return NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        case .normal: return NSFont.preferredFont(forTextStyle: .headline).pointSize
        case .big:    return NSFont.preferredFont(forTextStyle: .title2).pointSize
        }
    }

    /// SwiftUI font scaled by `scale`. `scale == 1` matches `font` visually
    /// (same point size, regular weight).
    func font(scale: CGFloat) -> Font {
        .system(size: basePointSize * scale).weight(.regular)
    }

    /// AppKit font scaled by `scale`, mirroring `font(scale:)`.
    func nsFont(scale: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: basePointSize * scale)
    }
}

// MARK: - Metrics

/// Shared metrics for the toolbar. Spacing follows a 4pt base scale, and the
/// control corner radius derives from the card radius minus the card padding
/// so nested rounded rects stay concentric.
///
/// Dimensional properties are instance vars that scale by `zoom`; non-dimensional
/// constants (opacities, animations, delays) remain static so sibling structs
/// can reference them without needing a metrics instance.
private struct ToolbarMetrics {
    let zoom: CGFloat

    // MARK: Dimensional (instance — scale with zoom)
    var controlHeight: CGFloat { 26 * zoom }
    var cardRadius: CGFloat    { 10 * zoom }
    var cardPadding: CGFloat   { 4  * zoom }
    var controlRadius: CGFloat { cardRadius - cardPadding }
    var groupSpacing: CGFloat  { 4  * zoom }
    var dividerHeight: CGFloat { 16 * zoom }

    // MARK: Non-dimensional (static — no scaling)
    static let hoverOpacity: Double = 0.07
    static let pressedOpacity: Double = 0.12
    static let hoverAnimation: Animation = .easeOut(duration: 0.12)
    /// Delay before a hover tooltip becomes visible (~120 ms feels instant but avoids
    /// flicker when the cursor just passes through).
    static let tooltipDelay: UInt64 = 120_000_000 // nanoseconds
}

// MARK: - ToolbarControlStyle

/// Unified hover/pressed treatment for every interactive control in the bar:
/// a soft `primary` wash on hover, slightly stronger while pressed, with one
/// shared micro-animation so all controls respond identically.
private struct ToolbarControlStyle: ButtonStyle {
    let controlRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, controlRadius: controlRadius)
    }

    /// `@State` must live in a real View (a ButtonStyle is not installed in
    /// the hierarchy), hence this inner wrapper.
    private struct StyledBody: View {
        let configuration: Configuration
        let controlRadius: CGFloat
        @State private var isHovered = false

        var body: some View {
            let opacity: Double = configuration.isPressed
                ? ToolbarMetrics.pressedOpacity
                : (isHovered ? ToolbarMetrics.hoverOpacity : 0)

            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
                        .fill(Color.primary.opacity(opacity))
                )
                .contentShape(RoundedRectangle(cornerRadius: controlRadius, style: .continuous))
                .animation(ToolbarMetrics.hoverAnimation, value: isHovered)
                .animation(ToolbarMetrics.hoverAnimation, value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - ToolbarView

struct ToolbarView: View {

    @ObservedObject var viewModel: ToolbarViewModel

    /// Injected OutputHandler for Copy + Paste-back in the result state.
    let outputHandler: OutputHandler

    /// Reports the view's measured size to the controller so it can resize and
    /// reposition the hosting panel as the body expands/contracts.
    let onContentResize: (CGSize) -> Void

    /// Called when the user taps the Settings button — opens the Settings window and dismisses.
    let onOpenSettings: () -> Void

    /// Called when the user taps Ignore this App — adds the source app to the ignored list and dismisses.
    let onIgnoreApp: () -> Void

    /// Called when the user taps Ignore this site — adds the source domain to the ignored list and dismisses.
    let onIgnoreDomain: () -> Void

    /// Dismisses the toolbar. Used after a paste-back completes and to confirm
    /// closing while an action is still running.
    let onDismiss: () -> Void

    /// Turns off the "confirm before closing a finished result" setting, then
    /// dismisses. Lets the user opt out of this prompt without opening Settings.
    let onDisableCloseConfirmation: () -> Void

    /// Asks the controller to make the floating panel key so the prompt TextField
    /// can receive keystrokes (the panel is non-activating). Called when the prompt
    /// input area opens.
    let onActivatePromptInput: () -> Void

    /// Tracks whether a paste-back is in-flight; disables the button while true.
    @State private var isPastingBack = false

    /// Briefly true after the Copy button is tapped, showing a checkmark confirmation.
    @State private var copyConfirmed = false

    /// Gates the destructive "ignore this app" action behind user confirmation.
    @State private var isShowingIgnoreConfirmation = false

    /// Drives the overflow (burger) action menu popover.
    @State private var isBurgerOpen = false

    @FocusState private var promptFieldFocused: Bool

    /// Measured width of the action bar. The card's width is driven by this row
    /// (the widest one), so the result body below uses it to fill the full card
    /// width instead of a narrower fixed width. Measured via GeometryReader +
    /// onChange (not a PreferenceKey) because preference updates do not fire under
    /// the panel's intrinsic-sizing hosting view.
    @State private var actionBarWidth: CGFloat = 0

    // MARK: - Zoom helpers

    /// Current zoom scalar from the view model.
    private var zoom: CGFloat { viewModel.toolbarZoom.scale }

    /// Metrics instance carrying the current zoom.
    private var metrics: ToolbarMetrics { ToolbarMetrics(zoom: zoom) }

    /// 1 when the font is excluded from the zoom; otherwise rides the zoom.
    private var effectiveFontScale: CGFloat { viewModel.includeFontInZoom ? zoom : 1 }

    /// Scales a raw layout literal by the current zoom.
    private func z(_ v: CGFloat) -> CGFloat { v * zoom }

    /// Chrome font (action bar, captions, footers) scaled by the zoom.
    /// Derived from the system text style's point size (AppKit), scaled by
    /// the current zoom, so it tracks the system text size rather than a
    /// hardcoded point size.
    private func chromeFont(_ style: NSFont.TextStyle) -> Font {
        .system(size: NSFont.preferredFont(forTextStyle: style).pointSize * zoom)
    }

    /// AppKit font matching `chromeFont(_:)`, used where AppKit-backed text is
    /// needed for native selection inside the floating panel.
    private func chromeNSFont(_ style: NSFont.TextStyle) -> NSFont {
        NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize * zoom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
                .zIndex(1)
            if viewModel.isPromptInputActive {
                Divider().padding(.horizontal, z(8))
                promptInputArea
            }
            if case .idle = viewModel.actionState { } else if !viewModel.suppressRunningPanel {
                Divider().padding(.horizontal, z(8))
                resultArea
            }
            if (viewModel.speakPhase != .idle || viewModel.canReplaySpeak) && !viewModel.isDictionaryAction {
                Divider().padding(.horizontal, z(8))
                speakArea
            }
        }
        .background(
            RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
        )
        // Hairline edge so the material card stays defined on light backgrounds
        // (mimics the standard macOS floating-panel border).
        .overlay(
            RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        // Transparent space around the card: sides/top give the shadow room to
        // draw (the panel itself has no window shadow); the larger bottom inset
        // additionally hosts the utility tooltips, which are overlay content
        // and would otherwise be clipped by the hosting panel.
        .padding(.top, z(8))
        .padding(.horizontal, z(12))
        .padding(.bottom, z(24))
        .fixedSize()
        // Measure the laid-out size and forward it to the controller. A single
        // background GeometryReader + PreferenceKey works on macOS 13
        // (.onGeometryChange is 14+).
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ToolbarSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ToolbarSizeKey.self) { size in
            onContentResize(size)
        }
        .confirmationDialog(
            "Ignore this app?",
            isPresented: $isShowingIgnoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Ignore App", role: .destructive, action: onIgnoreApp)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PopGuy will stop showing the toolbar in this app. You can re-enable it in Settings.")
        }
        .confirmationDialog(
            "Close without using the result?",
            isPresented: $viewModel.isShowingCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Close Anyway", role: .destructive, action: onDismiss)
            Button("Turn This Setting Off", action: onDisableCloseConfirmation)
            Button("Keep Open", role: .cancel) {}
        } message: {
            Text("Use Copy or Paste back to keep the result, or close anyway.")
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: metrics.groupSpacing) {
            // Brand mark — decorative, spans the full control height so
            // it reads at the same visual weight as the action buttons.
            Image("ToolbarLogo")
                .resizable()
                .scaledToFit()
                .frame(width: metrics.controlHeight, height: metrics.controlHeight)
                .accessibilityHidden(true)

            // Ordered action buttons — one divider between consecutive actions;
            // none before the first. Bookends (logo, utilities) are outside this loop.
            ForEach(Array(viewModel.orderedActions.enumerated()), id: \.element) { index, id in
                if index > 0 {
                    toolbarDivider
                }
                actionControl(for: id)
            }

            if viewModel.hasOverflow {
                if !viewModel.orderedActions.isEmpty {
                    toolbarDivider
                }
                burgerButton
            }

            // Push the utility group (Ignore this App, Settings) to the trailing
            // edge, leaving a clear gap between it and the action buttons. Under
            // the root `.fixedSize()` this Spacer only has slack to expand because
            // the action bar is floored to `minResultWidth` below.
            Spacer(minLength: z(16))

            if viewModel.sourceDomain != nil {
                ToolbarUtilityButton(
                    systemName: "nosign",
                    tooltip: "Ignore this site",
                    controlHeight: metrics.controlHeight,
                    controlRadius: metrics.controlRadius,
                    zoom: zoom,
                    action: onIgnoreDomain
                )
            }

            ToolbarUtilityButton(
                systemName: "eye.slash",
                tooltip: "Ignore this app",
                controlHeight: metrics.controlHeight,
                controlRadius: metrics.controlRadius,
                zoom: zoom,
                action: { isShowingIgnoreConfirmation = true }
            )
            .opacity(viewModel.sourceBundleID == nil ? 0.4 : 1.0)
            .disabled(viewModel.sourceBundleID == nil)

            ToolbarUtilityButton(
                systemName: "gear",
                tooltip: "Settings",
                controlHeight: metrics.controlHeight,
                controlRadius: metrics.controlRadius,
                zoom: zoom,
                action: onOpenSettings
            )
        }
        .padding(metrics.cardPadding)
        // Floor the bar to the same minimum the result body uses, so the trailing
        // Spacer has slack to push the utility group to the right edge even when
        // few actions are active. When many actions make the row naturally wider,
        // this is a no-op and the row keeps its intrinsic width.
        .frame(minWidth: minResultWidth, alignment: .leading)
        // Measure this row's width: it's the widest one and sets the card width,
        // so the result body can match it (see `resultWidth`). We set the @State
        // directly from the GeometryReader (onAppear + onChange) rather than via a
        // PreferenceKey: under this panel's intrinsic-sizing hosting view the
        // preference→onPreferenceChange path never fires, leaving the width at the
        // fallback and the result body narrower than the card.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { actionBarWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { actionBarWidth = $0 }
            }
        )
    }

    /// Renders the appropriate control for a given action identifier.
    @ViewBuilder
    private func actionControl(for id: ActionIdentifier, forceLabeled: Bool = false) -> some View {
        let compact = forceLabeled ? false : viewModel.compactActions
        switch id {
        case .builtin(.improve):
            ToolbarActionButton(
                symbolName: "wand.and.stars",
                label: "Improve",
                isRunning: isRunning(.improve),
                isDisabled: isActionRunning,
                compact: compact,
                zoom: zoom,
                controlHeight: metrics.controlHeight,
                controlRadius: metrics.controlRadius,
                action: { viewModel.triggerImprove() }
            )
        case .builtin(.shorten):
            ToolbarActionButton(
                symbolName: "text.badge.minus",
                label: "Shorten",
                isRunning: isRunning(.shorten),
                isDisabled: isActionRunning,
                compact: compact,
                zoom: zoom,
                controlHeight: metrics.controlHeight,
                controlRadius: metrics.controlRadius,
                action: { viewModel.triggerShorten() }
            )
        case .builtin(.proofread):
            ToolbarActionButton(
                symbolName: "checkmark.bubble",
                label: "Proofread",
                isRunning: isRunning(.proofread),
                isDisabled: isActionRunning,
                compact: compact,
                zoom: zoom,
                controlHeight: metrics.controlHeight,
                controlRadius: metrics.controlRadius,
                action: { viewModel.triggerProofread() }
            )
        case .builtin(.prompt):
            ToolbarActionButton(
                symbolName: "bubble.and.pencil",
                label: "Prompt",
                isRunning: isRunning(.prompt),
                isDisabled: isActionRunning,
                compact: compact,
                zoom: zoom,
                controlHeight: metrics.controlHeight,
                controlRadius: metrics.controlRadius,
                action: {
                    viewModel.triggerPromptInput()
                    onActivatePromptInput()
                }
            )
        case .builtin(.translate):
            // Translate button + language picker. Avoid .disabled() on the picker:
            // it drops the borderless menu's emphasized title weight, changing "vi"
            // width and shifting the toolbar. Dim + block hits instead.
            HStack(spacing: z(2)) {
                ToolbarActionButton(
                    symbolName: "character.bubble",
                    label: "Translate",
                    isRunning: isRunning(.translate),
                    isDisabled: isActionRunning,
                    compact: compact,
                    zoom: zoom,
                    controlHeight: metrics.controlHeight,
                    controlRadius: metrics.controlRadius,
                    action: { viewModel.triggerTranslate() }
                )
                LanguagePicker(
                    selection: $viewModel.targetLanguage,
                    controlHeight: metrics.controlHeight,
                    controlRadius: metrics.controlRadius,
                    zoom: zoom
                )
                .opacity(isActionRunning ? 0.5 : 1)
                .allowsHitTesting(!isActionRunning)
            }
        case .dictionary:
            HStack(spacing: z(2)) {
                ToolbarActionButton(
                    symbolName: "character.book.closed",
                    label: "Look up",
                    isRunning: viewModel.isDictionaryAction && isActionRunning,
                    // Block while any action runs — including this lookup itself — so a
                    // repeated click can't cancel and restart the in-flight lookup.
                    isDisabled: isActionRunning,
                    compact: compact,
                    zoom: zoom,
                    controlHeight: metrics.controlHeight,
                    controlRadius: metrics.controlRadius,
                    action: { viewModel.triggerDictionary() }
                )
                LanguagePicker(
                    selection: $viewModel.dictionaryTargetLanguage,
                    controlHeight: metrics.controlHeight,
                    controlRadius: metrics.controlRadius,
                    zoom: zoom,
                    onPick: { _ in viewModel.triggerDictionary() }
                )
                .opacity(isActionRunning ? 0.5 : 1)
                .allowsHitTesting(!isActionRunning)
            }
        case .speak:
            // Speak is orthogonal to text actions: isDisabled is always false
            // (Stop must be pressable regardless of isActionRunning). isRunning
            // reflects .loading so the built-in spinner gives instant feedback.
            // Symbol and label are phase-driven: idle shows the wave icon / "Speak";
            // loading and playing show stop / "Stop".
            HStack(spacing: z(2)) {
                ToolbarActionButton(
                    symbolName: viewModel.speakPhase == .playing ? "stop.fill" : "speaker.wave.2",
                    label: viewModel.speakPhase == .idle ? "Speak" : "Stop",
                    isRunning: viewModel.speakPhase == .loading,
                    isDisabled: false,
                    compact: compact,
                    zoom: zoom,
                    controlHeight: metrics.controlHeight,
                    controlRadius: metrics.controlRadius,
                    action: { viewModel.triggerSpeak(accent: nil) }
                )
                // Hide the accent picker for engines that auto-detect the
                // language from the text (e.g. OpenAI) — the selection has no
                // effect there, so showing it would only mislead.
                if viewModel.speakSettings.selectedEngine.usesLanguageSelection {
                    AccentPicker(
                        selection: $viewModel.selectedSpeakAccent,
                        controlHeight: metrics.controlHeight,
                        controlRadius: metrics.controlRadius,
                        zoom: zoom,
                        onPick: { accent in viewModel.triggerSpeak(accent: accent) }
                    )
                }
            }
        case .custom(let uuid):
            if let action = viewModel.customActions.first(where: { $0.id == uuid }) {
                if action.type == .speech {
                    // Speech custom actions: play/stop toggle, orthogonal to the
                    // text-result state machine. Mirrors the built-in Speak button's
                    // running/disabled treatment — Stop must be pressable at all times.
                    ToolbarActionButton(
                        icon: action.icon,
                        label: viewModel.speakPhase == .idle ? action.title : "Stop",
                        isRunning: viewModel.speakPhase == .loading,
                        isDisabled: false,
                        compact: compact,
                        zoom: zoom,
                        controlHeight: metrics.controlHeight,
                        controlRadius: metrics.controlRadius,
                        action: { viewModel.triggerCustomAction(action) }
                    )
                } else {
                    // All non-speech custom actions (AI, translation, dictionary, and the
                    // four scriptable types: .openURL, .runShortcut, .appleScript,
                    // .shellScript) render as a standard button with a per-button spinner.
                    // Scriptable types use ScriptActionEngine; result state is managed by
                    // triggerCustomAction → finishWith/reset, so the result panel appears
                    // only when actionState == .result (i.e. afterRun == .showResult) and
                    // is suppressed for .none/.copyResult/.pasteResult (actionState → .idle).
                    ToolbarActionButton(
                        icon: action.icon,
                        label: action.title,
                        isRunning: isActionRunning && viewModel.activeCustomActionID == action.id,
                        isDisabled: isActionRunning,
                        compact: compact,
                        zoom: zoom,
                        controlHeight: metrics.controlHeight,
                        controlRadius: metrics.controlRadius,
                        action: { viewModel.triggerCustomAction(action) }
                    )
                }
            } else {
                EmptyView()
            }
        }
    }

    /// Overflow (burger) menu button and popover listing extra actions.
    private var burgerButton: some View {
        Button {
            isBurgerOpen.toggle()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * zoom, weight: .medium))
                .frame(width: metrics.controlHeight, height: metrics.controlHeight)
        }
        .buttonStyle(ToolbarControlStyle(controlRadius: metrics.controlRadius))
        .toolbarTooltip("More actions", controlRadius: metrics.controlRadius)
        .popover(isPresented: $isBurgerOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: metrics.groupSpacing) {
                ForEach(viewModel.overflowActions, id: \.self) { id in
                    actionControl(for: id, forceLabeled: true)
                }
            }
            .padding(metrics.cardPadding * 2)
            .onChange(of: viewModel.actionState) { state in
                if case .running = state { isBurgerOpen = false }
            }
            .onChange(of: viewModel.speakPhase) { phase in
                if phase != .idle { isBurgerOpen = false }
            }
            .onChange(of: viewModel.isPromptInputActive) { active in
                if active { isBurgerOpen = false }
            }
        }
    }

    /// Consistent group separator — one height everywhere, with a little
    /// horizontal breathing room.
    private var toolbarDivider: some View {
        Divider()
            .frame(height: metrics.dividerHeight)
            .padding(.horizontal, z(2))
    }

    // MARK: - Running helpers

    /// True while any action is executing. Drives the disabled state shared by
    /// every action button so a second action can't be started mid-run.
    private var isActionRunning: Bool {
        if case .running = viewModel.actionState { return true }
        return false
    }

    /// True only for the built-in action currently executing — used to show the
    /// spinner on just that button, not on every button.
    private func isRunning(_ kind: ActionKind) -> Bool {
        isActionRunning && viewModel.activeActionKind == kind
    }

    // MARK: - Result / error area

    @ViewBuilder
    private var resultArea: some View {
        switch viewModel.actionState {
        case .idle:
            EmptyView()

        case .running(let progress):
            // Streamed output is always shown as plain text (never Markdown-rendered)
            // because mid-stream content is incomplete — unclosed `**`, partial list
            // items — making it unsafe to parse. Full Markdown rendering happens only
            // on the final `.result` state once the complete response is available.
            VStack(alignment: .leading, spacing: z(8)) {
                if progress.isEmpty {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    scrollableResultBody {
                        resultText(progress)
                            .padding(.trailing, resultContentTrailing)
                    }
                }
            }
            .padding(resultPaddingNoTrailing)
            .frame(width: resultWidth, alignment: .leading)

        case .result:
            // Edit affordance applies only to non-diff results (Translate, Shorten,
            // custom). Improve and Proofread render DiffView and must not get an
            // Edit button.
            VStack(alignment: .leading, spacing: z(8)) {
                if viewModel.isDictionaryAction {
                    if viewModel.isDictionaryNotFound {
                        Text("No definition found")
                            .font(chromeFont(.callout))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, z(24))
                     } else if let entry = viewModel.dictionaryEntry {
                        VStack(alignment: .leading, spacing: z(8)) {
                            if viewModel.dictionaryEntries.count > 1 {
                                dictionaryProviderTabs
                            }
                            DictionaryEntryView(entry: entry)
                        }
                    }
                } else if !viewModel.isResultEditable {
                    scrollableResultBody {
                        DiffView(segments: viewModel.diffSegments, font: viewModel.resultFontSize.font(scale: effectiveFontScale))
                            .padding(.trailing, resultContentTrailing)
                    }
                } else if viewModel.isEditing {
                    // Edit mode opens a taller area than the read view for comfort.
                    // Mirror the read path: a SwiftUI ScrollView (overlay scrollbar,
                    // no reserved gutter) wrapping a self-sizing NSTextView that
                    // wraps to the width SwiftUI hands it. The text container width
                    // is set from the view's own bounds in `layout()` — that fires
                    // when SwiftUI sizes the view, unlike AppKit width-tracking.
                    ScrollView(.vertical) {
                        FullWidthTextEditor(text: $viewModel.editedResult, font: viewModel.resultFontSize.nsFont(scale: effectiveFontScale))
                            .frame(width: editorContentWidth, alignment: .topLeading)
                            .frame(minHeight: editMinHeight, alignment: .topLeading)
                    }
                    .frame(maxHeight: editMaxHeight)
                } else if viewModel.preserveFormatting {
                    scrollableResultBody {
                        MarkdownResultView(source: viewModel.displayedResult, font: viewModel.resultFontSize.font(scale: effectiveFontScale))
                            .padding(.trailing, resultContentTrailing)
                    }
                } else {
                    scrollableResultBody {
                        resultText(viewModel.displayedResult)
                            .padding(.trailing, resultContentTrailing)
                    }
                }
                resultButtons(
                    effective: currentResultEffectiveText,
                    isEditable: viewModel.isResultEditable,
                    hideCopy: viewModel.isDictionaryAction,
                    hidePasteBack: viewModel.isDictionaryAction,
                    isDictionary: viewModel.isDictionaryAction && hasSelectedDictionaryEntry,
                    onDictionaryListen: viewModel.isDictionaryAction && hasSelectedDictionaryEntry
                        ? { viewModel.triggerDictionaryListen() }
                        : nil,
                    speakPhase: viewModel.speakPhase,
                    canReplaySpeak: viewModel.canReplaySpeak
                )
                    .padding(.top, (viewModel.isDictionaryAction && hasSelectedDictionaryEntry) ? 0 : footerTopPadding)
            }
            .padding(resultPaddingNoTrailing)
            .frame(width: resultWidth, alignment: .leading)

        case .error(let message):
            HStack(alignment: .top, spacing: z(6)) {
                Image(systemName: "exclamationmark.triangle")
                    .font(chromeFont(.caption1))
                    .foregroundStyle(.red)
                SelectableToolbarErrorText(
                    message: message,
                    font: chromeNSFont(.caption1),
                    textColor: .systemRed
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }
            .padding(resultPadding)
            .frame(width: resultWidth, alignment: .leading)
        }
    }

    private var currentResultEffectiveText: String {
        guard viewModel.isDictionaryAction else {
            return viewModel.displayedResult
        }
        guard let entry = viewModel.selectedDictionaryResult?.entry else {
            return viewModel.displayedResult
        }
        return DictionaryEntryView.readableText(for: entry)
    }

    private var hasSelectedDictionaryEntry: Bool {
        viewModel.selectedDictionaryResult != nil
    }

    private var dictionaryProviderTabs: some View {
        Picker(
            "",
            selection: Binding<DictionaryProviderKind>(
                get: {
                    viewModel.selectedDictionaryProvider
                        ?? viewModel.dictionaryEntries.first?.providerKind
                        ?? .macOSBuiltin
                },
                set: { provider in
                    Task { @MainActor in
                        viewModel.selectDictionaryProvider(provider)
                    }
                }
            )
        ) {
            ForEach(viewModel.dictionaryEntries) { result in
                Text(result.providerKind.shortName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tag(result.providerKind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: resultWidth)
        .clipped()
    }

    /// Aligns result content with the action-button labels above it
    /// (card padding 4 + button horizontal padding 8 = 12). Used by the error
    /// state, which has no scroll view.
    private var resultPadding: EdgeInsets {
        EdgeInsets(top: z(14), leading: z(12), bottom: z(14), trailing: z(12))
    }

    /// Same as `resultPadding` but with no trailing inset, so the ScrollView
    /// reaches the card's right edge and its overlay scrollbar sits flush there.
    /// The trailing breathing room is reapplied inside the scroll content via
    /// `resultContentTrailing` so text/diff never sits under the scrollbar.
    private var resultPaddingNoTrailing: EdgeInsets {
        EdgeInsets(top: z(14), leading: z(12), bottom: z(14), trailing: 0)
    }

    /// Trailing inset applied to the scrolled content (text/diff) so it keeps a
    /// gap from the scrollbar (or, when no scrollbar, from the card's right edge).
    private var resultContentTrailing: CGFloat { z(12) }

    /// Extra space above the footer button row, on top of the VStack spacing.
    private var footerTopPadding: CGFloat { z(8) }

    /// Content width for the result body, matched to the card's content width so
    /// the body fills it (no right-edge gap). A concrete width — not `maxWidth` —
    /// lets multi-line Text wrap deterministically under the root `.fixedSize()`.
    ///
    /// Matches the measured action bar width (the widest row, which sets the card
    /// width), but never narrower than `minResultWidth` so the body stays a
    /// comfortable reading width even when few actions are active and the action
    /// bar is short. When the floor applies, the wider body widens the whole card
    /// (the VStack sizes to its widest child).
    private var resultWidth: CGFloat { max(actionBarWidth, minResultWidth) }

    /// Minimum content width for the result/prompt/speak body, so a short action
    /// bar doesn't force text to wrap in a cramped column.
    private var minResultWidth: CGFloat { z(340) }

    /// Explicit width for the edit-mode editor (an NSViewRepresentable, which does
    /// not expand to `maxWidth: .infinity` the way a native Text does). Matches the
    /// read text region: full body minus the leading inset and trailing breathing room.
    private var editorContentWidth: CGFloat {
        max(0, resultWidth - resultPaddingNoTrailing.leading - resultContentTrailing)
    }

    /// Height cap for the result body. Under the root `.fixedSize()` the panel
    /// grows with content up to this cap; longer output scrolls instead.
    private var resultMaxHeight: CGFloat { z(280) }

    /// Edit mode opens a larger editing area than the read view: a taller resting
    /// height plus a higher cap, so editing longer results is comfortable.
    private var editMinHeight: CGFloat { z(140) }
    private var editMaxHeight: CGFloat { z(240) }

    private func scrollableResultBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.vertical) {
            content()
        }
        .frame(maxHeight: resultMaxHeight)
    }

    private func resultText(_ text: String) -> some View {
        // Treat all external content as plain text — never render as markup.
        Text(text)
            .font(viewModel.resultFontSize.font(scale: effectiveFontScale))
            .textSelection(.enabled)
            .lineLimit(nil)
            // Wrap to the fixed result width and grow vertically. Without this,
            // root `.fixedSize()` would force a single overflowing line.
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Speak area

    @ViewBuilder
    private var speakArea: some View {
        VStack(alignment: .leading, spacing: z(6)) {
            switch viewModel.speakPhase {
            case .loading:
                HStack(spacing: z(8)) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("Loading…")
                        .font(chromeFont(.callout))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            case .playing:
                HStack(spacing: z(8)) {
                    SpeakWaveView(zoom: zoom)
                    Text("Speaking…")
                        .font(chromeFont(.callout))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            case .idle:
                // Playback finished: keep the spoken text + a re-listen button so
                // the user can replay the cached audio without a new request.
                if let spoken = viewModel.lastSpokenText {
                    scrollableResultBody {
                        resultText(spoken)
                            .padding(.trailing, resultContentTrailing)
                    }
                    if viewModel.canReplaySpeak {
                        Button { viewModel.replaySpeak() } label: {
                            Label("Listen again", systemImage: "speaker.wave.2")
                                .font(footerButtonFont)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, z(2))
                    }
                }
            }

            if viewModel.speakFellBack {
                Label {
                    Text("Cloud voice unavailable — using the System voice.")
                        .font(chromeFont(.caption1))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(chromeFont(.caption1))
                }
            }
        }
        .padding(resultPaddingNoTrailing)
        .frame(width: resultWidth, alignment: .leading)
    }

    // MARK: - Prompt input area

    /// Inline editor for the on-the-fly Prompt action. The selected text is applied
    /// via the {{text}} placeholder — implicitly when omitted, verbatim when present.
    @ViewBuilder
    private var promptInputArea: some View {
        VStack(alignment: .leading, spacing: z(6)) {
            TextField("Type a prompt for the selected text…", text: $viewModel.promptDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: NSFont.systemFontSize * zoom))
                .lineLimit(1...4)
                .focused($promptFieldFocused)
                .onSubmit { viewModel.runPrompt() }

            Text("Use {{text}} for the selected text — added automatically if omitted.")
                .font(chromeFont(.caption1))
                .foregroundStyle(.secondary)

            // Footer button row, below the hint — left-aligned, Run then Cancel.
            HStack(spacing: z(8)) {
                Button { viewModel.runPrompt() } label: {
                    Text("Run").font(footerButtonFont)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // Explicit dismiss — closes the toolbar immediately, bypassing the
                // prevent-close guard (that guard only stops accidental outside-click /
                // Escape, not a deliberate Cancel tap).
                Button { onDismiss() } label: {
                    Text("Cancel").font(footerButtonFont)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
        // Full padding (incl. trailing) — unlike the result area there is no
        // overlay scrollbar here, so the field/Run button need a right inset.
        .padding(resultPadding)
        .frame(width: resultWidth, alignment: .leading)
        // Defer one runloop tick: the panel is made key (makeKeyAndOrderFront) in
        // the same event as this area appearing, so setting @FocusState inline in
        // onAppear lands before the panel is key and is dropped. The async hop runs
        // after the window is key, so the field reliably becomes first responder.
        .onAppear {
            DispatchQueue.main.async { promptFieldFocused = true }
        }
    }

    /// Font for the footer buttons (Copy / Paste back / Edit / Cancel). At zoom 1
    /// this equals the small-control system font, so the row is unchanged; at
    /// higher zoom the labels (and the bordered chrome that hugs them) grow with
    /// the rest of the toolbar.
    private var footerButtonFont: Font {
        .system(size: NSFont.smallSystemFontSize * zoom)
    }

    private var footerButtonHeight: CGFloat {
        NSFont.smallSystemFontSize * zoom * 2
    }

    private func resultButtons(
        effective: String,
        isEditable: Bool,
        hideCopy: Bool = false,
        hidePasteBack: Bool = false,
        isDictionary: Bool = false,
        onDictionaryListen: (() -> Void)? = nil,
        speakPhase: SpeakPhase = .idle,
        canReplaySpeak: Bool = false
    ) -> some View {
        let buttonRow = HStack(spacing: z(8)) {
            if isDictionary, let onListen = onDictionaryListen {
                Button(action: onListen) {
                    switch speakPhase {
                    case .loading:
                        Label("Listen", systemImage: "hourglass")
                            .font(footerButtonFont)
                    case .playing:
                        Label("Stop", systemImage: "stop.fill")
                            .font(footerButtonFont)
                    case .idle:
                        Label(canReplaySpeak ? "Listen again" : "Listen", systemImage: "speaker.wave.2")
                            .font(footerButtonFont)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(speakPhase == .loading)
            }

            if !hideCopy {
                Button {
                    outputHandler.copy(effective)
                    copyConfirmed = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        copyConfirmed = false
                    }
                } label: {
                    ZStack {
                        Image(systemName: "doc.on.doc")
                            .font(footerButtonFont)
                            .opacity(copyConfirmed ? 0 : 1)
                        Image(systemName: "checkmark")
                            .font(footerButtonFont)
                            .opacity(copyConfirmed ? 1 : 0)
                    }
                    .animation(.easeInOut(duration: 0.15), value: copyConfirmed)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !hidePasteBack, let source = viewModel.sourceElement, source.isEditable {
                Button {
                    // Capture source and effective text before the async Task to
                    // avoid capturing a potentially stale reference.
                    let capturedSource = source
                    let capturedEffective = effective
                    isPastingBack = true
                    Task { @MainActor in
                        await outputHandler.pasteBack(capturedEffective, to: capturedSource)
                        isPastingBack = false
                        // Paste-back is the terminal action — dismiss the toolbar.
                        onDismiss()
                    }
                } label: {
                    Label("Paste back", systemImage: "arrow.uturn.backward.circle")
                        .font(footerButtonFont)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isPastingBack)
            }

            // Edit / Done toggle — only for non-diff results (Translate, Shorten, custom).
            if isEditable {
                if viewModel.isEditing {
                    Button { viewModel.endEditing() } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(footerButtonFont)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isPastingBack)
                } else {
                    Button { viewModel.beginEditing() } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(footerButtonFont)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isPastingBack)
                }
            }

            // For Dictionary, push Cancel to the trailing edge, away from Listen.
            if isDictionary {
                Spacer()
            }

            // Cancel — close the toolbar without copying or pasting back.
            Button(action: onDismiss) {
                Label("Cancel", systemImage: "xmark")
                    .font(footerButtonFont)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isPastingBack)
        }

        return Group {
            if isDictionary {
                // Dictionary footer: a full-width bar separated from the body by a
                // divider. The negative leading padding cancels the container's
                // leading inset so the divider reaches the panel's left edge; the
                // inner horizontal padding keeps Listen/Cancel off both edges.
                // Negative bottom padding trims the container's z(14) bottom inset
                // down to z(9), matching the z(9) gap above the buttons.
                VStack(spacing: 0) {
                    Divider()
                    buttonRow
                        .padding(.horizontal, z(12))
                        .padding(.top, z(9))
                        .frame(maxWidth: .infinity, minHeight: footerButtonHeight)
                }
                .padding(.leading, -z(12))
                .padding(.bottom, -z(5))
            } else {
                buttonRow
                    .frame(minHeight: footerButtonHeight)
            }
        }
    }
}

// MARK: - SpeakWaveView

/// Animated equalizer bars shown while audio is playing.
/// Five `Capsule` bars animate their heights independently so the result
/// looks like a live sound wave. The container has a fixed height so the
/// toolbar never pulses during animation.
private struct SpeakWaveView: View {
    let zoom: CGFloat
    @State private var animating = false

    /// Base height and amplitude for each bar, staggered so bars look independent.
    /// Durations and phases are NOT scaled — only spatial dimensions are.
    private let barParams: [(base: CGFloat, amplitude: CGFloat, duration: Double)] = [
        (8, 6,  0.45),
        (12, 5, 0.55),
        (16, 4, 0.40),
        (10, 7, 0.50),
        (7,  5, 0.48),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 2 * zoom) {
            ForEach(Array(barParams.enumerated()), id: \.offset) { index, params in
                Capsule()
                    .fill(Color.secondary.opacity(0.7))
                    .frame(
                        width: 3 * zoom,
                        height: animating
                            ? (params.base + params.amplitude) * zoom
                            : params.base * zoom
                    )
                    .animation(
                        Animation
                            .easeInOut(duration: params.duration)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.07),
                        value: animating
                    )
            }
        }
        .frame(height: 22 * zoom)
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

// MARK: - FullWidthTextEditor

/// A self-sizing plain-text editor that fills the width SwiftUI hands it and
/// grows with its content. It is a bare NSTextView (no internal NSScrollView, so
/// no reserved scroller gutter); SwiftUI's surrounding ScrollView owns the
/// scrolling and provides an overlay scrollbar, exactly like the read path.
///
/// The text container width is set from the view's own `bounds` in `layout()`,
/// which fires whenever SwiftUI resizes the view — unlike AppKit
/// `widthTracksTextView`/autoresizing, which does not fire under `NSHostingView`
/// (the cause of the narrow text container in earlier attempts). macOS 13+.
private struct FullWidthTextEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        if let container = textView.textContainer {
            // Width is driven manually in SelfSizingTextView.layout(); no padding
            // so text reaches both edges.
            container.widthTracksTextView = false
            container.lineFragmentPadding = 0
        }
        textView.string = text
        return textView
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        context.coordinator.text = $text
        if textView.string != text { textView.string = text }
        if textView.font != font {
            textView.font = font
            textView.invalidateIntrinsicContentSize()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// NSTextView that wraps to its own width and reports its laid-out height as
/// `intrinsicContentSize`, so SwiftUI sizes it vertically while it fills the
/// width SwiftUI gives it.
private final class SelfSizingTextView: NSTextView {
    override func layout() {
        super.layout()
        // Drive the container width from the actual view width SwiftUI set. This
        // fires on every resize, so the text always wraps to the full width.
        if let container = textContainer {
            let usableWidth = max(0, bounds.width - textContainerInset.width * 2)
            if container.size.width != usableWidth {
                container.size = NSSize(width: usableWidth, height: .greatestFiniteMagnitude)
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Size preference

/// Carries the toolbar's measured size up to ToolbarView so the controller can
/// resize the hosting panel. macOS 13-compatible (no .onGeometryChange).
private struct ToolbarSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - HideMenuIndicatorModifier

/// Hides the system menu chevron when the API is available (macOS 14+).
private struct HideMenuIndicatorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.menuIndicator(.hidden)
        } else {
            content
        }
    }
}


// MARK: - LanguagePicker

/// Compact target-language menu showing a short BCP-47 code (e.g. "vi") plus chevrons.
private struct LanguagePicker: View {
    @Binding var selection: TargetLanguage
    let controlHeight: CGFloat
    let controlRadius: CGFloat
    let zoom: CGFloat
    /// Called after the selection changes. When set (Dictionary), picking a
    /// language re-runs the action immediately; nil (Translate) just updates
    /// the selection.
    var onPick: ((TargetLanguage) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(TargetLanguage.allCases) { lang in
                Button {
                    selection = lang
                    onPick?(lang)
                } label: {
                    if selection == lang {
                        Label(lang.rawValue, systemImage: "checkmark")
                    } else {
                        Text(lang.rawValue)
                    }
                }
            }
        } label: {
            Text(selection.bcp47)
                .font(.system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * zoom).weight(.medium))
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.borderlessButton)
        .modifier(HideMenuIndicatorModifier())
        // Padding on the Menu (not inside its label) sizes both the pill and hit area.
        .padding(.horizontal, 6 * zoom)
        .frame(height: controlHeight)
        // A Menu can't take ToolbarControlStyle, so it mirrors the style's
        // treatment by hand: a resting wash (it reads as a distinct control
        // next to Translate) deepening to the shared hover opacity.
        .background(
            Color.primary.opacity(isHovered ? ToolbarMetrics.pressedOpacity : 0.05),
            in: RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: controlRadius, style: .continuous))
        .fixedSize()
        .animation(ToolbarMetrics.hoverAnimation, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - AccentPicker

/// Compact accent quick-switch menu for the Speak action.
/// Mirrors `LanguagePicker` styling (borderless menu, same hover/background
/// treatment, `HideMenuIndicatorModifier`, same metrics). Shows the default
/// accent's short tag as the label and calls `onPick` with the chosen accent.
private struct AccentPicker: View {
    @Binding var selection: SpeakAccent
    let controlHeight: CGFloat
    let controlRadius: CGFloat
    let zoom: CGFloat
    let onPick: (SpeakAccent) -> Void

    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(SpeakAccent.allCases) { accent in
                Button {
                    selection = accent
                    onPick(accent)
                } label: {
                    if accent == selection {
                        Label(accent.displayName, systemImage: "checkmark")
                    } else {
                        Text(accent.displayName)
                    }
                }
            }
        } label: {
            Text(selection.shortTag)
                .font(.system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * zoom).weight(.medium))
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.borderlessButton)
        .modifier(HideMenuIndicatorModifier())
        // Padding on the Menu (not inside its label) sizes both the pill and hit area.
        .padding(.horizontal, 6 * zoom)
        .frame(height: controlHeight)
        // Resting wash deepening to shared hover opacity — mirrors LanguagePicker.
        .background(
            Color.primary.opacity(isHovered ? ToolbarMetrics.pressedOpacity : 0.05),
            in: RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: controlRadius, style: .continuous))
        .fixedSize()
        .animation(ToolbarMetrics.hoverAnimation, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - ToolbarTooltipModifier

/// Shared hover-tooltip overlay used by action buttons (compact mode) and
/// utility buttons. Appears ~120 ms after the cursor enters — fast enough to
/// feel instant but slow enough to avoid flickering on a passing cursor.
///
/// Placement is `.bottomTrailing` to avoid obscuring the button icon above.
/// Uses the same `regularMaterial` pill as the rest of the toolbar chrome.
///
/// When `text` is empty the modifier is a no-op — no hover tracking, no overlay.
private struct ToolbarTooltipModifier: ViewModifier {
    let text: String
    let controlRadius: CGFloat

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if text.isEmpty {
            // Empty text → no-op: attach nothing, return content unchanged.
            content
        } else {
            content
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        hoverTask?.cancel()
                        hoverTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: ToolbarMetrics.tooltipDelay)
                            guard !Task.isCancelled else { return }
                            if isHovered { showTooltip = true }
                        }
                    } else {
                        hoverTask?.cancel()
                        hoverTask = nil
                        showTooltip = false
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showTooltip {
                        Text(text)
                            .font(.body)
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: controlRadius, style: .continuous)
                                    .fill(.regularMaterial)
                                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                            )
                            .offset(y: 28)
                            .zIndex(1)
                            .transition(.opacity)
                    }
                }
                .animation(ToolbarMetrics.hoverAnimation, value: showTooltip)
        }
    }
}

private extension View {
    /// Attaches the shared toolbar hover-tooltip overlay.
    func toolbarTooltip(_ text: String, controlRadius: CGFloat) -> some View {
        modifier(ToolbarTooltipModifier(text: text, controlRadius: controlRadius))
    }
}

// MARK: - ToolbarActionButton

/// A compact button used for the Improve, Shorten, Proofread, Translate, and
/// custom actions.
///
/// When `compact` is true the text label is hidden and a hover tooltip is shown
/// instead (using the same ~120 ms overlay pattern as `ToolbarUtilityButton`).
private struct ToolbarActionButton: View {
    let icon: ActionIcon
    let label: String
    /// Shows the spinner — true only for the action currently executing.
    let isRunning: Bool
    /// Greys out and blocks the button — true for every action button while any
    /// action runs, so a second action can't be started mid-run.
    let isDisabled: Bool
    /// When true: icon-only layout + hover tooltip. When false: icon + label, no tooltip.
    let compact: Bool
    let zoom: CGFloat
    let controlHeight: CGFloat
    let controlRadius: CGFloat
    let action: () -> Void

    init(symbolName: String, label: String, isRunning: Bool, isDisabled: Bool, compact: Bool = false, zoom: CGFloat, controlHeight: CGFloat, controlRadius: CGFloat, action: @escaping () -> Void) {
        self.icon = .sfSymbol(symbolName)
        self.label = label
        self.isRunning = isRunning
        self.isDisabled = isDisabled
        self.compact = compact
        self.zoom = zoom
        self.controlHeight = controlHeight
        self.controlRadius = controlRadius
        self.action = action
    }

    init(icon: ActionIcon, label: String, isRunning: Bool, isDisabled: Bool, compact: Bool = false, zoom: CGFloat, controlHeight: CGFloat, controlRadius: CGFloat, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.isRunning = isRunning
        self.isDisabled = isDisabled
        self.compact = compact
        self.zoom = zoom
        self.controlHeight = controlHeight
        self.controlRadius = controlRadius
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5 * zoom) {
                // Fixed-size leading slot so swapping icon ↔ spinner keeps the
                // same footprint in both states.
                Group {
                    if isRunning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    } else {
                        ActionIconView(icon: icon, font: .system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * zoom))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 18 * zoom, height: 18 * zoom)

                if !compact {
                    Text(label)
                        .font(.system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * zoom).weight(.medium))
                }
            }
            .padding(.horizontal, 5 * zoom)
            .frame(height: controlHeight)
        }
        .buttonStyle(ToolbarControlStyle(controlRadius: controlRadius))
        .disabled(isDisabled)
        .toolbarTooltip(compact ? label : "", controlRadius: controlRadius)
    }
}

// MARK: - ToolbarUtilityButton

/// A compact icon-only button (Settings, Ignore-this-app) with a hover
/// background and a fast custom tooltip that appears almost immediately on hover
/// (the system `.help()` tooltip has a ~1–2s delay that is not configurable).
private struct ToolbarUtilityButton: View {
    let systemName: String
    let tooltip: String
    let controlHeight: CGFloat
    let controlRadius: CGFloat
    let zoom: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: NSFont.preferredFont(forTextStyle: .body).pointSize * zoom).weight(.medium))
                // Quiet at rest, full-contrast on hover — utility actions are
                // secondary to Improve/Translate and shouldn't compete.
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: controlHeight, height: controlHeight)
        }
        .buttonStyle(ToolbarControlStyle(controlRadius: controlRadius))
        .animation(ToolbarMetrics.hoverAnimation, value: isHovered)
        .onHover { isHovered = $0 }
        .toolbarTooltip(tooltip, controlRadius: controlRadius)
    }
}

// MARK: - SelectableToolbarErrorText

/// Native selectable label for toolbar error messages. SwiftUI `Text` selection
/// can be unreliable in a non-activating floating panel, while NSTextField's
/// selectable label behavior gives users the standard copy affordance.
struct SelectableToolbarErrorText: NSViewRepresentable {
    let message: String
    let font: NSFont
    let textColor: NSColor

    func makeNSView(context: Context) -> NSTextField {
        Self.makeLabel(message: message, font: font, textColor: textColor)
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = message
        label.font = font
        label.textColor = textColor
        label.invalidateIntrinsicContentSize()
    }

    @MainActor
    static func makeLabel(message: String, font: NSFont, textColor: NSColor) -> NSTextField {
        let label = WrappingSelectableToolbarErrorLabel(labelWithString: message)
        label.font = font
        label.textColor = textColor
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBordered = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }
}

private final class WrappingSelectableToolbarErrorLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        guard bounds.width > 0, let cell else {
            return super.intrinsicContentSize
        }

        let measured = cell.cellSize(
            forBounds: NSRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: .greatestFiniteMagnitude
            )
        )
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(measured.height))
    }

    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - Preview

#Preview("Popup Window") {
    let viewModel = ToolbarViewModel()
    viewModel.targetLanguage = .french
    // Seed the canonical default order (all enabled built-ins; promptEnabled defaults to false).
    viewModel.orderedActions = [.builtin(.improve), .builtin(.shorten), .builtin(.proofread), .builtin(.translate), .speak]

    return ToolbarView(
        viewModel: viewModel,
        outputHandler: OutputHandler(),
        onContentResize: { _ in },
        onOpenSettings: {},
        onIgnoreApp: {},
        onIgnoreDomain: {},
        onDismiss: {},
        onDisableCloseConfirmation: {},
        onActivatePromptInput: {}
    )
    .padding(20)
}

#Preview("Edit Mode") {
    let viewModel = ToolbarViewModel()
    // Seed the canonical default order so the action bar renders in the preview.
    viewModel.orderedActions = [.builtin(.improve), .builtin(.shorten), .builtin(.proofread), .builtin(.translate), .speak]
    // Drive the view model into a non-diff result with no handler wired (placeholder
    // path), then enter edit mode so the FullWidthTextEditor is shown.
    viewModel.update(
        text: "Some selected text",
        sourceElement: SourceElementRef(element: AXUIElementCreateSystemWide()),
        screenRect: nil,
        sourceBundleID: nil
    )
    viewModel.triggerTranslate() // no handler → activeActionKind = .translate, .result placeholder
    viewModel.editedResult = """
    **Bold**, *italic*, ~~strikethrough~~ and `inline code`.
    - first list item
    - second list item

    Edit me — the editor spans the full body width.

        Edit me — the editor spans the full body width.
        Edit me — the editor spans the full body width.
        Edit me — the editor spans the full body width.
        Edit me — the editor spans the full body width.
        Edit me — the editor spans the full body width.
    """
    viewModel.beginEditing()

    return ToolbarView(
        viewModel: viewModel,
        outputHandler: OutputHandler(),
        onContentResize: { _ in },
        onOpenSettings: {},
        onIgnoreApp: {},
        onIgnoreDomain: {},
        onDismiss: {},
        onDisableCloseConfirmation: {},
        onActivatePromptInput: {}
    )
    .padding(20)
}
