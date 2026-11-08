using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PopGuy.Controls;
using PopGuy.Core.Actions;
using PopGuy.Core.Settings;
using PopGuy.Platform.Input;

namespace PopGuy.Settings.Pages;

/// <summary>
/// The shortcut rows' shared parts on Triggers, Terminal Composer and Emoji: a refused hotkey's message under its row, and the
/// recorder's clear and record buttons.
/// </summary>
internal static class ShortcutRowStatus
{
    /// <summary>macOS: the clear button only with a shortcut; neither button while recording.</summary>
    internal static void RefreshButtons(ShortcutRecorder recorder, Button clear, Button record)
    {
        var recording = recorder.IsRecording;
        clear.Visibility = !recording && recorder.Shortcut is not null ? Visibility.Visible : Visibility.Collapsed;
        record.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
    }

    internal static void Show(TextBlock text, string? message)
    {
        text.Text = message ?? "";
        text.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>
    /// <paramref name="id"/>'s refusal, if Windows refused it: "Already used by" the PopGuy hotkey that registered the
    /// same keys first (an action, or the Ctrl+C+C replacement for the OCR shortcut), else "another app".
    /// </summary>
    internal static string? Message(
        AppSettings current, IReadOnlyList<HotkeyRegistration> registrations, ActionIdentifier id, Shortcut shortcut)
    {
        var status = registrations.FirstOrDefault(r => r.Id == id && r.Shortcut == shortcut)?.Status;
        var owner = registrations
            .Where(r => r.Id != id && r.Status == HotkeyStatus.Registered && r.Shortcut == shortcut)
            .Select(r => OwnerLabel(current, r.Id))
            .FirstOrDefault(label => label is not null);
        return status switch
        {
            HotkeyStatus.InUse => owner is null ? "Shortcut in use by another app" : $"Already used by {owner}",
            HotkeyStatus.Invalid => "Windows refused this shortcut",
            _ => null,
        };
    }

    /// <summary>A registered hotkey's name in "Already used by …"; null for an id no longer in the settings.</summary>
    private static string? OwnerLabel(AppSettings current, ActionIdentifier id)
    {
        if (id == HotkeyService.ChordReplacementId) return "the Ctrl+C+C replacement";
        if (id == HotkeyService.OcrCaptureId) return "Screen Text Capture";
        if (id == HotkeyService.ComposeId) return "Terminal Composer";
        if (id == HotkeyService.EmojiPickerId) return "Emoji picker";
        return current.ShortcutBindings.Any(b => b.Id == id) ? ActionLabel(current, id) : null;
    }

    /// <summary>An action's label (macOS TriggersView.actionLabel): the Default action picker, and the owner above.</summary>
    internal static string ActionLabel(AppSettings settings, ActionIdentifier id) => id.Type switch
    {
        ActionIdentifierType.Builtin => id.BuiltinKind switch
        {
            ActionKind.Improve => "Improve",
            ActionKind.Shorten => "Shorten",
            ActionKind.Proofread => "Proofread",
            ActionKind.Translate => "Translate",
            ActionKind.Prompt => "Prompt",
            _ => "Custom",
        },
        ActionIdentifierType.Speak => "Speak",
        ActionIdentifierType.Dictionary => "Look up",
        _ => settings.CustomActions.FirstOrDefault(a => a.Id == id.CustomId)?.Title ?? "Custom",
    };
}
