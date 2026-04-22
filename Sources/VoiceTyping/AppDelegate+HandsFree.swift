import AppKit
import Foundation

/// v0.5.3 hands-free dictation. Short Fn tap (< `tapThreshold`) at Fn↑ ⇒
/// recording continues with VAD-driven auto-stop instead of stopping at
/// Fn↑. See `docs/todo/v0.5.3.md` "Hands-free 模式" for the design table.
enum HandsFree {
    /// Fn↑ duration below this threshold counts as a tap (= enter
    /// hands-free). Above ⇒ standard hold-mode stop. 80–100 ms is a typical
    /// deliberate tap; 200 ms gives ~2× headroom without bleeding into
    /// "I really meant to hold" territory.
    static let tapThreshold: TimeInterval = 0.2

    /// After hands-free entry, if no VAD speech event arrives within this
    /// window, auto-cancel (discard audio). Catches accidental taps and
    /// "tap then realise I have nothing to say" cases. 10 s leaves room
    /// for the user to glance at notes before starting.
    static let noSpeechTimeout: TimeInterval = 10.0

    /// After each VAD `.speechEnded`, schedule a stop in this many seconds.
    /// Cancelled by subsequent `.speechStarted`. 1.5 s reads as a comfortable
    /// "end of sentence" pause without prematurely cutting people off mid-
    /// thought.
    static let postSpeechSilence: TimeInterval = 1.5
}

@MainActor
extension AppDelegate {

    // MARK: - Tap-vs-hold decision

    /// Called from `handleFn` on Fn↑. All conditions must hold for hands-free
    /// to take over; any failure falls through to the default `stopRecording`
    /// path so the user gets the existing hold-mode behaviour.
    func shouldEnterHandsFree(duration: TimeInterval) -> Bool {
        guard state.handsFreeEnabled else { return false }
        guard duration < HandsFree.tapThreshold else { return false }
        // The capture session must have actually started (guard against
        // startRecording having bailed on permissions / model state).
        guard state.status == .recording else { return false }
        // Coupled to Qwen for v0.5.3 — Whisper has no streaming/VAD path.
        // Settings UI greys the toggle for non-Qwen so users don't get
        // silent fallbacks, but double-guard here.
        guard activeBackend.isQwen else { return false }
        return true
    }

    // MARK: - Lifecycle

