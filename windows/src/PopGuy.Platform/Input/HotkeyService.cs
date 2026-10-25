using System.ComponentModel;
using PopGuy.Core.Actions;
using PopGuy.Core.Settings;

namespace PopGuy.Platform.Input;

/// <summary>Whether a hotkey from the settings works, for the Settings UI.</summary>
public enum HotkeyStatus
{
    /// <summary>Registered: a press fires <see cref="HotkeyService.Fired"/>.</summary>
    Registered,

    /// <summary>Another app (or another binding here) already has these keys (ERROR_HOTKEY_ALREADY_REGISTERED).</summary>
    InUse,

    /// <summary>Windows refused the keys for another reason (no key, an unknown modifier, a reserved combination).</summary>
    Invalid,
}

/// <summary>One hotkey from the settings and how its registration went.</summary>
/// <param name="Id">The action it runs, or <see cref="HotkeyService.ChordReplacementId"/> / <see cref="HotkeyService.OcrCaptureId"/>.</param>
/// <param name="Shortcut">The keys.</param>
/// <param name="Status">Whether it works.</param>
public sealed record HotkeyRegistration(ActionIdentifier Id, Shortcut Shortcut, HotkeyStatus Status);

/// <summary>
/// The settings' global hotkeys (spec-1 §1.5): every <see cref="AppSettings.ShortcutBindings"/> entry, the chord
/// replacement (when the chord is on) and the OCR shortcut (when OCR is on), registered through
/// <see cref="GlobalInput.Register"/> (RegisterHotKey with MOD_NOREPEAT on the input thread's message-only window,
/// so the hotkeys' keys also reach <see cref="GlobalInput.Keys"/> with their codes). Hotkeys consume the keystroke.
/// <para>
/// <see cref="Apply"/> unregisters everything, then registers everything again: call it on every change of the
/// bindings, custom actions, the chord flag or replacement, or the OCR flag or shortcut. A refused hotkey is not an
/// error: its <see cref="HotkeyRegistration.Status"/> says why, and the others still work. Whether a fired action
/// exists and is enabled (and whether PopGuy is on) is the App's check at fire time.
/// </para>
/// <para>
/// Threading: RegisterHotKey and UnregisterHotKey only work on the thread that owns the window; GlobalInput runs
/// every registration there (it posts to the input thread and waits, up to 5 s), so <see cref="Apply"/> may be called
/// from any thread (it blocks briefly; calls are serialized). <see cref="Fired"/> is raised on the thread pool.
/// Ids are reused across <see cref="Apply"/> calls, so a press already queued when the keys change may run the
/// binding that now has its id (a window of a few milliseconds).
/// </para>
/// </summary>
public sealed class HotkeyService : IDisposable
{
    /// <summary>The chord-replacement hotkey's sentinel id (the macOS app's UUID; no real custom action has it).</summary>
    public static ActionIdentifier ChordReplacementId { get; } =
        ActionIdentifier.Custom(Guid.Parse("00000000-0000-0000-0000-000000504F50"));

    /// <summary>The OCR screen-text-capture hotkey's sentinel id (the macOS app's UUID).</summary>
    public static ActionIdentifier OcrCaptureId { get; } =
        ActionIdentifier.Custom(Guid.Parse("00000000-0000-0000-0000-00004F4352AA"));

    private readonly GlobalInput _input;
    private readonly Action<string>? _log;
    private readonly Lock _applyLock = new();
    private readonly CancellationTokenSource _stop = new();

    /// <summary>The registered ids' targets; replaced whole by <see cref="Apply"/>, read by the hotkey loop.</summary>
    private volatile IReadOnlyDictionary<int, ActionIdentifier> _targets = new Dictionary<int, ActionIdentifier>();

    /// <summary>The GlobalInput ids registered now. Under <see cref="_applyLock"/>.</summary>
    private readonly List<int> _ids = [];

    private volatile IReadOnlyList<HotkeyRegistration> _registrations = [];

    /// <summary>Starts reading <see cref="GlobalInput.HotKeys"/> (this service must be its only reader). Registers nothing until <see cref="Apply"/>.</summary>
    /// <param name="log">Gets refused registrations and failures.</param>
    public HotkeyService(GlobalInput input, Action<string>? log = null)
    {
        _input = input;
        _log = log;
        _ = Task.Run(ReadHotKeysAsync);
    }

