import Foundation

/// Single source of truth for recording duration cap.
///
/// Both the hold-Fn path (`AppDelegate.startRecording`) and the v0.5.3
/// hands-free path derive their `maxDuration:` from here. Hands-free does
/// **not** configure its own cap — it inherits whatever the user's current
/// timing × backend selection dictates.
///
/// To change the cap, change this function. There should be no other site
/// that hard-codes 60 / 600 for recording duration.
enum RecordingPolicy {

    /// Returns the maximum recording duration (seconds) for the given
    /// timing × backend combination.
    ///
    /// - **live + Qwen → 600 s.** Live streaming runs per-segment ASR with
    ///   bounded per-segment cost and no single-shot risk. 600 s is the
    ///   memory bound (38 MB at 16 kHz mono Float32) — generous enough for
    ///   lecture/meeting dictation.
    /// - **everything else → 60 s.** Bounds the cost of a single
    ///   `Qwen.transcribe` (or Whisper batch) call so long recordings don't
    ///   trigger oom / runaway latency.
    ///
    /// Live mode also requires Qwen backend at the call site (Whisper has no
    /// streaming path); the `backend.isQwen` check here is a defensive
    /// double-guard, not a separate policy.
    static func maxDuration(timing: AppState.TranscriptionTiming,
                            backend: ASRBackend) -> TimeInterval {
        (timing == .live && backend.isQwen) ? 600 : 60
    }
}
