using System.Security;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Icons;
using PopGuy.Core.Settings;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;
using PopGuy.Services;
using Windows.Graphics;
using VirtualKey = Windows.System.VirtualKey;
using DrawingPoint = System.Drawing.Point;

namespace PopGuy.Onboarding;

/// <summary>
/// The first-launch wizard (spec-3 §6, macOS OnboardingView.swift): six steps in the macOS order: Welcome, How PopGuy
/// Reads Text (the Windows step in place of the Accessibility permission: Windows needs none), Set Up a Provider, How
/// PopGuy Appears, Choose Your Actions and You're All Set. A 560×560 client area, centered, not resizable. Enter goes to
/// the next step unless the focus is in a text field, on a button or in the shortcut recorder (macOS: no default action
/// while recording). Every switch saves through <see cref="SettingsStore.Update"/> at once, and a change from elsewhere
/// (the tray, Settings) shows while the window is open. The App owns its lifetime and marks onboarding done when it
/// closes. UI thread only.
/// </summary>
public sealed partial class OnboardingWindow : Window
{
    private const double ClientSize = 560;
    private const int StepCount = 6;

    private readonly AppServices _services;
    private readonly Action _openSettings;
    private readonly UIElement[] _steps;
    private readonly Ellipse[] _dots;
    private int _step;
    private bool _closing;

    /// <summary>The controls are being set from the settings: their change events are not the user's.</summary>
    private bool _syncing;

    // How PopGuy Appears.
    private ToggleSwitch _chordToggle = null!;
    private ContentControl _replacementRow = null!;
    private ShortcutRecorder _recorder = null!;
    private Border _chordBadge = null!;
    private Button _clearButton = null!;
    private Button _recordButton = null!;
    private ToggleSwitch _onSelectToggle = null!;

    // Choose Your Actions: each switch with the wrapper that carries its tooltip (a disabled switch gets no pointer).
    private readonly List<(ActionIdentifier Id, ToggleSwitch Toggle, Grid Wrapper)> _actionToggles = [];

    // You're All Set.
    private ToggleSwitch _loginToggle = null!;
    private TextBlock _loginErrorText = null!;

    /// <summary>The one-shot re-realizations after the first show, kept so they tick.</summary>
    private DispatcherQueueTimer? _presentedTimer;
    private DispatcherQueueTimer? _backstopTimer;

    /// <param name="openSettings">The last step's Open Settings…: the Settings window comes to the front.</param>
    internal OnboardingWindow(AppServices services, Action openSettings)
    {
        _services = services;
        _openSettings = openSettings;
        InitializeComponent();

        _steps =
        [
            WelcomeStep(),
            ReadsTextStep(),
            ProviderStep(),
            AppearsStep(),
            ActionsStep(),
            FinishStep(),
        ];
        _dots = new Ellipse[StepCount];
        for (var i = 0; i < StepCount; i++)
        {
            _dots[i] = new Ellipse();
            DotsPanel.Children.Add(_dots[i]);
        }
        AutomationProperties.SetName(DotsPanel, "Setup steps");

        BackButton.Click += (_, _) => ShowStep(_step - 1);
        NextButton.Click += (_, _) => ShowStep(_step + 1);
        PrimaryButton.Click += (_, _) => OnPrimary();
        RootGrid.PreviewKeyDown += OnPreviewKeyDown;

        Place();
        Refresh();
        ShowStep(0);

        _services.Settings.Changed += OnSettingsChanged;
        Activated += OnFirstActivated;
        Activated += OnActivated;
        Closed += OnClosed;
    }

