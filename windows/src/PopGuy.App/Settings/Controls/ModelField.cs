using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Providers;
using PopGuy.Settings.ViewModels;
using VirtualKey = Windows.System.VirtualKey;

namespace PopGuy.Settings.Controls;

/// <summary>
/// The Model input of an action card (macOS ModelField): free text, a menu of the provider's suggested models
/// (<see cref="ProviderKindExtensions.CuratedModels"/>), Check (a one-token call through ProviderModelValidator) whose
/// outcome shows for 1 s, and a notice with a one-click replacement when the text is a deprecated id
/// (<see cref="ModelDeprecations"/>). The text is handed to <see cref="Committed"/> 500 ms after the last keystroke, on
/// Enter, when a suggestion is picked and when the box loses focus. Styles come from the owning card, so they follow the
/// theme. UI thread only.
/// </summary>
public sealed partial class ModelField : UserControl
{
    private static readonly TimeSpan SaveDelay = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan FeedbackDuration = TimeSpan.FromSeconds(1);

    private readonly TextBox _box = new() { PlaceholderText = "Model", MinWidth = 200, MaxWidth = 280 };
    private readonly Button _suggestions = new() { Padding = new Thickness(8, 6, 8, 6) };
    private readonly MenuFlyout _suggestionMenu = new();
    private readonly Button _check = new() { Content = "Check" };
    private readonly ProgressRing _ring = new() { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
    private readonly StackPanel _feedback = new() { Orientation = Orientation.Horizontal, Spacing = 6, Visibility = Visibility.Collapsed };
    private readonly FontIcon _feedbackIcon = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _feedbackText = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly Grid _deprecation = new() { ColumnSpacing = 6, Visibility = Visibility.Collapsed };
    private readonly FontIcon _deprecationIcon = new() { Glyph = "\uE7BA", VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _deprecationText = new();
    private readonly Button _replace = new();

    private ActionsViewModel? _model;
    private Func<string, Style>? _style;
    private ProviderKind _kind;
    private IReadOnlyList<string> _shownSuggestions = [];
    private DispatcherQueueTimer? _saveTimer;
    private DispatcherQueueTimer? _dismissTimer;
    private CancellationTokenSource? _checkRun;

    /// <summary>The box is being set from the settings: its change events are not the user's.</summary>
    private bool _syncing;

    public ModelField()
    {
        AutomationProperties.SetName(_box, "Model");
        _suggestions.Content = new FontIcon { FontSize = 12, Glyph = "\uE70D" };
        _suggestions.Flyout = _suggestionMenu;
        AutomationProperties.SetName(_suggestions, "Suggested models");
        HoverTooltip.SetText(_suggestions, "Suggested models");

        var input = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var element in new FrameworkElement[] { _box, _suggestions, _check, _ring })
        {
            element.VerticalAlignment = VerticalAlignment.Center;
            input.Children.Add(element);
        }

        _feedback.HorizontalAlignment = HorizontalAlignment.Right;
        _feedback.Children.Add(_feedbackIcon);
        _feedback.Children.Add(_feedbackText);

        // The notice: icon, text, then the replacement button.
        _deprecation.HorizontalAlignment = HorizontalAlignment.Right;
        for (var i = 0; i < 3; i++) _deprecation.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _deprecation.Children.Add(_deprecationIcon);
        _deprecationText.VerticalAlignment = VerticalAlignment.Center;
        _deprecationText.TextWrapping = TextWrapping.Wrap;
        _deprecationText.MaxWidth = 360;
        Grid.SetColumn(_deprecationText, 1);
        _deprecation.Children.Add(_deprecationText);
        _replace.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(_replace, 2);
        _deprecation.Children.Add(_replace);

        var root = new StackPanel { Spacing = 4 };
        root.Children.Add(input);
        root.Children.Add(_feedback);
        root.Children.Add(_deprecation);
        Content = root;
        IsTabStop = false;

        _box.TextChanged += (_, _) => OnTextChanged();
        _box.LostFocus += (_, _) => Flush();
        _box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            e.Handled = true;
            Flush();
        };
        _check.Click += async (_, _) => await CheckAsync();
        _replace.Click += (_, _) => SetAndCommit(_kind.MigratedModel(_box.Text));
        Unloaded += (_, _) =>
        {
            // The Settings window's re-attach takes the page out and puts it back in one tick.
            if (!IsLoaded) Release();
        };
    }

    /// <summary>The text to save as the action's model.</summary>
    internal event Action<string>? Committed;

    /// <summary>The check runs through <paramref name="model"/>; <paramref name="style"/> resolves the card's styles.</summary>
    internal void Attach(ActionsViewModel model, Func<string, Style> style)
    {
        _model = model;
        _style = style;
        _feedbackText.Style = style("CaptionStyle");
        _deprecationText.Style = style("CaptionStyle");
        _deprecationIcon.Style = style("CautionIconStyle");
    }

