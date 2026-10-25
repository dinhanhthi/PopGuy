namespace PopGuy.Core.Toolbar;

/// <summary>
/// Detects the Ctrl+C+C chord: two chord-key presses strictly under <see cref="ChordWindowMs"/> apart. A port of
/// DoubleTapDetector.swift. The second tap fires and resets, so a third tap re-arms (pairs [1,2], [3,4] fire once
/// each), and any other key resets the pending tap.
/// <para>
/// Pure state machine: the caller passes each event's time and whether it is the chord key. Feed key-downs of
/// non-modifier keys only (the low-level hook reports Ctrl itself as a key; on macOS modifiers never reach the
/// detector), or re-pressing Ctrl between the taps would reset it. Not thread-safe: one input thread feeds it.
/// </para>
/// </summary>
public sealed class DoubleTapDetector(uint chordWindowMs = 300)
{
    public uint ChordWindowMs { get; } = chordWindowMs;

    private uint? _lastTapMs;

    /// <summary>Feeds one key-down; returns true when it completes the chord.</summary>
    /// <param name="timestampMs">
    /// The event's system tick count in milliseconds (the hook's timestamp). The gap is computed unchecked, so the
    /// 49.7-day wrap is harmless.
    /// </param>
    /// <param name="isChordKey">The key is Ctrl+C (Ctrl only, no Shift/Alt/Win); false for any other key.</param>
    public bool Handle(uint timestampMs, bool isChordKey)
    {
        if (!isChordKey)
        {
            _lastTapMs = null;
            return false;
        }
        if (_lastTapMs is { } last && unchecked(timestampMs - last) < ChordWindowMs)
        {
            _lastTapMs = null;
            return true;
        }
        _lastTapMs = timestampMs;
        return false;
    }

    /// <summary>Discards the pending first tap.</summary>
    public void Reset() => _lastTapMs = null;
}
