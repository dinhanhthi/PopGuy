// The window's look: adaptive dark/light colors, motion, cards, the window glass and small controls.
// Copied from the thi-macos-glass template and adapted for macOS 13 (pre-14 motion fallbacks) and PopGuy's
// Settings header row (plain SwiftUI, no SwiftUI toolbar; tooltips via `.hoverTooltip`).
import AppKit
import SwiftUI

/// The single place for macOS 26 feature gates. Call sites still need `if #available(macOS 26, *)` for the
/// compiler; this adds the DEBUG `--force-fallbacks` override on top, so pre-26 paths can be checked on 26+.
enum PlatformFeatures {
    static let forceFallbacks: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--force-fallbacks")
        #else
        return false
        #endif
    }()

    static var liquidGlass: Bool {
        if #available(macOS 26, *) { return !forceFallbacks }
        return false
    }
}

/// The app colors. Each one has a dark and a light value and follows the window's appearance live.
enum Palette {
    /// The tint over the window's blur (`WindowGlass`). #1C1C1E / #F5F5F7, both at 0.6.
    static let windowTint = dynamicNSColor(
        dark: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.6),
        light: NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 0.6))
    static let hoverFill = dynamic(dark: .white.withAlphaComponent(0.1), light: .black.withAlphaComponent(0.06))
    static let pressedFill = dynamic(dark: .white.withAlphaComponent(0.2), light: .black.withAlphaComponent(0.12))
    /// Darkens a pressed button over its own fill.
    static let pressedOverlay = dynamic(dark: .black.withAlphaComponent(0.2), light: .black.withAlphaComponent(0.1))
    /// Dims the window behind an in-window modal, over the modal's backdrop blur.
    static let scrim = dynamic(dark: .black.withAlphaComponent(0.45), light: .black.withAlphaComponent(0.28))
    static let switchOffFill = dynamic(dark: .white.withAlphaComponent(0.22), light: .black.withAlphaComponent(0.15))
    /// The shadow of the switch's white knob, the same in both modes.
    static let knobShadow = Color.black.opacity(0.2)
    /// Cards and panels, a step above the window. #2C2C2E / #FFFFFF
    static let surface = dynamic(
        dark: NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1),
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    /// Controls on a card, a step above `surface`. #3A3A3C / #EBEBED
    static let inputSurface = dynamic(
        dark: NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1),
        light: NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 237 / 255, alpha: 1))
    /// The 1 pt edge of cards and panels.
    static let surfaceBorder = dynamic(dark: .white.withAlphaComponent(0.08), light: .black.withAlphaComponent(0.08))
    /// The edge of a raised card: bright at the top, dim on the sides, a faint highlight at the bottom.
    static let raisedRim = LinearGradient(
        stops: [
            .init(color: dynamic(dark: .white.withAlphaComponent(0.24), light: .black.withAlphaComponent(0.10)),
                  location: 0),
            .init(color: dynamic(dark: .white.withAlphaComponent(0.05), light: .black.withAlphaComponent(0.05)),
                  location: 0.45),
            .init(color: dynamic(dark: .white.withAlphaComponent(0.10), light: .black.withAlphaComponent(0.12)),
                  location: 1),
        ],
        startPoint: .top, endPoint: .bottom)
    /// The light at the top of a raised button's fallback capsule.
    static let buttonSheen = LinearGradient(
        colors: [dynamic(dark: .white.withAlphaComponent(0.08), light: .white.withAlphaComponent(0.6)), .clear],
        startPoint: .top, endPoint: .center)
    /// The light at the top of a raised card; none in light mode.
    static let cardSheen = LinearGradient(
        colors: [dynamic(dark: .white.withAlphaComponent(0.05), light: .clear), .clear],
        startPoint: .top, endPoint: .center)
    /// The shadow under a raised card (radius 6, y 3).
    static let cardShadow = dynamic(dark: .black.withAlphaComponent(0.35), light: .black.withAlphaComponent(0.10))
    /// The shadow under a raised button's fallback capsule (radius 3, y 1.5).
    static let buttonShadow = dynamic(dark: .black.withAlphaComponent(0.35), light: .black.withAlphaComponent(0.12))

    /// A color that resolves to `dark` under a dark appearance and to `light` otherwise.
    /// `nonisolated` so the provider closures are not MainActor-isolated: AppKit may resolve a color off the main thread.
    private nonisolated static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: dynamicNSColor(dark: dark, light: light))
    }

    private nonisolated static func dynamicNSColor(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

/// The app's shared animations.
enum Motion {
    /// Pages, tabs, panels, lists and the pill: a quick spring, its small bounce invisible at this length.
    static let standard: Animation = {
        if #available(macOS 14, *) { return .snappy(duration: 0.25) }
        return .spring(response: 0.25, dampingFraction: 0.85) // approximation of snappy for macOS 13
    }()
    /// Hover highlights.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Sheets and the search bar opening: a touch slower than `standard`.
    static let sheet: Animation = {
        if #available(macOS 14, *) { return .snappy(duration: 0.3) }
        return .spring(response: 0.3, dampingFraction: 0.85) // approximation of snappy for macOS 13
    }()
    /// A view leaving: a short fade, quicker than its entrance.
    static let exit = Animation.easeOut(duration: 0.1)
    /// A button going down and back up.
    static let press: Animation = {
        if #available(macOS 14, *) { return .snappy(duration: 0.12) }
        return .spring(response: 0.12, dampingFraction: 0.85) // approximation of snappy for macOS 13
    }()
    /// Switches and disclosure chevrons.
    static let toggle: Animation = {
        if #available(macOS 14, *) { return .snappy(duration: 0.2) }
        return .spring(response: 0.2, dampingFraction: 0.85) // approximation of snappy for macOS 13
    }()
    /// Items reflowing under a drag: an interactive spring that retargets on every move (available on macOS 13,
    /// no fallback needed).
    static let drag = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.86)
}

