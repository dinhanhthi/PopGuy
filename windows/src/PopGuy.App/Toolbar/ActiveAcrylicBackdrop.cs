using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace PopGuy.Toolbar;

/// <summary>
/// DesktopAcrylic that stays active (promoted from the Phase 3 spike): WinUI's DesktopAcrylicBackdrop follows window
/// activation and shows its solid fallback while the window is inactive, which a toolbar that never activates always
/// is. This one drives the controller with its own configuration (never the default one, which WinUI updates on every
/// activation change): input always active, the theme following the content's ActualTheme. One window only. Check
/// <see cref="DesktopAcrylicController.IsSupported"/> before using it.
/// </summary>
internal sealed partial class ActiveAcrylicBackdrop : SystemBackdrop
{
    private DesktopAcrylicController? _controller;
    private SystemBackdropConfiguration? _configuration;
    private FrameworkElement? _root;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(connectedTarget, xamlRoot);
        if (_controller is not null) return; // one window only
        _root = xamlRoot.Content as FrameworkElement;
        _configuration = new SystemBackdropConfiguration { IsInputActive = true, Theme = ThemeOf(_root) };
        _controller = new DesktopAcrylicController();
        _controller.SetSystemBackdropConfiguration(_configuration);
        _controller.AddSystemBackdropTarget(connectedTarget);
        if (_root is not null) _root.ActualThemeChanged += OnActualThemeChanged;
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop disconnectedTarget)
    {
        base.OnTargetDisconnected(disconnectedTarget);
        if (_root is not null) _root.ActualThemeChanged -= OnActualThemeChanged;
        _root = null;
        if (_controller is not null)
        {
            _controller.RemoveSystemBackdropTarget(disconnectedTarget);
            _controller.Dispose();
            _controller = null;
        }
        _configuration = null;
    }

    private void OnActualThemeChanged(FrameworkElement sender, object args)
    {
        if (_configuration is not null) _configuration.Theme = ThemeOf(sender);
    }

    private static SystemBackdropTheme ThemeOf(FrameworkElement? root) => root?.ActualTheme switch
    {
        ElementTheme.Light => SystemBackdropTheme.Light,
        ElementTheme.Dark => SystemBackdropTheme.Dark,
        _ => SystemBackdropTheme.Default,
    };
}