    /// Switch from hold-mode behaviour ("stop on release") to hands-free
    /// behaviour ("stop on silence"). Audio capture is already running —
    /// we just leave it running and arm the watchdog timers.
    func enterHandsFree() {
        handsFreeActive = true
        handsFreeSpeechObserved = false
        state.handsFreeActive = true
        Log.app.info("Hands-free entered — silence threshold \(HandsFree.postSpeechSilence, format: .fixed(precision: 1), privacy: .public)s, no-speech timeout \(HandsFree.noSpeechTimeout, format: .fixed(precision: 1), privacy: .public)s")

        // v0.5.3: brief "tap Fn to cancel" prompt for the first 3 s after
        // entry so first-time users learn the cancel gesture. After 3 s
        // (or sooner if the duration timer overrides it for "Xs left"),
        // capsule falls back to the status-derived text.
        state.capsuleOverlayText = "TAP FN TO CANCEL"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.state.capsuleOverlayText == "TAP FN TO CANCEL" {
                    self.state.capsuleOverlayText = nil
                }
            }
        }

        // Arm the no-speech timeout. First VAD event of any kind cancels it.
        armNoSpeechTimer()
    }

    /// User tapped Fn during hands-free. Discard audio (don't inject) and
    /// reset all the hands-free machinery before falling back to the
    /// standard stopRecording path which writes the audio buffer through
    /// `audio.stop()` and the early-return short-buffer guard.
    func cancelHandsFree() {
        Log.app.info("Hands-free cancelled by user tap")
        // Tear down before stopping so the cleanup hook in stopRecording
        // is a no-op. Stop with a discard flag would be cleaner but the
        // existing pipeline doesn't support it; instead we let
        // stopRecording's short-buffer / pipeline path proceed normally.
        // For the user the perceptible effect is "audio is dropped"
        // because we just zero the recorded buffer.
        cleanupHandsFreeState()
        _ = audio.stop()  // truncate the in-flight capture; result discarded
        state.status = .idle
        capsuleWindow.hide()
        clearRecordingDurationTimer()
        // Abort the debug-capture session for this cancel — no segments,
        // no inject, but we still want the partial meta on disk for
        // analysis (writer.abort writes endedAt + zero counts).
        currentDebugWriter?.abort()
        currentDebugWriter = nil
        // Clean up any live-mode state too (no-op for non-live).
        cleanUpLiveState()
    }

    /// Tear down hands-free timers + watchdog. Called from both the
    /// VAD-silence-triggered stop path and the user-cancel path. Safe to
    /// call when `handsFreeActive` is already false.
    func cleanupHandsFreeState() {
        guard handsFreeActive
                || handsFreeWatchdog != nil
                || handsFreeNoSpeechTask != nil
                || handsFreeSilenceTask != nil
        else { return }

        handsFreeNoSpeechTask?.cancel()
        handsFreeNoSpeechTask = nil
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil
        handsFreeWatchdogIngestTask?.cancel()
        handsFreeWatchdogIngestTask = nil
        handsFreeWatchdog?.stop()
        handsFreeWatchdog = nil
        handsFreeActive = false
        handsFreeSpeechObserved = false
        state.handsFreeActive = false
    }

    // MARK: - VAD wiring

    /// Spin up a VAD-only pump and tee the audio sample stream into both it
    /// and a no-op drain. Used only when hands-free is enabled, the active
    /// backend is Qwen, but live mode is OFF — i.e. one-shot or post-record
    /// timing. In live mode the LiveTranscriber's own `vadObserver` covers
    /// this, so we don't spin up a watchdog there.
    func startHandsFreeWatchdog(samples: AsyncStream<[Float]>,
                                 vadBox: SharedVADBox,
                                 observer: @escaping LiveTranscriber.VADObserver) {
        let watchdog = VADWatchdog(vadBox: vadBox, tuning: .production, observer: observer)
        watchdog.start()
        handsFreeWatchdog = watchdog
        handsFreeWatchdogIngestTask = Task.detached {
            for await chunk in samples {
                watchdog.ingest(samples: chunk)
            }
        }
    }

    /// Receives VAD events from either the LiveTranscriber pump (live mode)
    /// or the VADWatchdog (non-live mode). Bounced to the main actor by the
    /// observer closure in `startRecording`. No-op until hands-free has
    /// been entered — events that arrive between Fn↓ and the Fn↑ tap-vs-hold
    /// decision are ignored.
    func handleHandsFreeVAD(_ event: LiveTranscriber.VADEvent) {
        guard handsFreeActive else { return }

        switch event {
        case .speechStarted:
            markSpeechObserved()
            // Cancel any pending stop — the user resumed talking.
            handsFreeSilenceTask?.cancel()
            handsFreeSilenceTask = nil

        case .speechEnded:
            markSpeechObserved()
            armSilenceTimer()
        }
    }

    // MARK: - Timers

    private func markSpeechObserved() {
        guard !handsFreeSpeechObserved else { return }
        handsFreeSpeechObserved = true
        handsFreeNoSpeechTask?.cancel()
        handsFreeNoSpeechTask = nil
    }

    private func armNoSpeechTimer() {
        handsFreeNoSpeechTask?.cancel()
        handsFreeNoSpeechTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(HandsFree.noSpeechTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.handsFreeActive, !self.handsFreeSpeechObserved else { return }
                Log.app.info("Hands-free no-speech timeout — auto-cancel")
                self.cancelHandsFree()
            }
        }
    }

    private func armSilenceTimer() {
        // Cancel any in-flight silence timer first — speechStarted's
        // cancellation handles the resume case, but we double-guard so
        // back-to-back .speechEnded events (rare but possible from VAD)
        // don't double-arm.
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(HandsFree.postSpeechSilence * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.handsFreeActive else { return }
                Log.app.info("Hands-free silence threshold reached — auto-stop")
                // Standard stopRecording path — runs the existing
                // transcribe + inject pipeline. cleanupHandsFreeState is
                // called inside stopRecording.
                self.stopRecording()
            }
        }
    }
}
