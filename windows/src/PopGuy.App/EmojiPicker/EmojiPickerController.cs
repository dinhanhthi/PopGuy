using System.Drawing;
using Microsoft.Win32;
using PopGuy.Core;
using PopGuy.Core.Emojis;
using PopGuy.Core.Settings;
using PopGuy.Core.Toolbar;
using PopGuy.Platform.Capture;
using PopGuy.Platform.Output;
using PopGuy.Platform.SystemServices;
using PopGuy.Platform.Windowing;

namespace PopGuy.EmojiPicker;

/// <summary>
/// Owns the Emoji Picker (macOS EmojiPickerController.swift): builds the catalog off the UI thread while the feature is
/// on (<see cref="Preload"/>; <see cref="Unload"/> frees it), opens <see cref="EmojiPickerWindow"/> at the caret of the
/// source app on the hotkey (<see cref="Toggle"/>), and types the pick back into the source.
/// <list type="bullet">
/// <item>Opening: the caret is read off the UI thread (UI Automation, 250 ms at most); a password field opens no picker,
/// an unknown caret opens it at the pointer. A second press while the caret read runs cancels the opening; a stale read
/// is dropped. PopGuy's own windows (or no window) are no source: the picker opens at the pointer and a pick is
/// copied.</item>
/// <item>Catalog not built yet (the hotkey right after the feature was turned on, or at launch): the catalog is never
/// built on the key press; the opening waits for the preload and the picker shows once it finishes, if no newer press
/// came meanwhile.</item>
/// <item>Insertion: the picker hides (handing the foreground back), then the emoji is typed as Unicode key events
/// (<see cref="PasteBack.TypeForEmojiAsync"/>). When that does not go through (the source lost the foreground, runs as
/// administrator, closed, or did not take the keys), the emoji is copied instead; never for a password field or a
/// remote session.</item>
/// </list>
/// UI thread only (its awaits resume there). The picked emoji is never logged, only lengths and reasons.
/// </summary>
internal sealed class EmojiPickerController
{
    private readonly SettingsStore _settings;
    private readonly AppPaths _paths;
    private readonly Func<uint, bool> _isUserKeyDown;
    private readonly Action<string> _log;

    private EmojiPickerWindow? _window;
    private EmojiPickerModel? _model;
    private EmojiFrecency? _frecency;
    private bool _loading;
    private bool _closed;

    /// <summary>Bumped by every catalog build and free, so a stale build is dropped.</summary>
    private int _loadGeneration;

    /// <summary>Bumped by every hotkey press (and by <see cref="Unload"/>), so a stale caret read or opening is dropped.</summary>
    private int _request;

    /// <summary>A caret read runs for the current request.</summary>
    private bool _locating;

    /// <summary>An opening that waits for the catalog: shown when the preload finishes, if its request is still current.</summary>
    private (int Request, Rectangle Caret, bool AtCaret)? _pendingShow;

    /// <summary>The foreground app when the picker opened; the pick goes back to it.</summary>
    private ForegroundApp? _source;

    private sealed record LoadedCatalog(EmojiPickerModel Model, EmojiFrecency Frecency, int Count, double MaxVersion);

    public EmojiPickerController(
        SettingsStore settings, AppPaths paths, Func<uint, bool> isUserKeyDown, Action<string> log)
    {
        _settings = settings;
        _paths = paths;
        _isUserKeyDown = isUserKeyDown;
        _log = log;
    }

    /// <summary>The picker's gear: the App opens Settings on the Emoji Picker page. UI thread.</summary>
    public event Action? SettingsRequested;

    // Catalog.

    /// <summary>
    /// Builds the catalog, its search index and the model in the background (the feature was turned on, or it is on at
    /// launch), then creates the hidden picker window, so the first press shows it at once. No-op when built or building.
    /// </summary>
    public void Preload()
    {
        if (_closed || _model is not null || _loading) return;
        _loading = true;
        _ = LoadAsync(++_loadGeneration, _paths.EmojiUsageFile);
    }

