using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;
using PopGuy.Services;
using PopGuy.Settings.ViewModels;
using PopGuy.Toolbar;
using Windows.Foundation;

namespace PopGuy.Settings.Controls;

/// <summary>
/// The toolbar layout editor (macOS <c>ToolbarLayoutEditorView.swift</c>). Row 1 is the real <see cref="ToolbarView"/>,
/// not hit-testable, bound to an editor-owned <see cref="ToolbarViewModel"/> presented with the current settings in
/// idle state (its session is never run, so no provider, clipboard or history is touched). Then a More card of
/// icon chips: beside the toolbar, top aligned, when both fit the editor's width, else on row 2 (macOS
/// moreFitsBesideToolbar; the arrangement holds still during a drag). A "More actions" connector joins the two cards
/// behind them: straight with the label in its middle side by side; on row 2, an elbow from the toolbar card's bottom
/// into the More card's right edge, the label on its run. Drag an action to reorder it, or to move it
/// between the rows (a 4 DIP threshold, pointer capture);
/// the drop slot comes from the buttons' and chips' real bounds and shows live in the preview, then saves through
/// <see cref="ToolbarLayout.MoveAction"/>; a click without a drag does nothing (In More actions and Show label are switches
/// on the action cards, as on macOS). No caps; a soft warning shows when the toolbar card is wider than
/// <see cref="ToolbarLimits.ToolbarWidthWarningThreshold"/>. Preview-only (Settings → Appearance, macOS
/// <c>ToolbarPreviewView.swift</c>): the toolbar alone, centered when it fits, with no More actions card, drag, hover
/// names or width warning. Its page calls <see cref="Refresh"/> on every settings change. UI thread only.
/// </summary>
public sealed partial class ToolbarLayoutEditor : UserControl
{
    /// <summary>The pointer travel (DIP) before a press becomes a drag (macOS minimumDistance).</summary>
    private const double DragThreshold = 4;

    /// <summary>The connector's visible line (DIP, zoom 1) on each side of its label.</summary>
    private const double ConnectorStub = 12;

    /// <summary>The space (DIP, zoom 1) between the connector's line and its label.</summary>
    private const double ConnectorLabelPad = 6;

    /// <summary>The toolbar's button height at zoom 1 (the bar's 44 minus its padding): the More chips match it.</summary>
    private const double ControlHeight = 32;

    /// <summary>Hover targets over the preview's actions: its buttons are not hit-testable, so their tooltips are here.</summary>
    private readonly Dictionary<ActionIdentifier, Rectangle> _targets = [];
    private readonly List<(ActionIdentifier Id, FrameworkElement Chip)> _chips = [];

    private ActionsViewModel? _model;

    /// <summary>False for the preview-only mode (set once in <see cref="Initialize"/>).</summary>
    private bool _isEditable = true;
    private ToolbarSession? _session;
    private ToolbarView? _view;
    private ToolbarViewModel? _viewModel;
    private Border? _ghost;

    /// <summary>The preview was presented again: its controls lose their tab stops after the next layout.</summary>
    private bool _tabStopsPending;

    /// <summary>The press or drag in progress; null when the pointer is up.</summary>
    private DragSession? _drag;

    /// <summary>The More card sits beside the toolbar (else below it); see <see cref="UpdateArrangement"/>.</summary>
    private bool _sideBySide;

    /// <summary>The connector's last placement (the cards' bounds and the arrangement), so a layout pass that moved nothing sets nothing.</summary>
    private (Rect Toolbar, Rect More, bool SideBySide)? _connectorPlacement;