/// A raised button like the toolbar's: `height` tall (a circle for an icon, with no `horizontalPadding`). Liquid Glass
/// on macOS 26; before, a capsule lit from above with a soft shadow, like `GlassCard(raised:)`. Lighter on hover,
/// darker while pressed, dimmed when disabled. `tint` colors the glass (or the capsule's fill).
struct RaisedButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 0
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Raised(configuration: configuration, height: height, horizontalPadding: horizontalPadding, tint: tint)
    }

    private struct Raised: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let horizontalPadding: CGFloat
        let tint: Color?
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let fill = configuration.isPressed ? Palette.pressedOverlay : hovered && isEnabled ? Palette.hoverFill : .clear
            configuration.label
                .foregroundStyle(.primary)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: height, minHeight: height, maxHeight: height)
                .modifier(RaisedCapsule(tint: tint))
                .overlay(Capsule().fill(fill).allowsHitTesting(false))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }

    private struct RaisedCapsule: ViewModifier {
        let tint: Color?

        func body(content: Content) -> some View {
            if #available(macOS 26, *), PlatformFeatures.liquidGlass {
                content.glassEffect(.regular.tint(tint), in: Capsule())
            } else {
                content.modifier(RaisedCapsuleFallback(tint: tint))
            }
        }
    }
}

/// The pre-Liquid Glass raised capsule: a `tint` (or input-color) fill lit from above, a soft shadow and a lit rim.
private struct RaisedCapsuleFallback: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                Capsule().fill(tint ?? Palette.inputSurface)
                    .overlay(Capsule().fill(Palette.buttonSheen))
                    .shadow(color: Palette.buttonShadow, radius: 3, y: 1.5)
            }
            .overlay(Capsule().strokeBorder(Palette.raisedRim, lineWidth: 1).allowsHitTesting(false))
    }
}

/// The capsule behind a group of header-row controls (tabs, a search field). PopGuy's header row is plain SwiftUI, so
/// no AppKit toolbar draws this capsule: Liquid Glass on macOS 26, before that the raised capsule of `RaisedButtonStyle`.
struct HeaderCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.modifier(RaisedCapsuleFallback())
        }
    }
}

extension View {
    /// Puts the view in a header-row capsule (`HeaderCapsule`).
    func headerCapsule() -> some View {
        modifier(HeaderCapsule())
    }
}