    /// <summary>A registered hotkey was pressed: the action's id, or a sentinel (<see cref="ChordReplacementId"/>, <see cref="OcrCaptureId"/>).</summary>
    public event Action<ActionIdentifier>? Fired;

    /// <summary>Every hotkey of the last <see cref="Apply"/>, in order, with its status. Any thread.</summary>
    public IReadOnlyList<HotkeyRegistration> Registrations => _registrations;

    /// <summary>Re-registers every hotkey of <paramref name="settings"/> and returns <see cref="Registrations"/>. Any thread.</summary>
    public IReadOnlyList<HotkeyRegistration> Apply(AppSettings settings)
    {
        var wanted = settings.ShortcutBindings.Select(b => (b.Id, b.Shortcut)).ToList();
        if (settings.TriggerChordEnabled && settings.ChordReplacementShortcut is { } replacement)
        {
            wanted.Add((ChordReplacementId, replacement));
        }
        if (settings.OcrEnabled && settings.OcrShortcut is { } ocr) wanted.Add((OcrCaptureId, ocr));

        lock (_applyLock)
        {
            UnregisterAll();
            var targets = new Dictionary<int, ActionIdentifier>();
            var registrations = new List<HotkeyRegistration>(wanted.Count);
            foreach (var (id, shortcut) in wanted)
            {
                var status = Register(shortcut, out var hotKeyId);
                if (status == HotkeyStatus.Registered)
                {
                    _ids.Add(hotKeyId);
                    targets[hotKeyId] = id;
                }
                else
                {
                    _log?.Invoke($"hotkeys: {shortcut} not registered, {status}");
                }
                registrations.Add(new(id, shortcut, status));
            }
            _targets = targets;
            _registrations = registrations;
            return registrations;
        }
    }

    /// <summary>Unregisters every hotkey and stops reading. Does not dispose the <see cref="GlobalInput"/>.</summary>
    public void Dispose()
    {
        _stop.Cancel();
        lock (_applyLock)
        {
            UnregisterAll();
            _targets = new Dictionary<int, ActionIdentifier>();
            _registrations = [];
        }
    }

    private HotkeyStatus Register(Shortcut shortcut, out int hotKeyId)
    {
        hotKeyId = 0;
        // VK codes run 0x01–0xFE; 0 is no key.
        if (shortcut.VirtualKey is 0 or > 0xFE) return HotkeyStatus.Invalid;
        try
        {
            // ShortcutModifiers has RegisterHotKey's MOD_* values, like HotKeyModifiers.
            hotKeyId = _input.Register((HotKeyModifiers)shortcut.Modifiers, shortcut.VirtualKey);
            return HotkeyStatus.Registered;
        }
        catch (Win32Exception e) when (e.NativeErrorCode == GlobalInput.ErrorAlreadyRegistered)
        {
            return HotkeyStatus.InUse;
        }
        catch (Exception e) when (e is Win32Exception or ArgumentOutOfRangeException or InvalidOperationException or TimeoutException)
        {
            _log?.Invoke($"hotkeys: register failed, {e.GetType().Name} {e.Message}");
            return HotkeyStatus.Invalid;
        }
    }

    /// <summary>Under <see cref="_applyLock"/>.</summary>
    private void UnregisterAll()
    {
        foreach (var id in _ids)
        {
            try
            {
                _input.Unregister(id);
            }
            catch (Exception e) when (e is TimeoutException or ObjectDisposedException)
            {
                _log?.Invoke($"hotkeys: unregister failed, {e.GetType().Name}");
            }
        }
        _ids.Clear();
    }

    private async Task ReadHotKeysAsync()
    {
        try
        {
            await foreach (var id in _input.HotKeys.ReadAllAsync(_stop.Token).ConfigureAwait(false))
            {
                if (!_targets.TryGetValue(id, out var target)) continue;
                try
                {
                    Fired?.Invoke(target);
                }
                catch (Exception e)
                {
                    _log?.Invoke($"hotkeys: a Fired handler threw, {e.GetType().Name} {e.Message}");
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }
}