    /// <summary>
    /// Shows <paramref name="kind"/>'s suggestions and the saved <paramref name="model"/>; a box being edited keeps its
    /// text. A provider change cancels a running check and clears its outcome.
    /// </summary>
    internal void Show(ProviderKind kind, string model)
    {
        if (kind != _kind)
        {
            _kind = kind;
            CancelCheck();
            HideFeedback();
        }
        var suggestions = kind.CuratedModels();
        if (!suggestions.SequenceEqual(_shownSuggestions))
        {
            _shownSuggestions = suggestions;
            _suggestionMenu.Items.Clear();
            foreach (var id in suggestions)
            {
                var item = new MenuFlyoutItem { Text = id };
                item.Click += (_, _) => SetAndCommit(id);
                _suggestionMenu.Items.Add(item);
            }
        }
        _suggestions.Visibility = suggestions.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _check.Visibility = ActionsViewModel.CanCheckModel(kind) ? Visibility.Visible : Visibility.Collapsed;
        if (_box.FocusState == FocusState.Unfocused && _saveTimer?.IsRunning != true && _box.Text != model)
        {
            _syncing = true;
            _box.Text = model;
            _syncing = false;
        }
        Refresh();
    }

    /// <summary>Hands a pending edit to <see cref="Committed"/> now.</summary>
    internal void Flush()
    {
        if (_saveTimer?.IsRunning == true) Commit();
    }

    /// <summary>The card goes: the pending edit is saved and a running check stops.</summary>
    internal void Release()
    {
        Flush();
        CancelCheck();
        _dismissTimer?.Stop();
    }

    private void OnTextChanged()
    {
        if (_syncing) return;
        HideFeedback();
        Refresh();
        _saveTimer ??= CreateTimer(SaveDelay, Commit);
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void Commit()
    {
        _saveTimer?.Stop();
        Committed?.Invoke(_box.Text);
    }

    private void SetAndCommit(string model)
    {
        _syncing = true;
        _box.Text = model;
        _syncing = false;
        HideFeedback();
        Refresh();
        Commit();
    }

    /// <summary>Check needs a non-blank model and no running check; the notice names a deprecated id's replacement.</summary>
    private void Refresh()
    {
        _check.IsEnabled = _checkRun is null && _box.Text.Trim().Length > 0;
        var replacement = _kind.MigratedModel(_box.Text);
        var deprecated = replacement != _box.Text;
        _deprecation.Visibility = deprecated ? Visibility.Visible : Visibility.Collapsed;
        if (!deprecated) return;
        _deprecationText.Text = $"{_box.Text.Trim()} is deprecated.";
        _replace.Content = $"Use {replacement}";
    }

    // Check.

    private async Task CheckAsync()
    {
        if (_model is null || _checkRun is not null) return;
        var model = _box.Text.Trim();
        if (model.Length == 0) return;
        Flush();
        _dismissTimer?.Stop();
        HideFeedback();
        var run = _checkRun = new CancellationTokenSource();
        ShowRunning(true);
        VerifyOutcome outcome;
        try
        {
            outcome = await _model.CheckModelAsync(_kind, model, run.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        finally
        {
            if (_checkRun == run) _checkRun = null;
            run.Dispose();
            ShowRunning(_checkRun is not null);
        }
        ShowOutcome(outcome);
    }

    private void CancelCheck()
    {
        _checkRun?.Cancel();
        _checkRun = null;
        ShowRunning(false);
    }

    private void ShowRunning(bool running)
    {
        _ring.IsActive = running;
        _ring.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        Refresh();
    }

    private void ShowOutcome(VerifyOutcome outcome)
    {
        if (_style is null) return;
        var (glyph, iconStyle, textStyle) = outcome switch
        {
            VerifyOutcome.Valid => ("\uE73E", "SuccessIconStyle", "CaptionStyle"),
            VerifyOutcome.Invalid => ("\uEA39", "CriticalIconStyle", "ErrorTextStyle"),
            VerifyOutcome.NoKey => ("\uE8D7", "SecondaryIconStyle", "CaptionStyle"),
            _ => ("\uE7BA", "CautionIconStyle", "CaptionStyle"),
        };
        _feedbackIcon.Glyph = glyph;
        _feedbackIcon.Style = _style(iconStyle);
        _feedbackText.Style = _style(textStyle);
        _feedbackText.Text = ActionsViewModel.CheckText(outcome);
        _feedback.Visibility = Visibility.Visible;
        _dismissTimer ??= CreateTimer(FeedbackDuration, HideFeedback);
        _dismissTimer.Stop();
        _dismissTimer.Start();
    }

    private void HideFeedback()
    {
        _dismissTimer?.Stop();
        _feedback.Visibility = Visibility.Collapsed;
    }

    private DispatcherQueueTimer CreateTimer(TimeSpan interval, Action tick)
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = interval;
        timer.IsRepeating = false;
        timer.Tick += (sender, _) =>
        {
            sender.Stop();
            tick();
        };
        return timer;
    }
}
