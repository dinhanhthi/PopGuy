// SpeakPhase.swift
// PopGuy — SpeakEngine
//
// Three-state machine that SpeakCoordinator publishes and ToolbarViewModel mirrors.

// MARK: - SpeakPhase

/// The three phases of a speak request lifecycle.
///
/// Transitions:
///   idle → loading  (speak() called, before any engine starts playing)
///   loading → playing  (any engine's onSpeakingChange fires true)
///   playing → idle  (all engines stop, no load in flight)
///   loading → idle  (stop() called during load, or cloud/dictionary returns without starting)
nonisolated enum SpeakPhase: Sendable, Equatable {
    case idle
    case loading
    case playing
}