/// A small text button of a card row: a capsule of the input color, lighter on hover, darker while pressed.
/// `formRow`: as tall as a compact `CapsuleTabs`, for a form row. `prominent`: the accent color with white text.
struct RowTextButtonStyle: ButtonStyle {
    var formRow = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, formRow: formRow, prominent: prominent)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let formRow: Bool
        let prominent: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(formRow ? .subheadline : .caption.weight(.medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, formRow ? 10 : 8)
                .padding(.vertical, formRow ? 0 : 3)
                .frame(height: formRow ? 22 : nil)
                .background(
                    Capsule()
                        .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.inputSurface))
                        .overlay(Capsule().fill(
                            configuration.isPressed ? Palette.pressedOverlay : hovered && isEnabled ? Palette.hoverFill : .clear)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// The icon buttons of a row: a round highlight on hover, darker and a bit smaller while pressed, dimmed when
/// disabled. The highlight reaches past the label without changing the row's layout.
struct RowIconButtonStyle: ButtonStyle {
    /// A capsule highlight, for a label wider than an icon (an icon and a menu chevron).
    var capsule = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, capsule: capsule)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let capsule: Bool
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let fill = configuration.isPressed ? Palette.pressedFill : hovered && isEnabled ? Palette.hoverFill : .clear
            configuration.label
                .background {
                    if capsule {
                        Capsule().fill(fill).padding(-5)
                    } else {
                        Circle().fill(fill).padding(-5)
                    }
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// A row of a settings sidebar: the selected row is an accent capsule with white text, the others get a hover
/// capsule. Rows sit in a `VStack(spacing: SidebarItemStyle.spacing)` instead of a `List(.sidebar)`, whose
/// selection fills the whole row height, so neighbors touch however much padding the rows get.
/// PopGuy: the capsule height comes from `height` (the template's 6 pt vertical padding around a body line); a row
/// adds its own `SettingsMetrics.sidebarItemVerticalPadding` inside it.
struct SidebarItemStyle: ButtonStyle {
    var selected: Bool
    /// Gap between two rows' capsules.
    static let spacing: CGFloat = 6
    /// Height of a row's capsule.
    static let height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovered = false

        var body: some View {
            let fill: Color = selected ? .accentColor
                : configuration.isPressed ? Palette.pressedFill
                : hovered ? Palette.hoverFill : .clear
            configuration.label
                .labelStyle(SidebarLabelStyle(selected: selected))
                .padding(.horizontal, 10)
                .frame(minHeight: SidebarItemStyle.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }

    private struct SidebarLabelStyle: LabelStyle {
        let selected: Bool

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 8) {
                configuration.icon
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                configuration.title
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
        }
    }
}

/// A button of a bottom bar: `height` tall (a circle for an icon, with no `horizontalPadding`), a capsule of the input
/// color, or the accent color when `prominent`; lighter on hover, darker while pressed, dimmed when disabled.
struct BottomBarButtonStyle: ButtonStyle {
    /// Every control of the bottom bars: buttons, menus, chips and a one-line text field.
    static let height: CGFloat = 34

    var height = Self.height
    var prominent = false
    var horizontalPadding: CGFloat = 14
    /// A menu's trigger: it stays pressed while its menu is open, and shows the hover look then, not the darker one.
    var menu = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, height: height, prominent: prominent,
                  horizontalPadding: horizontalPadding, menu: menu)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let prominent: Bool
        let horizontalPadding: CGFloat
        let menu: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: height, minHeight: height, maxHeight: height)
                .background(
                    Capsule()
                        .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.inputSurface))
                        .overlay(Capsule().fill(
                            configuration.isPressed && !menu ? Palette.pressedOverlay
                                : (hovered || configuration.isPressed) && isEnabled ? Palette.hoverFill : .clear)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// An icon button of the Settings header row: a small round highlight on hover, darker while pressed, dimmed when
/// disabled. `tooltip` is its hover tooltip (`.hoverTooltip`) and its accessibility label.
struct HeaderIconButton: View {
    let systemImage: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .imageScale(.large)
        }
        .buttonStyle(HeaderIconButtonStyle())
        .accessibilityLabel(tooltip)
        .hoverTooltip(tooltip)
    }
}

/// The look of a `HeaderIconButton`: a 36 by 24 label with a 28 pt round highlight, as big as a toolbar group
/// button's. Also for a `Menu` in a header button group (`.menuStyle(.button)` + this style).
struct HeaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCircle(configuration: configuration)
    }

    private struct HoverCircle: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(width: 36, height: 24)
                .background {
                    Circle()
                        .fill(configuration.isPressed ? Palette.pressedFill
                            : hovered && isEnabled ? Palette.hoverFill : .clear)
                        .frame(width: 28, height: 28)
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// The arrow of a menu button.
struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .accessibilityHidden(true)
    }
}

