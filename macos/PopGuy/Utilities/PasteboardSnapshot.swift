// PasteboardSnapshot.swift
// PopGuy
//
// A value-type snapshot of an NSPasteboard's contents at a point in time.
// Provides restore capability so the caller can undo a synthetic Cmd+C
// without clobbering the user's clipboard.
//
// Used by: ClipboardFallback (Phase 1), OutputHandler (Phase 2).
//
// Actor isolation: capture() and restore() are @MainActor because NSPasteboard
// is a main-thread-only AppKit object. The struct itself is Sendable (pure
// value type with Data/String/Int members) so snapshots can be moved across
// actor boundaries if needed, but capture/restore must happen on the main actor.

import AppKit

/// A point-in-time copy of a pasteboard's contents.
///
/// Sendable: this is a value type holding only Sendable values (String, Data,
/// Int). NSPasteboardItem is NOT directly copied — we extract raw Data per type
/// to make the snapshot fully value-typed and Sendable.
struct PasteboardSnapshot: Sendable {
    /// The `changeCount` of the board at snapshot time.
    /// Use this to detect whether the board was modified between snapshot and restore.
    let changeCount: Int

    /// Per-item data, keyed by pasteboard type raw string.
    struct Item: Sendable {
        let dataByType: [String: Data]
    }

    let items: [Item]

    // MARK: - Factory

    /// Snapshot the current contents of the given pasteboard.
    /// Must be called on the main actor (NSPasteboard is main-thread-only).
    @MainActor
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let changeCount = pasteboard.changeCount
        let items: [Item] = (pasteboard.pasteboardItems ?? []).map { pbItem in
            var dataByType: [String: Data] = [:]
            for type_ in pbItem.types {
                if let data = pbItem.data(forType: type_) {
                    dataByType[type_.rawValue] = data
                }
            }
            return Item(dataByType: dataByType)
        }
        return PasteboardSnapshot(changeCount: changeCount, items: items)
    }

    // MARK: - Restore

    /// Write the snapshot's contents back to the given pasteboard,
    /// replacing whatever is there now.
    ///
    /// Must be called on the main actor (NSPasteboard is main-thread-only).
    ///
    /// - Parameter pasteboard: The board to restore. Usually `NSPasteboard.general`.
    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pbItems: [NSPasteboardItem] = items.map { item in
            let pbItem = NSPasteboardItem()
            for (typeString, data) in item.dataByType {
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(typeString))
            }
            return pbItem
        }
        pasteboard.writeObjects(pbItems)
    }
}