    public ToolbarLayoutEditor()
    {
        InitializeComponent();
        Surface.PointerPressed += OnPointerPressed;
        Surface.PointerMoved += OnPointerMoved;
        Surface.PointerReleased += OnPointerReleased;
        Surface.PointerCanceled += OnPointerLost;
        Surface.PointerCaptureLost += OnPointerLost;
        Viewport.SizeChanged += OnArrangementInputChanged;
        ToolbarCard.SizeChanged += OnArrangementInputChanged;
        MoreCard.SizeChanged += OnArrangementInputChanged;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    /// <summary>
    /// Once, before the editor loads. The preview's session gets the app's providers and history but no API key, and
    /// nothing ever runs it: the preview raises no action. <paramref name="isEditable"/> false shows the toolbar only.
    /// </summary>
    internal void Initialize(ActionsViewModel model, AppServices services, bool isEditable = true)
    {
        _model = model;
        _isEditable = isEditable;
        if (!isEditable)
        {
            MoreCard.Visibility = Visibility.Collapsed;
            // The toolbar alone, the same space on every side.
            SurfaceContent.Padding = new Thickness(12);
            Surface.HorizontalAlignment = HorizontalAlignment.Center;
        }
        _session = new ToolbarSession(new ActionEngine(services.Providers, _ => null), services.History, () => model.Current);
    }

    /// <summary>The preview shows the current settings; a drag in progress keeps its own order (its end reseeds).</summary>
    internal void Refresh()
    {
        if (_drag is null) Reseed();
    }

    /// <summary>The preview is built on each load: <see cref="ToolbarView.Detach"/> is final.</summary>
    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_session is null) return;
        if (_view is null)
        {
            _viewModel = new ToolbarViewModel(_session, DispatcherQueue);
            _view = new ToolbarView { IsHitTestVisible = false };
            _view.ViewModel = _viewModel;
            _view.LayoutUpdated += OnPreviewLayoutUpdated;
            PreviewHost.Children.Add(_view);
        }
        Reseed();
    }

    /// <summary>A page taken out and put back in one tick may load again before this: a still-loaded editor keeps its preview.</summary>
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (IsLoaded || _view is null) return;
        EndDrag();
        _view.LayoutUpdated -= OnPreviewLayoutUpdated;
        _view.Detach();
        _viewModel?.Detach();
        PreviewHost.Children.Clear();
        Overlay.Children.Clear();
        _targets.Clear();
        _ghost = null;
        _view = null;
        _viewModel = null;
    }

    // Seeding.

    /// <summary>The preview and More actions show <paramref name="settings"/> (default: the saved settings).</summary>
    private void Reseed(AppSettings? settings = null)
    {
        if (_model is null || _viewModel is null) return;
        // A known source app, so "Ignore this app" shows enabled (macOS seeds a dummy source).
        _viewModel.Present(settings ?? _model.Current, isEditable: false, canIgnoreApp: true);
        _tabStopsPending = true;
        RebuildMore();
    }

    private void RebuildMore()
    {
        if (_viewModel is null || !_isEditable) return;
        var zoom = _viewModel.Zoom;
        if (ConnectorLabel.FontSize != 12 * zoom) ConnectorLabel.FontSize = 12 * zoom;
        MoreRow.Spacing = 4 * zoom;
        MoreRow.Children.Clear();
        _chips.Clear();
        foreach (var item in _viewModel.OverflowActions)
        {
            var icon = ToolbarView.Icon(item);
            if (icon is FontIcon glyph) glyph.FontSize = 14 * zoom;
            else if (icon is TextBlock emoji) emoji.FontSize = 14 * zoom;
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            var chip = new Border
            {
                Width = ControlHeight * zoom,
                Height = ControlHeight * zoom,
                CornerRadius = new CornerRadius(4),
                Background = ThemeBrush("SubtleFillColorSecondaryBrush"),
                Child = icon,
            };
            HoverTooltip.SetText(chip, item.Label);
            MoreRow.Children.Add(chip);
            _chips.Add((item.Id, chip));
        }
        if (_chips.Count > 0) return;
        MoreRow.Children.Add(new Rectangle
        {
            Width = ControlHeight * 2 * zoom,
            Height = ControlHeight * zoom,
            RadiusX = 4,
            RadiusY = 4,
            Stroke = ThemeBrush("TextFillColorSecondaryBrush"),
            StrokeThickness = 1,
            StrokeDashArray = [4, 3],
        });
    }

    /// <summary>
    /// After each layout: the host takes the zoomed card's size (the zoom is a render scale, so the view's layout size is
    /// unscaled), the hover targets and the width warning (editable only) follow, and a new preview's controls
    /// leave the tab order (hit-testing stops the pointer only: Enter on Ignore would open its confirmation). Idempotent,
    /// so the layout it may cause settles at once.
    /// </summary>
    private void OnPreviewLayoutUpdated(object? sender, object e)
    {
        if (_view is null || _viewModel is null) return;
        var zoom = _viewModel.Zoom;
        var width = _view.ActualWidth * zoom;
        var height = _view.ActualHeight * zoom;
        if (PreviewHost.Width != width) PreviewHost.Width = width;
        if (PreviewHost.Height != height) PreviewHost.Height = height;
        var wide = _isEditable && width > ToolbarLimits.ToolbarWidthWarningThreshold ? Visibility.Visible : Visibility.Collapsed;
        if (WidthWarning.Visibility != wide) WidthWarning.Visibility = wide;
        if (_isEditable)
        {
            SyncTargets();
            SyncConnector();
        }
        if (!_tabStopsPending) return;
        _tabStopsPending = false;
        RemoveTabStops(_view);
    }

    private void OnArrangementInputChanged(object sender, SizeChangedEventArgs e) => UpdateArrangement();

    /// <summary>
    /// The More card goes beside the toolbar when both cards and the gap fit the viewport (less the surface's padding),
    /// else below it (macOS measuredSideBySide). The widths do not depend on the arrangement (both cards hug their
    /// content, the viewport is as wide as the page gives), so the switch cannot feed back on itself. Below until
    /// measured. Editable only, and never during a press or drag: the drop zone keeps the layout the drag started in.
    /// Idempotent: the height change it causes re-raises the viewport's SizeChanged.
    /// </summary>
    private void UpdateArrangement()
    {
        if (!_isEditable || _drag is not null) return;
        var toolbarWidth = ToolbarCard.ActualWidth;
        var moreWidth = MoreCard.ActualWidth;
        var available = Viewport.ActualWidth - SurfaceContent.Padding.Left - SurfaceContent.Padding.Right;
        var sideBySide = toolbarWidth > 0 && moreWidth > 0 && available > 0
            && ToolbarLayoutEditMath.MoreFitsBesideToolbar(toolbarWidth, moreWidth, ConnectorRun(), available);
        // The gaps follow the zoom (the label's size), so the margin is checked even when the arrangement holds. Below,
        // room on the right when the elbow passes the toolbar card (see SyncConnector).
        var margin = sideBySide
            ? new Thickness(ConnectorRun(), 0, 0, 0)
            : new Thickness(0, WrappedGap, ElbowPastToolbar(toolbarWidth, moreWidth) ? ConnectorRun() : 0, 0);
        if (!MoreCard.Margin.Equals(margin)) MoreCard.Margin = margin;
        if (sideBySide == _sideBySide) return;
        _sideBySide = sideBySide;
        SurfaceContent.Orientation = sideBySide ? Orientation.Horizontal : Orientation.Vertical;
    }

    // The "More actions" connector (macOS connector): the label is measured, not read from a layout pass, so the fit
    // decision above never waits on one.

    private Size ConnectorLabelSize()
    {
        ConnectorLabel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return ConnectorLabel.DesiredSize;
    }

    private double Zoom => _viewModel?.Zoom ?? 1;

    /// <summary>The run that carries the label (stub, pad, label, pad, stub): the gap between the cards side by side.</summary>
    private double ConnectorRun() => ConnectorLabelSize().Width + 2 * (ConnectorStub + ConnectorLabelPad) * Zoom;

    /// <summary>The gap between the rows when the More card is below the toolbar: the label sits beside the More card,
    /// so the gap is the preview's own padding.</summary>
    private const double WrappedGap = 12;

    /// <summary>
    /// Below the toolbar, whether the toolbar card ends too soon for the elbow to drop from its bottom edge (the More
    /// card plus the run is wider): the elbow then leaves from its right edge, right of both cards. Both cards start at
    /// the same left edge.
    /// </summary>
    private bool ElbowPastToolbar(double toolbarWidth, double moreWidth) => moreWidth + ConnectorRun() > toolbarWidth - 8;

    /// <summary>
    /// Places the connector behind the cards. Side by side: straight, from the toolbar card's right edge to the More
    /// card's left edge. Below: an elbow from the toolbar card's bottom down to the More card's middle, then left into its
    /// right edge. The label sits in a break of the last run (no fill behind it, so the backdrop shows through).
    /// Idempotent: called from every layout pass.
    /// </summary>
    private void SyncConnector()
    {
        if (Bounds(ToolbarCard) is not { } toolbar || Bounds(MoreCard) is not { } more
            || toolbar.Width <= 0 || more.Width <= 0)
        {
            if (Connector.Opacity != 0) Connector.Opacity = 0;
            return;
        }
        var placement = (toolbar, more, _sideBySide);
        if (_connectorPlacement is { } last && last.Equals(placement)) return;
        _connectorPlacement = placement;

        var label = ConnectorLabelSize();
        var half = label.Width / 2 + ConnectorLabelPad * Zoom;
        Point[] points;
        Point center;
        if (_sideBySide)
        {
            // Level with the toolbar card's middle, kept within the More card.
            var y = Math.Clamp(toolbar.Y + toolbar.Height / 2, more.Top + 4, Math.Max(more.Top + 4, more.Bottom - 4));
            points = [new Point(toolbar.Right, y), new Point(more.Left, y)];
            center = new Point((toolbar.Right + more.Left) / 2, y);
        }
        else
        {
            // The run ends at the More card's right edge, level with its middle, and starts the run to the right, where
            // the line drops from the toolbar card's bottom; or, when the toolbar card ends before that, from its right
            // edge (UpdateArrangement reserves the room).
            var y = more.Y + more.Height / 2;
            var end = new Point(more.Right, y);
            if (ElbowPastToolbar(toolbar.Width, more.Width))
            {
                var x = Math.Max(more.Right + ConnectorRun(), toolbar.Right + ConnectorStub * Zoom);
                var toolbarY = toolbar.Y + toolbar.Height / 2;
                points = [new Point(toolbar.Right, toolbarY), new Point(x, toolbarY), new Point(x, y), end];
                center = new Point((more.Right + x) / 2, y);
            }
            else
            {
                var x = more.Right + ConnectorRun();
                points = [new Point(x, toolbar.Bottom), new Point(x, y), end];
                center = new Point((more.Right + x) / 2, y);
            }
        }
        // The label breaks the last run.
        var breakIndex = points.Length - 2;
        var direction = points[breakIndex + 1].X >= points[breakIndex].X ? 1 : -1;
        ConnectorLineA.Points = ToPoints(points[..(breakIndex + 1)].Append(new Point(center.X - direction * half, center.Y)));
        ConnectorLineB.Points = ToPoints(points[(breakIndex + 1)..].Prepend(new Point(center.X + direction * half, center.Y)));
        Canvas.SetLeft(ConnectorLabel, center.X - label.Width / 2);
        Canvas.SetTop(ConnectorLabel, center.Y - label.Height / 2);
        if (Connector.Opacity != 1) Connector.Opacity = 1;
    }

    private static PointCollection ToPoints(IEnumerable<Point> points)
    {
        var collection = new PointCollection();
        foreach (var point in points) collection.Add(point);
        return collection;
    }

    private static void RemoveTabStops(DependencyObject parent)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is Control control) control.IsTabStop = false;
            RemoveTabStops(child);
        }
    }

    private void SyncTargets()
    {
        if (_view is null || _viewModel is null) return;
        var shown = new HashSet<ActionIdentifier>();
        foreach (var (id, button) in _view.ActionButtons)
        {
            if (Bounds(button) is not { } rect) continue;
            shown.Add(id);
            if (!_targets.TryGetValue(id, out var target))
            {
                target = new Rectangle { Fill = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
                Overlay.Children.Insert(0, target); // below the ghost
                _targets[id] = target;
            }
            var label = _viewModel.Actions.FirstOrDefault(a => a.Id == id)?.Label;
            if (HoverTooltip.GetText(target) != label) HoverTooltip.SetText(target, label);
            if (Canvas.GetLeft(target) != rect.X) Canvas.SetLeft(target, rect.X);
            if (Canvas.GetTop(target) != rect.Y) Canvas.SetTop(target, rect.Y);
            if (target.Width != rect.Width) target.Width = rect.Width;
            if (target.Height != rect.Height) target.Height = rect.Height;
        }
        foreach (var gone in _targets.Keys.Except(shown).ToList())
        {
            Overlay.Children.Remove(_targets[gone]);
            _targets.Remove(gone);
        }
    }

    // Drag (macOS dragGesture): a press on an action, then moves past the threshold; the pointer is captured.

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(Surface);
        if (!_isEditable || _drag is not null || !point.Properties.IsLeftButtonPressed || _viewModel is null) return;
        if (HitTest(point.Position) is not { } hit) return;
        _drag = new DragSession
        {
            Id = hit.Id,
            SourcePrincipal = hit.Principal,
            SourceIndex = hit.Index,
            TargetPrincipal = hit.Principal,
            TargetIndex = hit.Index,
            Start = point.Position,
            Base = _model!.Current,
            ShownPrincipal = [.. _viewModel.Actions.Select(a => a.Id).Where(a => a != hit.Id)],
            ShownOverflow = [.. _viewModel.OverflowActions.Select(a => a.Id).Where(a => a != hit.Id)],
        };
        Surface.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is not { } drag || _viewModel is null) return;
        var position = e.GetCurrentPoint(Surface).Position;
        if (!drag.Started)
        {
            if (Math.Abs(position.X - drag.Start.X) < DragThreshold && Math.Abs(position.Y - drag.Start.Y) < DragThreshold) return;
            drag.Started = true;
            HoverTooltip.Dismiss();
            ShowGhost(drag.Id);
        }
        MoveGhost(position);
        e.Handled = true;

        var toPrincipal = !IsInMoreZone(position);
        var sameZone = toPrincipal == drag.TargetPrincipal;
        var (ordered, centers) = toPrincipal ? ToolbarRow() : MoreRowItems();
        var index = ToolbarLayoutEditMath.InsertionIndex(position.X, sameZone ? drag.TargetIndex : 0, ordered, centers, drag.Id);
        if (sameZone && index == drag.TargetIndex) return;
        drag.TargetPrincipal = toPrincipal;
        drag.TargetIndex = index;
        Reseed(Moved(drag.Base, drag));
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is not { } drag) return;
        EndDrag();
        Surface.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
        if (!drag.Started) return;
        var unchanged = drag.TargetPrincipal == drag.SourcePrincipal && drag.TargetIndex == drag.SourceIndex;
        if (!unchanged) Save("actionOrder", s => Moved(s, drag));
        Reseed();
        // Sizes that changed during the drag raised no update then, and may not change again.
        UpdateArrangement();
    }

    /// <summary>A cancelled drag (capture lost, pointer cancelled) drops its preview.</summary>
    private void OnPointerLost(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is null) return;
        EndDrag();
        Reseed();
        UpdateArrangement();
    }

    private void EndDrag()
    {
        _drag = null;
        if (_ghost is not null) _ghost.Visibility = Visibility.Collapsed;
    }

    /// <summary>
    /// <paramref name="s"/> with the dragged action at its target slot. The slot counts the shown actions; the zone may
    /// hold actions the toolbar does not show, which <see cref="ToolbarLayoutEditMath.ZoneIndex"/> skips.
    /// </summary>
    private static AppSettings Moved(AppSettings s, DragSession drag)
    {
        var zone = drag.TargetPrincipal ? ToolbarLayout.PrincipalOrdered(s) : ToolbarLayout.OverflowOrdered(s);
        var shown = drag.TargetPrincipal ? drag.ShownPrincipal : drag.ShownOverflow;
        var index = ToolbarLayoutEditMath.ZoneIndex(zone, shown, drag.Id, drag.TargetIndex);
        return ToolbarLayout.MoveAction(s, drag.Id, drag.TargetPrincipal, index);
    }

    /// <summary>The action under <paramref name="position"/>: its id, row and index in that row.</summary>
    private (ActionIdentifier Id, bool Principal, int Index)? HitTest(Point position)
    {
        if (_view is null) return null;
        var row = _view.ActionButtons.ToList();
        for (var i = 0; i < row.Count; i++)
            if (Bounds(row[i].Button) is { } rect && rect.Contains(position)) return (row[i].Id, true, i);
        for (var i = 0; i < _chips.Count; i++)
            if (Bounds(_chips[i].Chip) is { } rect && rect.Contains(position)) return (_chips[i].Id, false, i);
        return null;
    }

    /// <summary>
    /// The More card spans only its chips, so the zone is a whole band (<see cref="ToolbarLayoutEditMath.IsInMoreZone"/>):
    /// side by side, right of its left edge; below the toolbar, at or below its top, so dragging straight down from any
    /// toolbar action reaches it. Uses the arrangement on screen, held still for the drag.
    /// </summary>
    private bool IsInMoreZone(Point position) =>
        Bounds(MoreCard) is { } more
        // Up to the middle of the gap (the connector's run, or the gap between the rows).
        && ToolbarLayoutEditMath.IsInMoreZone(position.X, position.Y, more.Left, more.Top, _sideBySide,
            _sideBySide ? ConnectorRun() / 2 : WrappedGap / 2);

    private (IReadOnlyList<ActionIdentifier>, IReadOnlyDictionary<ActionIdentifier, double>) ToolbarRow()
    {
        var row = _view?.ActionButtons.ToList() ?? [];
        return Row(row);
    }

    private (IReadOnlyList<ActionIdentifier>, IReadOnlyDictionary<ActionIdentifier, double>) MoreRowItems() => Row(_chips);

    private (IReadOnlyList<ActionIdentifier>, IReadOnlyDictionary<ActionIdentifier, double>) Row(
        IReadOnlyList<(ActionIdentifier Id, FrameworkElement Element)> items)
    {
        var centers = new Dictionary<ActionIdentifier, double>();
        foreach (var (id, element) in items)
            if (Bounds(element) is { } rect) centers[id] = rect.X + rect.Width / 2;
        return ([.. items.Select(i => i.Id)], centers);
    }

    /// <summary><paramref name="element"/>'s bounds on the surface (zoom included), or null before it is laid out.</summary>
    private Rect? Bounds(FrameworkElement element)
    {
        if (element.ActualWidth <= 0 || element.ActualHeight <= 0) return null;
        try
        {
            return element.TransformToVisual(Surface).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
        }
        catch (ArgumentException)
        {
            return null; // not in the surface's tree (a row being rebuilt)
        }
    }

    // The ghost: the dragged action's icon under the pointer.

    private void ShowGhost(ActionIdentifier id)
    {
        if (_viewModel is null) return;
        var zoom = _viewModel.Zoom;
        var item = _viewModel.Actions.Concat(_viewModel.OverflowActions).FirstOrDefault(a => a.Id == id);
        if (_ghost is null)
        {
            _ghost = new Border
            {
                CornerRadius = new CornerRadius(4),
                BorderThickness = new Thickness(1),
                IsHitTestVisible = false,
            };
            Overlay.Children.Add(_ghost);
        }
        _ghost.Background = ThemeBrush("SolidBackgroundFillColorBaseBrush");
        _ghost.BorderBrush = ThemeBrush("CardStrokeColorDefaultBrush");
        _ghost.Width = ControlHeight * zoom;
        _ghost.Height = ControlHeight * zoom;
        if (item is not null)
        {
            var icon = ToolbarView.Icon(item);
            if (icon is FontIcon glyph) glyph.FontSize = 14 * zoom;
            else if (icon is TextBlock emoji) emoji.FontSize = 14 * zoom;
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            _ghost.Child = icon;
        }
        _ghost.Visibility = Visibility.Visible;
    }

    private void MoveGhost(Point position)
    {
        if (_ghost is null) return;
        Canvas.SetLeft(_ghost, position.X - _ghost.Width / 2);
        Canvas.SetTop(_ghost, position.Y - _ghost.Height / 2);
    }

    /// <summary>Saves one change; a failed write is logged and the preview goes back to the saved settings.</summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_model is not null && !_model.Save(key, change)) Reseed();
    }

    private static Brush ThemeBrush(string key) => (Brush)Application.Current.Resources[key];

    /// <summary>A press on an action, and once past the threshold its drag (macOS ToolbarDragSession).</summary>
    private sealed class DragSession
    {
        public required ActionIdentifier Id { get; init; }
        public required bool SourcePrincipal { get; init; }
        public required int SourceIndex { get; init; }
        public required Point Start { get; init; }

        /// <summary>The settings when the press began: each preview applies the move to these.</summary>
        public required AppSettings Base { get; init; }

        /// <summary>Each row's shown actions without the dragged one; the target index counts these.</summary>
        public required IReadOnlyList<ActionIdentifier> ShownPrincipal { get; init; }
        public required IReadOnlyList<ActionIdentifier> ShownOverflow { get; init; }

        public bool TargetPrincipal { get; set; }
        public int TargetIndex { get; set; }
        public bool Started { get; set; }
    }
}
