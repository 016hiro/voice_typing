import Foundation
import SpeechVAD

/// v0.5.3 VAD-only pump for the hands-free path on non-live timing modes
/// (one-shot, post-record). Mirrors `LiveTranscriber`'s VAD wiring without
/// the recognition side — just feeds Silero with mic chunks and emits state
/// transitions to the observer.
///
/// Why a separate type instead of always running `LiveTranscriber`?
/// LiveTranscriber transcribes per segment and injects per segment, which
/// is the live UX. Hands-free under one-shot/post-record timing should keep
/// the user's chosen reveal behavior (single shot at end, or post-record
/// VAD-segmented) — the watchdog's only job is to tell the AppDelegate
/// "speech ended" so the silence timer can arm.
///
/// Lifecycle matches LiveTranscriber: `start()` to spin up the pump,
/// `ingest(samples:)` from the audio tap, `stop()` from `stopRecording`.
/// The observer fires on the pump's task thread; consumers must bounce to
/// their own actor (the AppDelegate hands-free handler bounces to MainActor).
///
/// Concurrency: the pump task owns the `StreamingVADProcessor`; samples come
/// in via an `AsyncStream<[Float]>` so producers (audio thread) don't block.
/// Reuses `LiveTranscriber.VADEvent` so AppDelegate has one event type to
/// branch on regardless of which pump produced it.
final class VADWatchdog: @unchecked Sendable {

    typealias Observer = @Sendable (LiveTranscriber.VADEvent) -> Void

    private let vadBox: SharedVADBox
    private let tuning: QwenASRRecognizer.StreamingTuning
    private let observer: Observer

    private let sampleStream: AsyncStream<[Float]>
    private let sampleContinuation: AsyncStream<[Float]>.Continuation
    private var pumpTask: Task<Void, Never>?

    init(vadBox: SharedVADBox,
         tuning: QwenASRRecognizer.StreamingTuning,
         observer: @escaping Observer) {
        self.vadBox = vadBox
        self.tuning = tuning
        self.observer = observer

        let (s, c) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.sampleStream = s
        self.sampleContinuation = c
    }

    /// Spawn the pump. Call before `ingest`.
    func start() {
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runPump()
        }
    }

    /// Push 16 kHz mono Float32 samples. Safe from any thread.
    func ingest(samples: [Float]) {
        guard !samples.isEmpty else { return }
        sampleContinuation.yield(samples)
    }

    /// Tear down. The pump drains a flush event for any in-progress speech
    /// span before exiting.
    func stop() {
        pumpTask?.cancel()
        sampleContinuation.finish()
    }

    // MARK: - Pump

    private func runPump() async {
        let vad = vadBox.model
        vad.resetState()
        defer { vad.resetState() }

        let processor = StreamingVADProcessor(model: vad, config: tuning.buildVADConfig())

        for await chunk in sampleStream {
            if Task.isCancelled { break }
            let events = processor.process(samples: chunk)
            for event in events {
                switch event {
                case .speechStarted: observer(.speechStarted)
                case .speechEnded:   observer(.speechEnded)
                }
            }
        }

        // Flush any in-progress span so the silence-detect handler sees the
        // tail .speechEnded if we're cancelled mid-utterance.
        for event in processor.flush() {
            if case .speechEnded = event { observer(.speechEnded) }
        }
    }
}