    /// <summary>Brings the window to the front: restored if minimized, then activated.</summary>
    internal void Show()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
            presenter.Restore();
        Activate();
    }

    // Steps.

    private void ShowStep(int step)
    {
        _step = Math.Clamp(step, 0, StepCount - 1);
        PageHost.Content = _steps[_step];
        PageScroller.ChangeView(null, 0, null, disableAnimation: true);
        for (var i = 0; i < StepCount; i++)
            _dots[i].Style = Res(i == _step ? "CurrentDotStyle" : "DotStyle");
        AutomationProperties.SetHelpText(DotsPanel, $"Step {_step + 1} of {StepCount}");

        var first = _step == 0;
        var last = _step == StepCount - 1;
        BackButton.Visibility = first ? Visibility.Collapsed : Visibility.Visible;
        NextButton.Visibility = first || last ? Visibility.Collapsed : Visibility.Visible;
        PrimaryButton.Visibility = first || last ? Visibility.Visible : Visibility.Collapsed;
        PrimaryButton.Content = first ? "Get started" : "Get Started";
        // macOS onAppear: the Run key is read each time the last step shows.
        if (last) RefreshLogin();
    }

    private void OnPrimary()
    {
        if (_step == StepCount - 1) Close();
        else ShowStep(_step + 1);
    }

    /// <summary>
    /// Enter is Next (macOS defaultAction), except where Enter is the control's own: a text or password field, a button
    /// (it clicks it), a combo box, and the shortcut recorder (which records it, or cancels).
    /// </summary>
    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || RootGrid.XamlRoot is not { } root) return;
        if (FocusManager.GetFocusedElement(root) is TextBox or PasswordBox or ButtonBase or ComboBox or ShortcutRecorder)
            return;
        e.Handled = true;
        OnPrimary();
    }

    private UIElement WelcomeStep() => StepPanel(Header(
        "", "Welcome to PopGuy",
        "Select text in any app. A toolbar appears nearby with Improve, Translate, and your own actions."));

    /// <summary>The Windows step in place of the macOS Accessibility permission: what PopGuy reads, and its one limit.</summary>
    private UIElement ReadsTextStep()
    {
        var ready = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        ready.Children.Add(Icon("", "SuccessIconStyle", 16));
        ready.Children.Add(new TextBlock { Text = "No permission is needed", Style = Res("SuccessTextStyle") });

        return StepPanel(
            Header(
                "", "How PopGuy Reads Text",
                "PopGuy reads the text you select through Windows UI Automation. When an app doesn't share its selection, " +
                "PopGuy copies it for a moment and puts your clipboard back right after."),
            ready,
            Card(Note(
                "", "CautionIconStyle",
                "Apps running as administrator are out of reach: Windows doesn't let PopGuy read their text or paste into " +
                "them. Run those apps without administrator rights to use PopGuy there.")));
    }

    /// <summary>The provider chooser comes in task 22.2; until then the step shows its header only.</summary>
    private UIElement ProviderStep() => StepPanel(Header(
        "", "Set Up a Provider",
        "Choose Local AI to run privately on your PC, or a Cloud API key for the best quality."));

    private UIElement AppearsStep()
    {
        _chordToggle = Switch("Show toolbar with Ctrl+C+C");
        _chordToggle.Toggled += (_, _) => Save("triggerChord", s => s with { TriggerChordEnabled = _chordToggle.IsOn });

        _recorder = new ShortcutRecorder { VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(_recorder, "Replacement shortcut");
        _recorder.RecordingStarted += OnRecordingStarted;
        _recorder.RecordingEnded += OnRecordingEnded;
        _clearButton = IconButton("", "Clear — revert to Ctrl+C+C");
        _clearButton.Click += (_, _) => Save("chordReplacementShortcut", s => s with { ChordReplacementShortcut = null });
        _recordButton = IconButton("", "Record a replacement shortcut (e.g. Ctrl+Shift+Space)");
        _recordButton.Click += (_, _) => _recorder.Start();
        // The chord's own badge while no replacement is set (macOS ShortcutBadge "⌘C+C").
        _chordBadge = new Border
        {
            Style = Res("BadgeStyle"),
            Child = new TextBlock { Text = "Ctrl+C+C", VerticalAlignment = VerticalAlignment.Center },
            VerticalAlignment = VerticalAlignment.Center,
        };
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        controls.Children.Add(_chordBadge);
        controls.Children.Add(_recorder);
        controls.Children.Add(_clearButton);
        controls.Children.Add(_recordButton);

        var replacement = new Grid { ColumnSpacing = 8 };
        replacement.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        replacement.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        replacement.Children.Add(new TextBlock { Text = "Use a different shortcut", VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(controls, 1);
        replacement.Children.Add(controls);
        // A control, so turning the chord off disables everything in the row (macOS .disabled).
        _replacementRow = new ContentControl
        {
            Content = replacement,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            IsTabStop = false,
        };

        var chordCard = Card(
            _chordToggle,
            Secondary("Press Ctrl+C twice quickly on selected text to show the toolbar."),
            _replacementRow,
            Secondary("You can pick a different shortcut instead of Ctrl+C+C (for example Ctrl+Shift+Space)."));

        _onSelectToggle = Switch("Show toolbar when text is selected");
        _onSelectToggle.Toggled += (_, _) =>
            Save("triggerOnSelect", s => s with { TriggerOnSelectEnabled = _onSelectToggle.IsOn });
        var selectCard = Card(
            _onSelectToggle,
            Secondary("Shows the toolbar the moment you select text. That can feel busy, so it's off by default."),
            Note(
                "", "CautionIconStyle",
                "May not work well in some editors (for example Cursor, VS Code, or Notion). Use Ctrl+C+C there instead."));

        return StepPanel(
            Header("", "How PopGuy Appears", "Trigger PopGuy with Ctrl+C+C, or show the toolbar when you select text."),
            chordCard,
            selectCard,
            Secondary("You can change these anytime in Settings → Triggers."));
    }

    /// <summary>The built-ins of macOS OnboardingActionsPage, with their SF Symbol names (glyphs via <see cref="SymbolMap"/>).</summary>
    private static readonly (ActionIdentifier Id, string Symbol, string Title, string Description)[] Builtins =
    [
        (ActionIdentifier.Builtin(ActionKind.Improve), "wand.and.stars", "Improve", "Fix grammar and improve clarity"),
        (ActionIdentifier.Builtin(ActionKind.Shorten), "text.badge.minus", "Shorten", "Make the text more concise"),
        (ActionIdentifier.Builtin(ActionKind.Proofread), "checkmark.bubble", "Proofread", "Fix spelling and grammar"),
        (ActionIdentifier.Builtin(ActionKind.Translate), "character.bubble", "Translate", "Translate into your chosen language"),
        (ActionIdentifier.Builtin(ActionKind.Prompt), "bubble.and.pencil", "Prompt", "Type a one-off prompt for the selected text"),
        (ActionIdentifier.Speak, "speaker.wave.2", "Speak", "Speak the selected text"),
        (ActionIdentifier.Dictionary, "character.book.closed", "Look up", "Look up the selected word"),
    ];

    private UIElement ActionsStep()
    {
        var rows = new StackPanel { Spacing = 10 };
        foreach (var (id, symbol, title, description) in Builtins)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var icon = Icon(SymbolMap.Glyph(symbol), "AccentIconStyle", 18);
            row.Children.Add(icon);
            var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = title, Style = AppStyle("BodyStrongTextBlockStyle") });
            text.Children.Add(Secondary(description));
            Grid.SetColumn(text, 1);
            row.Children.Add(text);

            var toggle = new ToggleSwitch { VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(toggle, title);
            toggle.Toggled += (_, _) => SetActionEnabled(id, toggle.IsOn);
            // Transparent, so it takes the pointer and shows the tooltip while the switch is locked.
            var wrapper = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
            wrapper.Children.Add(toggle);
            Grid.SetColumn(wrapper, 2);
            row.Children.Add(wrapper);

            _actionToggles.Add((id, toggle, wrapper));
            rows.Children.Add(row);
        }

        return StepPanel(
            Header("", "Choose Your Actions", "Pick which actions appear on the toolbar."),
            Secondary("You can enable all of these. You can change this later in Settings → Actions."),
            Card(rows));
    }

    /// <summary>macOS setEnabled: turning an action on also puts it on the toolbar row.</summary>
    private void SetActionEnabled(ActionIdentifier id, bool enabled) => Save(
        "actions",
        s => enabled
            ? ToolbarLayout.WithPrincipal(ToolbarLayout.WithEnabled(s, id, true), id, true)
            : ToolbarLayout.WithEnabled(s, id, false));

    private UIElement FinishStep()
    {
        _loginToggle = Switch("Start PopGuy at login");
        _loginToggle.Toggled += (_, _) => OnLoginToggled();
        _loginErrorText = new TextBlock { Style = Res("CriticalTextStyle"), Visibility = Visibility.Collapsed };

        var tour = new StackPanel { Spacing = 8 };
        tour.Children.Add(TourRow("", "Select text and press Ctrl+C+C, or turn on Show on text selection in Settings."));
        tour.Children.Add(TourRow(
            SymbolMap.Glyph("wand.and.stars"),
            "Click Improve to rewrite selected text with AI; a diff shows what changed before you apply."));
        tour.Children.Add(TourRow(SymbolMap.Glyph("globe"), "Click Translate to convert text to your target language."));
        tour.Children.Add(TourRow("", "Press Ctrl+C+C (double-tap) on selected text to show the toolbar."));
        tour.Children.Add(TourRow("", "Create custom AI actions in Settings with your own system prompt."));

        var openSettings = new Button { Content = "Open Settings…" };
        openSettings.Click += (_, _) => _openSettings();
        var more = new StackPanel { Spacing = 8 };
        more.Children.Add(Secondary(
            "You can change everything — providers, shortcuts, actions, and more — anytime in Settings."));
        more.Children.Add(openSettings);

        return StepPanel(
            Header("", "You're All Set", "Start PopGuy at login so it's always ready."),
            _loginToggle,
            _loginErrorText,
            tour,
            more);
    }

    // Settings.

    /// <summary>Queued: a change may be saved from any thread.</summary>
    private void OnSettingsChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>Every switch shows the current settings.</summary>
    private void Refresh()
    {
        if (_closing) return;
        var current = _services.Settings.Current;
        _syncing = true;
        _chordToggle.IsOn = current.TriggerChordEnabled;
        _replacementRow.IsEnabled = current.TriggerChordEnabled;
        _replacementRow.Opacity = current.TriggerChordEnabled ? 1 : 0.5;
        if (!_recorder.IsRecording) _recorder.Shortcut = current.ChordReplacementShortcut;
        _onSelectToggle.IsOn = current.TriggerOnSelectEnabled;
        foreach (var (id, toggle, wrapper) in _actionToggles)
        {
            // Locked while it is the only enabled action: the toolbar needs at least one (macOS isLastEnabledAction).
            var last = ToolbarLayout.IsLastEnabledAction(current, id);
            toggle.IsOn = ToolbarLayout.IsEnabled(current, id);
            toggle.IsEnabled = !last;
            toggle.Opacity = last ? 0.35 : 1;
            HoverTooltip.SetText(wrapper, last
                ? "Keep at least one action on. Turn on another action first."
                : "Turn this action on or off");
        }
        _syncing = false;
        RefreshRecorderButtons();
    }

    /// <summary>Saves one change; a failed write is logged and the switches go back to the saved settings.</summary>
    private void Save(string key, Func<AppSettings, AppSettings> change)
    {
        if (_syncing) return;
        try
        {
            _services.Settings.Update(change);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _services.Log.Write($"settings: {key} not saved, {e.GetType().Name}");
            Refresh();
        }
    }

    // The Ctrl+C+C replacement (as Settings → Triggers).

    /// <summary>The hotkeys go off first, so the combo the user presses reaches the recorder.</summary>
    private void OnRecordingStarted()
    {
        _services.SetHotkeysSuspended(true);
        RefreshRecorderButtons();
    }

    private void OnRecordingEnded(ShortcutKeyOutcome outcome, Shortcut? recorded)
    {
        if (outcome == ShortcutKeyOutcome.Record)
            Save("chordReplacementShortcut", s => s with { ChordReplacementShortcut = recorded });
        else if (outcome == ShortcutKeyOutcome.Clear)
            Save("chordReplacementShortcut", s => s with { ChordReplacementShortcut = null });
        _services.SetHotkeysSuspended(false);
        RefreshRecorderButtons();
    }

    /// <summary>macOS: the clear button only with a shortcut; neither button while recording.</summary>
    private void RefreshRecorderButtons()
    {
        var recording = _recorder.IsRecording;
        _clearButton.Visibility = !recording && _recorder.Shortcut is not null ? Visibility.Visible : Visibility.Collapsed;
        _chordBadge.Visibility = !recording && _recorder.Shortcut is null ? Visibility.Visible : Visibility.Collapsed;
        _recordButton.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
    }

    // Start at login (as Settings → General).

    private void RefreshLogin()
    {
        bool enabled;
        try
        {
            enabled = LaunchAtLogin.IsEnabled();
            ShowLoginError(null);
        }
        catch (Exception e) when (IsRegistryError(e))
        {
            enabled = false;
            ShowLoginError($"Could not read launch at login: {e.Message}");
        }
        _syncing = true;
        _loginToggle.IsOn = enabled;
        _syncing = false;
    }

    /// <summary>Writes the Run key (a few microseconds); on failure the switch goes back and the error shows.</summary>
    private void OnLoginToggled()
    {
        if (_syncing) return;
        var enable = _loginToggle.IsOn;
        try
        {
            LaunchAtLogin.SetEnabled(enable);
            ShowLoginError(null);
        }
        catch (Exception e) when (IsRegistryError(e))
        {
            _services.Log.Write($"launch at login: not {(enable ? "enabled" : "disabled")}, {e.GetType().Name}");
            _syncing = true;
            _loginToggle.IsOn = !enable;
            _syncing = false;
            ShowLoginError($"Could not {(enable ? "enable" : "disable")} launch at login: {e.Message}");
        }
    }

    private void ShowLoginError(string? message)
    {
        _loginErrorText.Text = message ?? "";
        _loginErrorText.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private static bool IsRegistryError(Exception e) =>
        e is IOException or UnauthorizedAccessException or SecurityException or InvalidOperationException;

    // Building blocks.

    private static StackPanel StepPanel(params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = 16 };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    /// <summary>macOS OnboardingHeader: the step's icon, title and subtitle.</summary>
    private Grid Header(string glyph, string title, string subtitle)
    {
        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = Icon(glyph, "AccentIconStyle", 28);
        icon.VerticalAlignment = VerticalAlignment.Top;
        grid.Children.Add(icon);
        var text = new StackPanel { Spacing = 4 };
        text.Children.Add(new TextBlock { Text = title, Style = AppStyle("SubtitleTextBlockStyle"), TextWrapping = TextWrapping.Wrap });
        text.Children.Add(Secondary(subtitle));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    private Border Card(params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = 10 };
        foreach (var child in children) panel.Children.Add(child);
        return new Border { Style = Res("CardStyle"), Child = panel };
    }

    /// <summary>An icon beside wrapped secondary text (a warning, a tour row).</summary>
    private Grid Note(string glyph, string iconStyle, string text)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = Icon(glyph, iconStyle, 14);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 3, 0, 0);
        grid.Children.Add(icon);
        var body = Secondary(text);
        Grid.SetColumn(body, 1);
        grid.Children.Add(body);
        return grid;
    }

    private Grid TourRow(string glyph, string text)
    {
        var row = Note(glyph, "SecondaryIconStyle", text);
        ((FrameworkElement)row.Children[0]).Width = 18;
        var body = (TextBlock)row.Children[1];
        body.Style = AppStyle("BodyTextBlockStyle");
        body.TextWrapping = TextWrapping.Wrap;
        return row;
    }

    private TextBlock Secondary(string text) => new() { Text = text, Style = Res("SecondaryTextStyle") };

    private FontIcon Icon(string glyph, string style, double size) =>
        new() { Glyph = glyph, FontSize = size, Style = Res(style), VerticalAlignment = VerticalAlignment.Center };

    private static ToggleSwitch Switch(string header) => new() { Header = header };

    private static Button IconButton(string glyph, string tooltip)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            Style = AppStyle("SubtleButtonStyle"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(button, tooltip);
        HoverTooltip.SetText(button, tooltip);
        return button;
    }

    private Style Res(string key) => (Style)RootGrid.Resources[key];

    private static Style AppStyle(string key) => (Style)Application.Current.Resources[key];

    // Lifetime.

    /// <summary>A shortcut recording ends when the window goes to the back: PopGuy's hotkeys are off while it records.</summary>
    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) ShortcutRecorder.CancelActive();
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _closing = true;
        ShortcutRecorder.CancelActive();
        _services.Settings.Changed -= OnSettingsChanged;
        RootGrid.PreviewKeyDown -= OnPreviewKeyDown;
        Activated -= OnFirstActivated;
        Activated -= OnActivated;
        CompositionTarget.Rendering -= OnFirstPresentedRendering;
        _presentedTimer?.Stop();
        _backstopTimer?.Stop();
        Closed -= OnClosed;
    }

    // First show: on a cold launch the window can show Mica but no XAML text until the next layout, and the wizard is the
    // first window of a first launch. As SettingsWindow (its comment has the finding): everything is taken out and put back
    // in one tick, 300 ms after the first presented frame and once more 1.5 s after the window first shows.

    private void OnFirstActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) return;
        Activated -= OnFirstActivated;
        CompositionTarget.Rendering += OnFirstPresentedRendering;
        _backstopTimer = StartOnce(TimeSpan.FromSeconds(1.5));
    }

    private void OnFirstPresentedRendering(object? sender, object e)
    {
        if (!_closing && (e is not RenderingEventArgs args || args.RenderingTime <= TimeSpan.Zero)) return;
        CompositionTarget.Rendering -= OnFirstPresentedRendering;
        if (!_closing) _presentedTimer = StartOnce(TimeSpan.FromMilliseconds(300));
    }

    private DispatcherQueueTimer StartOnce(TimeSpan delay)
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = delay;
        timer.IsRepeating = false;
        timer.Tick += (t, _) =>
        {
            t.Stop();
            Reattach();
        };
        timer.Start();
        return timer;
    }

    /// <summary>Skipped while closing, minimized, hidden or recording (leaving the tree cancels a recording).</summary>
    private void Reattach()
    {
        if (_closing || !AppWindow.IsVisible || _recorder.IsRecording) return;
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized }) return;
        var content = RootHost.Content;
        RootHost.Content = null;
        RootHost.Content = content;
    }

    // Placement: a fixed client size in DIPs, centered on the primary display's work area.

    private void Place()
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = MonitorInfo.Scale(new DrawingPoint(work.X + work.Width / 2, work.Y + work.Height / 2));
        var side = (int)Math.Round(ClientSize * scale);
        AppWindow.ResizeClient(new SizeInt32(Math.Min(side, work.Width), Math.Min(side, work.Height)));
        var size = AppWindow.Size;
        AppWindow.Move(new PointInt32(
            work.X + Math.Max(0, (work.Width - size.Width) / 2), work.Y + Math.Max(0, (work.Height - size.Height) / 2)));
    }
}
