using Microsoft.UI.Xaml.Controls;

namespace PopGuy.Settings.Pages;

/// <summary>
/// Settings → About (macOS AboutView.swift, spec-3 §5.8 without the Sparkle Updates card, which joins in Phase 23).
/// The version line is the informational version without the +commit suffix, as the window's footer shows it; there
/// is no build date (macOS PGReleaseDate): the SDK's deterministic build leaves no build time in the assembly, and the
/// exe's file time is whatever the copy or unzip gave it. The links open through HyperlinkButton's NavigateUri.
/// </summary>
public sealed partial class AboutPage : Page
{
    public AboutPage()
    {
        InitializeComponent();
        VersionText.Text = $"v{App.Version.Split('+')[0]}";
    }
}