    private async Task LoadAsync(int generation, string usageFile)
    {
        LoadedCatalog? loaded = null;
        try
        {
            loaded = await Task.Run(() => Build(usageFile));
        }
        catch (Exception e)
        {
            _log($"emoji: catalog not built, {e.GetType().Name}");
        }
        // Back on the UI thread. A free (or a newer build) meanwhile: dropped.
        if (generation != _loadGeneration) return;
        _loading = false;
        var pending = _pendingShow;
        _pendingShow = null;
        if (loaded is null || _closed || !_settings.Current.EmojiPickerEnabled) return;
        _model = loaded.Model;
        _frecency = loaded.Frecency;
        _model.Confirmed += OnConfirmed;
        _log($"emoji: catalog loaded ({loaded.Count} entries, up to Emoji {loaded.MaxVersion})");
        EnsureWindow();
        if (pending is { } show && show.Request == _request) Show(show.Request, show.Caret, show.AtCaret);
    }

    /// <summary>The catalog capped at what the system font draws, its index and the model. Thread pool.</summary>
    private static LoadedCatalog Build(string usageFile)
    {
        var maxVersion = EmojiCatalog.MaxEmojiVersion(Environment.OSVersion.Version.Build, ReadUbr());
        var index = new CatalogIndex(EmojiCatalog.Load(maxVersion, hideCountryFlags: true));
        var frecency = new EmojiFrecency(usageFile);
        var model = new EmojiPickerModel(new PickerCatalog(index), new EmojiSearch(index), frecency);
        return new LoadedCatalog(model, frecency, index.Emojis.Count, maxVersion);
    }

