namespace PopGuy.Core.Settings;

/// <summary>
/// Toolbar constants (macOS <c>ToolbarLimits.swift</c>). There are no action-count caps: users decide how many actions
/// sit on the toolbar or in More actions.
/// </summary>
public static class ToolbarLimits
{
    /// <summary>
    /// Toolbar card width (DIP, zoom included) above which Settings → Actions shows a soft warning under the layout
    /// editor that the toolbar is getting wide. Not a cap: nothing is rejected or trimmed.
    /// </summary>
    public const double ToolbarWidthWarningThreshold = 480;
}
