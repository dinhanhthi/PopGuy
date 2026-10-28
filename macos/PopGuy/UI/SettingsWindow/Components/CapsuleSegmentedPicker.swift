// CapsuleSegmentedPicker.swift
// PopGuy — UI/SettingsWindow/Components
//
// A segmented control styled as a fully-rounded track with a capsule highlight
// that slides behind the selected segment. Replaces SwiftUI's `.segmented`
// Picker in the Settings window so switching segments animates smoothly.
//
// The highlight slides AND resizes between segments of different widths via a
// matchedGeometryEffect, so no manual width measurement is needed.
//
// Isolation: @MainActor — implicitly via SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.

import SwiftUI

// MARK: - CapsuleSegment

/// One selectable segment: its underlying value and its visible label.
struct CapsuleSegment<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

// MARK: - CapsuleSegmentedPicker

/// A capsule-track segmented control with an animated sliding selection.
struct CapsuleSegmentedPicker<Value: Hashable>: View {

    @Binding var selection: Value
    let segments: [CapsuleSegment<Value>]

    @Namespace private var namespace

    private let animation: Animation = .spring(response: 0.32, dampingFraction: 0.82)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                Button {
                    withAnimation(animation) { selection = segment.value }
                } label: {
                    Text(segment.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 14)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selectedCapsule", in: namespace)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}
