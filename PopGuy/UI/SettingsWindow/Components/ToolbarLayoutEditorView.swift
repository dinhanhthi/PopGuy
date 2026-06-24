// ToolbarLayoutEditorView.swift
// PopGuy — UI/SettingsWindow/Components
//
// Interactive drag-and-drop editor for principal vs burger toolbar layout.
// Replaces the read-only ToolbarPreviewView at the top of the Actions tab.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import AppKit
import SwiftUI

// MARK: - Drag payload

private enum LayoutDragPayload {
    static func encode(_ id: ActionIdentifier) -> String? {
        guard let data = try? JSONEncoder().encode(id) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ string: String) -> ActionIdentifier? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ActionIdentifier.self, from: data)
    }
}

// MARK: - ToolbarLayoutEditorView

struct ToolbarLayoutEditorView: View {
    @ObservedObject var settings: SettingsStore

    @State private var draggingID: ActionIdentifier?
    @State private var isBurgerOpen = false
    @State private var rejectionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image("ToolbarLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                principalRow

                burgerControl

                Spacer(minLength: 8)

                capacityHints
            }

            if let rejectionMessage {
                Text(rejectionMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.12))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Principal row

    private var principalRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(settings.principalOrderedIdentifiers.enumerated()), id: \.element) { index, id in
                layoutChip(for: id, isDragging: draggingID == id)
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, principal: true, atIndex: index)
                    }
            }

            if settings.principalOrderedIdentifiers.isEmpty {
                dropPlaceholder(label: "Drop actions here")
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, principal: true, atIndex: 0)
                    }
            } else {
                Color.clear
                    .frame(width: 12, height: 32)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, principal: true, atIndex: settings.principalOrderedIdentifiers.count)
                    }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: Burger control

    private var burgerControl: some View {
        Button {
            isBurgerOpen.toggle()
        } label: {
            ZStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)

                if draggingID != nil && settings.overflowOrderedIdentifiers.isEmpty {
                    Text("Drop")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .offset(y: 14)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(draggingID != nil ? 0.18 : 0.10))
        )
        .hoverTooltip("More menu — drag actions here")
        .dropDestination(for: String.self) { items, _ in
            if !isBurgerOpen { isBurgerOpen = true }
            return handleDrop(items, principal: false, atIndex: settings.overflowOrderedIdentifiers.count)
        }
        .popover(isPresented: $isBurgerOpen, arrowEdge: .bottom) {
            burgerPopoverContent
        }
    }

    private var burgerPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("More menu")
                .font(.headline)

            if settings.overflowOrderedIdentifiers.isEmpty {
                dropPlaceholder(label: "No overflow actions yet")
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, principal: false, atIndex: 0)
                    }
            } else {
                ForEach(Array(settings.overflowOrderedIdentifiers.enumerated()), id: \.element) { index, id in
                    layoutChip(for: id, isDragging: draggingID == id)
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, principal: false, atIndex: index)
                        }
                }

                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, principal: false, atIndex: settings.overflowOrderedIdentifiers.count)
                    }
            }
        }
        .padding(16)
        .frame(minWidth: 220)
    }

    private var capacityHints: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(settings.principalActionCount)/\(ProConfig.maxPrincipalActions) toolbar")
            Text("\(settings.overflowActionCount)/\(ProConfig.maxBurgerActions) More")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: Chips

    @ViewBuilder
    private func layoutChip(for id: ActionIdentifier, isDragging: Bool) -> some View {
        HStack(spacing: 6) {
            chipIcon(for: id)
                .frame(width: 16, height: 16)
            Text(chipLabel(for: id))
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isDragging ? 0.22 : 0.12))
        )
        .opacity(isDragging ? 0.55 : 1)
        .hoverTooltip(chipLabel(for: id))
        .onDrag {
            draggingID = id
            let token = LayoutDragPayload.encode(id) ?? ""
            return NSItemProvider(object: token as NSString)
        }
    }

    private func dropPlaceholder(label: String) -> some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(minWidth: 80, minHeight: 32)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    // MARK: Drop handling

    private func handleDrop(_ items: [String], principal: Bool, atIndex: Int) -> Bool {
        defer { draggingID = nil }
        guard let token = items.first, let id = LayoutDragPayload.decode(token) else { return false }

        if settings.moveAction(id, toZone: principal, atIndex: atIndex) {
            rejectionMessage = nil
            return true
        }

        rejectionMessage = principal
            ? "Toolbar row is full (\(ProConfig.maxPrincipalActions)/\(ProConfig.maxPrincipalActions)). Free a slot first."
            : "More menu is full (\(ProConfig.maxBurgerActions)/\(ProConfig.maxBurgerActions)). Free a slot first."

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if rejectionMessage != nil { rejectionMessage = nil }
        }
        return false
    }

    // MARK: Action metadata

    private func chipLabel(for id: ActionIdentifier) -> String {
        switch id {
        case .builtin(.improve):   return "Improve"
        case .builtin(.shorten):   return "Shorten"
        case .builtin(.proofread): return "Proofread"
        case .builtin(.prompt):    return "Prompt"
        case .builtin(.translate): return "Translate"
        case .speak:               return "Speak"
        case .dictionary:          return "Look up"
        case .custom(let uuid):
            return settings.customActions.first(where: { $0.id == uuid })?.title ?? "Custom"
        }
    }

    @ViewBuilder
    private func chipIcon(for id: ActionIdentifier) -> some View {
        switch id {
        case .builtin(.improve):
            Image(systemName: "wand.and.stars")
        case .builtin(.shorten):
            Image(systemName: "text.badge.minus")
        case .builtin(.proofread):
            Image(systemName: "checkmark.bubble")
        case .builtin(.prompt):
            Image(systemName: "bubble.and.pencil")
        case .builtin(.translate):
            Image(systemName: "character.bubble")
        case .speak:
            Image(systemName: "speaker.wave.2")
        case .dictionary:
            Image(systemName: "character.book.closed")
        case .custom(let uuid):
            if let action = settings.customActions.first(where: { $0.id == uuid }) {
                ActionIconView(icon: action.icon, font: .caption)
            } else {
                Image(systemName: "sparkles")
            }
        }
    }
}
