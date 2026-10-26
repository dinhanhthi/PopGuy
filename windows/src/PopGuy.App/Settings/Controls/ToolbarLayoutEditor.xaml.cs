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
/// idle state (its session is never run, so no provider, clipboard or history is touched). Row 2 is a More actions card
/// of icon chips. Drag an action to reorder it, or to move it between the rows (a 4 DIP threshold, pointer capture);
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

    /// <summary>Pointer slack (DIP) above the More card that still counts as the More zone.</summary>
    private const double MoreZoneSlack = 8;

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

    public ToolbarLayoutEditor()
    {
        InitializeComponent();
        Surface.PointerPressed += OnPointerPressed;
        Surface.PointerMoved += OnPointerMoved;
        Surface.PointerReleased += OnPointerReleased;
        Surface.PointerCanceled += OnPointerLost;
        Surface.PointerCaptureLost += OnPointerLost;
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
        MoreTitle.FontSize = 12 * zoom;
        MoreChevron.FontSize = 10 * zoom;
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
        if (_isEditable) SyncTargets();
        if (!_tabStopsPending) return;
        _tabStopsPending = false;
        RemoveTabStops(_view);
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
    }

    /// <summary>A cancelled drag (capture lost, pointer cancelled) drops its preview.</summary>
    private void OnPointerLost(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is null) return;
        EndDrag();
        Reseed();
    }

    private void EndDrag()
    {
        _drag = null;
        if (_ghost is not null) _ghost.Visibility = Visibility.Collapsed;
    }

    /// <summary>
    /// <paramref name="s"/> with the dragged action at its target slot. The slot counts the shown actions; the zone may
    /// hold actions the toolbar does not show (Speak, Look up), which <see cref="ToolbarLayoutEditMath.ZoneIndex"/> skips.
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
    /// The More card spans only its chips, so the zone is the whole band at or below its top (less a little slack):
    /// dragging straight down from any toolbar action reaches it.
    /// </summary>
    private bool IsInMoreZone(Point position) =>
        Bounds(MoreCard) is { } more && position.Y >= more.Top - MoreZoneSlack;

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