/// Tabs for the header row, as tall as its buttons' highlights, in a `HeaderCapsule` (Liquid Glass on macOS 26, a
/// raised capsule before): the selected tab is an accent capsule that slides between the tabs (no slide under Reduce
/// Motion). `compact`: smaller, on a surface capsule, for a form row.
struct CapsuleTabs<Tab: Hashable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> Text
    var compact = false
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                Item(tab: tab, title: title(tab), selected: tab == selection, compact: compact, namespace: namespace) {
                    withAnimation(animation) { selection = tab }
                }
            }
        }
        // One pill that follows the selected item's frame, so it slides instead of fading between items.
        .background {
            Capsule()
                .fill(Color.accentColor)
                .matchedGeometryEffect(id: selection, in: namespace, isSource: false)
        }
        // Also animates a selection set from code (menus, shortcuts).
        .animation(animation, value: selection)
        .modifier(SurfaceTrack(compact: compact))
    }

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    /// The header row has no AppKit toolbar to draw a capsule around the tabs, so they get a `HeaderCapsule`; a form
    /// row's tabs sit on a surface track.
    private struct SurfaceTrack: ViewModifier {
        let compact: Bool

        func body(content: Content) -> some View {
            if compact {
                content
                    .padding(2)
                    .background(Capsule().fill(Palette.surface))
                    .overlay(Capsule().strokeBorder(Palette.surfaceBorder, lineWidth: 1).allowsHitTesting(false))
            } else {
                content
                    .padding(3)
                    .headerCapsule()
            }
        }
    }

    private struct Item: View {
        let tab: Tab
        let title: Text
        let selected: Bool
        let compact: Bool
        let namespace: Namespace.ID
        let action: () -> Void
        @State private var hovered = false
        /// A toolbar button's highlight; a form row's control when compact.
        private var height: CGFloat { compact ? 22 : 28 }

        var body: some View {
            Button(action: action) {
                title
                    .font(compact ? .subheadline : .callout)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .padding(.horizontal, compact ? 10 : 12)
                    .frame(height: height)
                    .background {
                        if hovered && !selected { Capsule().fill(Palette.hoverFill) }
                    }
                    .matchedGeometryEffect(id: tab, in: namespace)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// A small on/off switch, dimmed when disabled; the system switch stays wide even at `.mini` on macOS 26.
struct CompactSwitch: ToggleStyle {
    static let height: CGFloat = 19

    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration)
    }

    private struct Switch: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            // A Button, not a tap gesture: keyboard navigation reaches it and Space toggles it.
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Palette.switchOffFill)
                    .frame(width: 34, height: CompactSwitch.height)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: Palette.knobShadow, radius: 0.5, y: 0.5)
                            .padding(1.5)
                    }
                    .animation(reduceMotion ? nil : Motion.toggle, value: configuration.isOn)
                    .contentShape(Capsule())
            }
            .buttonStyle(Bare())
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }

    /// The label as is: `.plain` dims a disabled label on top of the switch's own dimming.
    private struct Bare: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }
}

/// A disclosure row whose chevron sits on the title's line, not halfway down a title with a subtitle. A click anywhere
/// on the header row toggles it, not only on the chevron; the row's own controls (its switch) keep their clicks.
struct TitleChevronDisclosureStyle: DisclosureGroupStyle {
    /// The chevron's width: content inset by it lines up with the title.
    nonisolated static let indent: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        TitleChevronDisclosure(configuration: configuration)
    }
}

private struct TitleChevronDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: TitleChevronDisclosureStyle.indent, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(configuration.isExpanded ? "Collapse" : "Expand")
                configuration.label
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if configuration.isExpanded { configuration.content }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : Motion.toggle) {
            configuration.$isExpanded.wrappedValue.toggle()
        }
    }
}

/// The translucent window background, blurring what is behind the window (toolbar included), under a tint so only a
/// little shows through. The tint follows a live dark/light switch.
///
/// `draggable` glass catches every click over it, so nothing underneath gets it, and a drag on it moves the window
/// (the titlebar band). Plain glass leaves its hits to SwiftUI as before.
struct WindowGlass: NSViewRepresentable {
    var draggable = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = draggable ? DragGlassView() : NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        let tint = TintView(frame: view.bounds)
        tint.autoresizingMask = [.width, .height]
        view.addSubview(tint)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Glass that is the hit view for every point inside it (not its tint), and lets AppKit drag the window from it.
    private final class DragGlassView: NSVisualEffectView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // `point` is in the superview's coordinates.
            isHidden || !frame.contains(point) ? nil : self
        }
    }

    /// A layer color resolves once, so it is set again in `updateLayer()`, which AppKit calls on an appearance change.
    private final class TintView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
        }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = Palette.windowTint.cgColor
            }
        }
    }
}

/// A card or panel: solid `Palette.surface` with a 1 pt `Palette.surfaceBorder` edge, on every macOS version, so it
/// stands out from the window background. Raised (a sidebar, an entry card) looks like the toolbar's capsules: a rim
/// lit from above, a faint sheen at the top and a soft shadow under it.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var raised = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if raised {
            content
                .background {
                    shape.fill(Palette.surface)
                        .overlay(shape.fill(Palette.cardSheen))
                        .shadow(color: Palette.cardShadow, radius: 6, y: 3)
                }
                .overlay(shape.strokeBorder(Palette.raisedRim, lineWidth: 1).allowsHitTesting(false))
        } else {
            content
                .background(shape.fill(Palette.surface))
                .overlay(shape.strokeBorder(Palette.surfaceBorder, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

/// On macOS 26+ (unless `--force-fallbacks`), scrolled content stops hard at the top edge instead of fading under
/// the transparent title bar.
struct HardTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}
