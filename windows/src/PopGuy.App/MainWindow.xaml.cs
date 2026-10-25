using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.UI;

namespace PopGuy;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        ApplyCaptionButtonColors();
        RootGrid.ActualThemeChanged += OnActualThemeChanged;
        Closed += OnClosed;

        // Without the +commit suffix the SDK appends to the informational version.
        VersionText.Text = $"Version {App.Version.Split('+')[0]}";
        DataRootText.Text = $"Data folder: {App.DataRoot}";
    }

    /// <summary>Windows switched Light and Dark: the caption buttons follow (the content follows through its ThemeResources).</summary>
    private void OnActualThemeChanged(FrameworkElement sender, object args) => ApplyCaptionButtonColors();

    private void OnClosed(object sender, WindowEventArgs args)
    {
        RootGrid.ActualThemeChanged -= OnActualThemeChanged;
        Closed -= OnClosed;
    }

    /// <summary>
    /// The caption buttons (minimize, maximize, close) in the current theme: transparent at rest, the subtle fills on
    /// hover and press, the primary text colour (disabled text while the window is inactive).
    /// </summary>
    private void ApplyCaptionButtonColors()
    {
        var theme = RootGrid.ActualTheme;
        var titleBar = AppWindow.TitleBar;
        var transparent = ThemeColor("SubtleFillColorTransparent", theme);
        var foreground = ThemeColor("TextFillColorPrimary", theme);
        titleBar.ButtonBackgroundColor = transparent;
        titleBar.ButtonInactiveBackgroundColor = transparent;
        titleBar.ButtonHoverBackgroundColor = ThemeColor("SubtleFillColorSecondary", theme);
        titleBar.ButtonPressedBackgroundColor = ThemeColor("SubtleFillColorTertiary", theme);
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonHoverForegroundColor = foreground;
        titleBar.ButtonPressedForegroundColor = ThemeColor("TextFillColorSecondary", theme);
        titleBar.ButtonInactiveForegroundColor = ThemeColor("TextFillColorDisabled", theme);
    }

    /// <summary>
    /// <paramref name="key"/>'s colour in the theme dictionary of <paramref name="theme"/> (WinUI keeps Dark under
    /// "Default"). The app-level lookup is the fallback only: it keeps the theme the app started in.
    /// </summary>
    private static Color ThemeColor(string key, ElementTheme theme)
    {
        string[] names = theme == ElementTheme.Light ? ["Light"] : ["Dark", "Default"];
        if (FindThemeValue(Application.Current.Resources, key, names) is Color color) return color;
        return (Color)Application.Current.Resources[key];
    }

    private static object? FindThemeValue(ResourceDictionary dictionary, string key, string[] names)
    {
        foreach (var name in names)
        {
            if (dictionary.ThemeDictionaries.TryGetValue(name, out var found)
                && found is ResourceDictionary themed
                && themed.TryGetValue(key, out var value))
            {
                return value;
            }
        }

        foreach (var merged in dictionary.MergedDictionaries)
        {
            if (FindThemeValue(merged, key, names) is { } value) return value;
        }

        return null;
    }
}
