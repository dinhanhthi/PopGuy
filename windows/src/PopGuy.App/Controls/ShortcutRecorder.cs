using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using PopGuy.Core.Settings;
using Windows.System;
using Windows.UI.Core;

namespace PopGuy.Controls;

/// <summary>
/// A shortcut badge that can record a new shortcut (macOS <c>ShortcutBadge</c> and <c>ShortcutRecorder</c>): it shows
/// <see cref="Shortcut"/> ("Ctrl+Shift+Space"), collapsed when there is none; <see cref="Start"/> takes the keyboard focus
/// and shows "Press a shortcut…" until a key press ends it (<see cref="Shortcut.Interpret"/>: Ctrl or Alt required, Esc
/// cancels, Backspace clears, bare modifiers wait). Losing the focus, leaving the tree or <see cref="CancelActive"/>
/// (the window deactivated) cancels. The owner keeps PopGuy's own hotkeys off while it records (they consume their keys
/// before any window sees them). One recorder at a time. UI thread only.
/// </summary>
public sealed partial class ShortcutRecorder : UserControl
{
    /// <summary>The badge, from markup so its theme brushes follow Light and Dark live.</summary>
    private const string BadgeXaml = """
        <Border
            xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            MinHeight="28"
            Padding="10,3,10,3"
            Background="{ThemeResource ControlFillColorSecondaryBrush}"
            BorderBrush="{ThemeResource CardStrokeColorDefaultBrush}"
            BorderThickness="1"
            CornerRadius="{ThemeResource ControlCornerRadius}">
            <Grid>
                <TextBlock VerticalAlignment="Center" />
                <TextBlock
                    VerticalAlignment="Center"
                    FontStyle="Italic"
                    Foreground="{ThemeResource AccentTextFillColorPrimaryBrush}"
                    Text="Press a shortcut…"
                    Visibility="Collapsed" />
            </Grid>
        </Border>
        """;

    private static ShortcutRecorder? _active;

    private readonly TextBlock _shortcutText;
    private readonly TextBlock _promptText;
    private Shortcut? _shortcut;

    /// <summary>The focus came here since <see cref="Start"/>: losing it now cancels.</summary>
    private bool _focused;

    public ShortcutRecorder()
    {
        var badge = (Border)XamlReader.Load(BadgeXaml);
        var grid = (Grid)badge.Child;
        _shortcutText = (TextBlock)grid.Children[0];
        _promptText = (TextBlock)grid.Children[1];
        Content = badge;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        PreviewKeyDown += OnPreviewKeyDown;
        GotFocus += (_, _) => _focused = IsRecording;
        LostFocus += (_, _) =>
        {
            if (_focused) Cancel();
        };
        Unloaded += (_, _) =>
        {
            // The Settings window's re-attach takes the page out and puts it back in one tick.
            if (!IsLoaded) Cancel();
        };
        Update();
    }

    /// <summary>Recording started (the badge has the focus). Raised before any key press.</summary>
    public event Action? RecordingStarted;

    /// <summary>
    /// Recording ended: <see cref="ShortcutKeyOutcome.Record"/> with the new shortcut, <see cref="ShortcutKeyOutcome.Clear"/>
    /// (Backspace) or <see cref="ShortcutKeyOutcome.Cancel"/> (Esc, focus lost, unloaded). <see cref="Shortcut"/> already
    /// shows the outcome.
    /// </summary>
    public event Action<ShortcutKeyOutcome, Shortcut?>? RecordingEnded;

    public bool IsRecording { get; private set; }

    /// <summary>The shortcut the badge shows; null collapses it (unless recording).</summary>
    public Shortcut? Shortcut
    {
        get => _shortcut;
        set
        {
            _shortcut = value;
            Update();
        }
    }

    /// <summary>Cancels the recorder that is recording, if any (its window was deactivated or closed).</summary>
    public static void CancelActive() => _active?.Cancel();

    /// <summary>Shows the prompt and takes the keyboard focus; another recorder that was recording is cancelled.</summary>
    public void Start()
    {
        if (IsRecording) return;
        _active?.Cancel();
        _active = this;
        IsRecording = true;
        _focused = false;
        Update();
        UpdateLayout();
        if (!Focus(FocusState.Programmatic))
        {
            // Just made visible: try again once it is laid out.
            DispatcherQueue.TryEnqueue(() =>
            {
                if (IsRecording) Focus(FocusState.Programmatic);
            });
        }
        RecordingStarted?.Invoke();
    }

    public void Cancel() => End(ShortcutKeyOutcome.Cancel, null);

    private void End(ShortcutKeyOutcome outcome, Shortcut? recorded)
    {
        if (!IsRecording) return;
        IsRecording = false;
        _focused = false;
        if (_active == this) _active = null;
        if (outcome == ShortcutKeyOutcome.Record) _shortcut = recorded;
        else if (outcome == ShortcutKeyOutcome.Clear) _shortcut = null;
        Update();
        RecordingEnded?.Invoke(outcome, recorded);
    }

    /// <summary>Every key press while recording is the recorder's: none reaches the page (Tab, Esc, access keys).</summary>
    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!IsRecording) return;
        e.Handled = true;
        var outcome = Core.Settings.Shortcut.Interpret((uint)e.Key, HeldModifiers(), out var recorded);
        if (outcome != ShortcutKeyOutcome.Ignore) End(outcome, recorded);
    }

    private static ShortcutModifiers HeldModifiers()
    {
        var held = ShortcutModifiers.None;
        if (IsDown(VirtualKey.Control)) held |= ShortcutModifiers.Control;
        if (IsDown(VirtualKey.Menu)) held |= ShortcutModifiers.Alt;
        if (IsDown(VirtualKey.Shift)) held |= ShortcutModifiers.Shift;
        if (IsDown(VirtualKey.LeftWindows) || IsDown(VirtualKey.RightWindows)) held |= ShortcutModifiers.Win;
        return held;
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void Update()
    {
        _shortcutText.Text = _shortcut?.ToString() ?? "";
        _shortcutText.Visibility = IsRecording ? Visibility.Collapsed : Visibility.Visible;
        _promptText.Visibility = IsRecording ? Visibility.Visible : Visibility.Collapsed;
        Visibility = IsRecording || _shortcut is not null ? Visibility.Visible : Visibility.Collapsed;
    }
}