    /// <summary>The Windows update build revision (the font updates ship in cumulative updates); 0 when unreadable.</summary>
    private static int ReadUbr()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            return key?.GetValue("UBR") is int ubr ? ubr : 0;
        }
        catch (Exception e) when (e is System.Security.SecurityException or IOException or UnauthorizedAccessException)
        {
            return 0;
        }
    }

    /// <summary>
    /// Hides the picker, cancels an opening in flight, frees the catalog and closes the window (the feature was turned
    /// off).
    /// </summary>
    public void Unload()
    {
        _request++;
        _locating = false;
        _pendingShow = null;
        _loadGeneration++;
        _loading = false;
        _window?.HidePicker();
        if (_model is not null) _model.Confirmed -= OnConfirmed;
        _model = null;
        _frecency = null;
        CloseWindow();
    }

    /// <summary>App exit: frees everything and closes the window; nothing opens afterwards.</summary>
    public void Close()
    {
        if (_closed) return;
        _closed = true;
        Unload();
    }

    /// <summary>Settings' "Clear Frequently Used": deletes the usage history (the next opening re-reads it).</summary>
    public void ClearFrequentlyUsed()
    {
        if (_frecency is { } frecency)
        {
            frecency.Clear();
        }
        else
        {
            try
            {
                File.Delete(_paths.EmojiUsageFile);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                _log($"emoji: usage history not deleted, {e.GetType().Name}");
                return;
            }
        }
        _log("emoji: frequently used cleared");
    }

    // Toggle.

    /// <summary>
    /// The hotkey: hides a visible picker, cancels an opening in flight, or opens the picker at the caret of
    /// <paramref name="source"/> (the foreground app when the hotkey fired).
    /// </summary>
    public void Toggle(ForegroundApp source)
    {
        if (_closed) return;
        if (_window is { IsShown: true } shown)
        {
            shown.HidePicker();
            return;
        }
        var request = ++_request;
        if (_locating || _pendingShow is not null)
        {
            _locating = false;
            _pendingShow = null;
            _log("emoji: opening cancelled");
            return;
        }
        _source = source;
        // PopGuy itself (or nothing) in front: no host caret to read; a pick is copied.
        if (source.Hwnd == 0 || source.IsOwnProcess)
        {
            Show(request, PointerRect(), atCaret: false);
            return;
        }
        _locating = true;
        _ = LocateAsync(request);
    }

    private async Task LocateAsync(int request)
    {
        (Rectangle? Caret, bool IsPassword) read;
        try
        {
            read = await Task.Run(() => UiaSelectionReader.ReadCaret());
        }
        catch (Exception e)
        {
            _log($"emoji: caret not read, {e.GetType().Name}");
            read = (null, false);
        }
        // Back on the UI thread: a newer press (or a free) made this read stale.
        if (request != _request) return;
        _locating = false;
        if (read.IsPassword)
        {
            _log("emoji: password field, no picker");
            return;
        }
        if (read.Caret is { } caret) Show(request, caret, atCaret: true);
        else Show(request, PointerRect(), atCaret: false);
    }

    /// <summary>The pointer, padded vertically like the toolbar's pointer anchor, so the picker never covers it.</summary>
    private static Rectangle PointerRect() =>
        PanelPositioning.PointerAnchor(ToolbarWindowStyle.CursorPosition(), PanelPositioning.PointerVerticalGap);

    // Show / hide.

    private void Show(int request, Rectangle caret, bool atCaret)
    {
        if (_model is not { } model)
        {
            _pendingShow = (request, caret, atCaret);
            Preload();
            _log("emoji: catalog not ready, opening once loaded");
            return;
        }
        var window = EnsureWindow();
        model.Reset();
        window.ShowAt(caret, model, _settings.Current.EmojiSkinTone);
        _log($"emoji: picker shown at the {(atCaret ? "caret" : "pointer")}");
    }

    private EmojiPickerWindow EnsureWindow()
    {
        if (_window is { } existing) return existing;
        var window = new EmojiPickerWindow();
        window.Cancelled += OnCancelled;
        window.SettingsRequested += OnSettingsRequested;
        window.Closed += OnWindowClosed;
        _window = window;
        return window;
    }

    private void CloseWindow()
    {
        if (_window is not { } window) return;
        DetachWindow(window);
        window.ClosePicker();
    }

    private void DetachWindow(EmojiPickerWindow window)
    {
        _window = null;
        window.Cancelled -= OnCancelled;
        window.SettingsRequested -= OnSettingsRequested;
        window.Closed -= OnWindowClosed;
    }

    /// <summary>The window closed without <see cref="CloseWindow"/>: dropped, so the next press builds a new one.</summary>
    private void OnWindowClosed(object sender, Microsoft.UI.Xaml.WindowEventArgs args)
    {
        if (sender is not EmojiPickerWindow window || !ReferenceEquals(window, _window)) return;
        DetachWindow(window);
        _log("emoji: picker window closed, a new one opens on the next press");
    }

    /// <summary>Esc in the search box.</summary>
    private void OnCancelled() => _window?.HidePicker();

    /// <summary>The gear: hides the picker, then the App opens Settings.</summary>
    private void OnSettingsRequested()
    {
        _window?.HidePicker();
        SettingsRequested?.Invoke();
    }

    // Insert.

    /// <summary>A pick (Enter or a click): hides the picker, which hands the foreground back, then types the emoji.</summary>
    private void OnConfirmed(Emoji emoji)
    {
        var text = emoji.Kind == EmojiKind.Symbol ? emoji.Glyph : emoji.Toned(_settings.Current.EmojiSkinTone);
        var source = _source;
        _window?.HidePicker();
        _ = InsertAsync(text, source);
    }

    /// <summary>
    /// Types <paramref name="text"/> into <paramref name="source"/>; copies it instead when that did not go through,
    /// except for a password field or a remote session. Starts on the UI thread: the typing may give the source the
    /// foreground only from there.
    /// </summary>
    private async Task InsertAsync(string text, ForegroundApp? source)
    {
        try
        {
            if (source is null || source.Hwnd == 0 || source.IsOwnProcess)
            {
                await CopyInsteadAsync(text, "noSource");
                return;
            }
            var result = await PasteBack.TypeForEmojiAsync(text, source, _isUserKeyDown, _log);
            if (result.Status == PasteBackStatus.Pasted)
            {
                _log($"emoji: typed ({text.Length} chars)");
                return;
            }
            if (IsSensitiveTargetRefusal(result.Reason))
            {
                _log($"emoji: not typed ({result.Reason}), not copied");
                return;
            }
            await CopyInsteadAsync(text, result.Reason);
        }
        catch (Exception e)
        {
            _log($"emoji: insert failed, {e.GetType().Name}");
        }
    }

    /// <summary>
    /// Puts the pick on the clipboard (off the UI thread, like the toolbar's and the composer's copies). The user did not
    /// ask for this copy, so it stays out of clipboard history and cloud sync, as the composer's "copied instead".
    /// </summary>
    private async Task CopyInsteadAsync(string text, string reason)
    {
        try
        {
            var written = await Task.Run(() => ClipboardGuard.WriteText(text, excludeFromHistory: true));
            _log($"emoji: copied instead ({reason}, {text.Length} chars, written {written})");
        }
        catch (Exception e)
        {
            _log($"emoji: copy failed, {e.GetType().Name}");
        }
    }

    /// <summary>A refusal because the target is sensitive (a password field or a remote session): no copy instead.</summary>
    private static bool IsSensitiveTargetRefusal(string reason) => reason is "passwordField" or "remoteDesktop";
}
