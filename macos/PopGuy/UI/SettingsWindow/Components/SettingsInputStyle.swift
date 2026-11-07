import SwiftUI

/// Shared look of the Settings window's text inputs: a rounded field (10 pt, the small inset-card radius) of the
/// input color with a 1 pt edge; the focused field gets an accent edge instead of the system's square focus ring.
/// The text is inset from the rounded edge (padding inside the fill), so it never touches the corners.
/// Header search capsules (`HeaderSearchCapsule`, the Library modal's search) keep their capsule look.
enum SettingsInputMetrics {
    static let cornerRadius: CGFloat = 10
    /// Matches the 28 pt row buttons; multi-line fields grow past it.
    static let minHeight: CGFloat = 28
}

/// `TextField` / `SecureField` style: `.textFieldStyle(.settings)`.
struct SettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        Field(configuration: configuration)
    }

    private struct Field: View {
        let configuration: TextField<SettingsTextFieldStyle._Label>
        @FocusState private var focused: Bool

        var body: some View {
            configuration
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: SettingsInputMetrics.minHeight)
                .modifier(SettingsInputChrome(focused: focused))
        }
    }
}

extension TextFieldStyle where Self == SettingsTextFieldStyle {
    static var settings: SettingsTextFieldStyle { SettingsTextFieldStyle() }
}

extension View {
    /// The `.textFieldStyle(.settings)` look for a multi-line `TextEditor`: the editor's own background is hidden
    /// and the text view is inset, so the first line, the caret and the scroller sit inside the rounded corners.
    func settingsTextEditor() -> some View {
        modifier(SettingsTextEditorStyle())
    }
}

private struct SettingsTextEditorStyle: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .modifier(SettingsInputChrome(focused: focused))
    }
}

/// The rounded fill, the edge (accent while focused) and the disabled dimming shared by both input styles.
private struct SettingsInputChrome: ViewModifier {
    let focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
        content
            .noSystemFocusRing()
            .background(shape.fill(Palette.inputSurface))
            .overlay(
                shape.strokeBorder(
                    focused ? Color.accentColor : Palette.surfaceBorder,
                    lineWidth: focused ? 1.5 : 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Motion.hover, value: focused)
    }
}

private extension View {
    /// The accent edge replaces the system focus ring (`focusEffectDisabled` is macOS 14+; the plain field and
    /// the hidden-background editor draw no ring on macOS 13).
    @ViewBuilder
    func noSystemFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}
