import Foundation
import SpeechVAD

/// Drives a live mic → VAD → Qwen transcription pipeline. Unlike v0.4.2's
/// post-record `transcribeStreaming(buffer:)`, this consumes audio as it
/// arrives, so by the time the user releases Fn the bulk of the ASR work is
/// already done — perceived latency on long dictation drops from
/// `ASR(total_audio)` to `ASR(last_segment) + drain`.
///
/// Architecture
/// ------------
/// `ingest(samples:)` is called from the audio tap (off the main thread). The
/// pump task drains those chunks, feeds them to a `StreamingVADProcessor`,
/// and on each `.speechEnded` event invokes `recognizer.transcribeSegmentSync`
/// — which serialises against any concurrent batch transcribe via the
/// recognizer's internal `transcribeLock`. Each segment yields the
/// accumulated transcript on `output`.
///
/// `finish()` closes the sample stream; the pump runs `processor.flush()` to
/// emit any tail segment, transcribes it, then completes the `output` stream.
///
/// Output semantics
/// ----------------
/// `output` yields **per-segment text** as each segment finishes — NOT
/// cumulative. Consumer is responsible for accumulating if it wants the full
/// transcript. This deliberate choice lets AppDelegate inject each segment
/// into the focused app the moment it arrives (the live UX), rather than
/// holding back until Fn↑.
///
/// Why not hold a single async-loop lock over the whole pump (like
/// `runStreaming` does for the batch path)? Because the live pump does
/// `for await chunk in sampleStream` — Swift's unfair lock can't be held
/// across awaits. Per-segment lock acquisition is cheap (one transcribe call
/// per ~1-3 s of audio) and lets the (rare) concurrent batch transcribe
/// interleave safely.
///
/// Memory: keeps the entire mic recording in `liveBuffer` for segment slicing.
/// At 16 kHz mono Float32 × 600 s `AudioCapture.maxDuration` cap → 38 MB max.
/// A sliding window would save memory but complicate sample-index bookkeeping
/// (VAD reports sample positions in absolute time); not worth the complexity.
final class LiveTranscriber: @unchecked Sendable {

    /// v0.5.1 Debug Capture hook. Fires once per segment regardless of
    /// HallucinationFilter outcome — `kept` distinguishes which path the text
    /// took. The writer uses this to capture the filter ± analysis (#6 in
    /// `todo/v0.5.1.md`).
    ///
    /// v0.7.1 #B6: extended with per-segment pump instrumentation so we can
    /// see WHERE the time went on slow segments. All `…SinceLast` fields are
    /// reset after each segment; they describe the pump cycle leading up to
    /// THIS segment's transcribe call. See SKILL/comments in `runPump`.
    struct SegmentEvent: Sendable {
        let rawText: String
        let kept: Bool
        /// v0.7.3 #B6: which HallucinationFilter layer dropped this segment.
        /// `nil` when `kept == true`.
        let filterReason: HallucinationFilter.FilterReason?
        let startSec: Double
        let endSec: Double
        let transcribeMs: Int
        let lockWaitMs: Int
        let chunkLagMaxMs: Int
        let pumpStallMaxMs: Int
        let vadProcessSumMs: Int
        let chunksSinceLast: Int
        let forceSplit: Bool
        let flushTriggered: Bool
    }
    typealias SegmentObserver = @Sendable (SegmentEvent) -> Void

    /// v0.7.1 #B6: session-level pump health snapshot. Read after the pump
    /// task finishes (i.e. `lt.finish()` returned and `output` drained), so
    /// AppDelegate can pass these into `DebugCaptureWriter.finalize`.
    struct PumpMetrics: Sendable {
        var chunkLagMaxMs: Int = 0
        var pumpStallMaxMs: Int = 0
        var vadProcessSumMs: Int = 0
        var ingestCount: Int = 0
    }

    /// v0.5.3 hands-free hook. Fires the moment VAD reports a speech-state
    /// transition — *before* the transcribe call. Lets the hands-free state
    /// machine arm/cancel its silence timer without waiting on ASR latency.
    /// Fires on the pump task thread; observer must bounce to its own actor.
    enum VADEvent: Sendable {
        case speechStarted
        case speechEnded
    }
    typealias VADObserver = @Sendable (VADEvent) -> Void

    private let recognizer: QwenASRRecognizer
    private let vadBox: SharedVADBox
    private let tuning: QwenASRRecognizer.StreamingTuning
    private let language: Language
    private let context: String?
    private let segmentObserver: SegmentObserver?
    private let vadObserver: VADObserver?

    let output: AsyncThrowingStream<String, Error>
    private let outputContinuation: AsyncThrowingStream<String, Error>.Continuation

    /// v0.7.1 #B6: chunks carry their `ingest()` wall-clock so the pump can
    /// measure AsyncStream queue lag. A `Date()` allocation per chunk at
    /// 16 kHz / 512-sample frames = ~31 ingests/sec on the audio thread —
    /// negligible vs the audio copy itself.
    private let sampleStream: AsyncStream<(ingestedAt: Date, samples: [Float])>
    private let sampleContinuation: AsyncStream<(ingestedAt: Date, samples: [Float])>.Continuation

    private var pumpTask: Task<Void, Never>?

    /// v0.7.1 #B6: session-level metrics published by the pump task.
    /// `metricsLock` guards every read/write; `pumpMetricsSnapshot` is the
    /// supported reader. Don't read `_pumpMetrics` directly.
    private let metricsLock = NSLock()
    private var _pumpMetrics = PumpMetrics()
    var pumpMetricsSnapshot: PumpMetrics {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return _pumpMetrics
    }

    init(
        recognizer: QwenASRRecognizer,
        vadBox: SharedVADBox,
        tuning: QwenASRRecognizer.StreamingTuning,
        language: Language,
        context: String?,
        segmentObserver: SegmentObserver? = nil,
        vadObserver: VADObserver? = nil
    ) {
        self.recognizer = recognizer
        self.vadBox = vadBox
        self.tuning = tuning
        self.language = language
        self.context = context
        self.segmentObserver = segmentObserver
        self.vadObserver = vadObserver

        let (out, outCont) = AsyncThrowingStream<String, Error>.makeStream()
        self.output = out
        self.outputContinuation = outCont

        // `.unbounded`: live samples must never be dropped — VAD relies on
        // continuous input to maintain its hidden-state hysteresis.
        let (samples, samplesCont) = AsyncStream<(ingestedAt: Date, samples: [Float])>.makeStream(bufferingPolicy: .unbounded)
        self.sampleStream = samples
        self.sampleContinuation = samplesCont
    }

    /// Spawns the pump. Call before `ingest`.
    func start() {
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runPump()
        }
    }

    /// Push a chunk of 16 kHz mono Float32 samples. Safe to call from any thread.
    /// v0.7.1 #B6: stamps the chunk's ingest time so the pump can measure
    /// AsyncStream queue lag.
    func ingest(samples: [Float]) {
        guard !samples.isEmpty else { return }
        sampleContinuation.yield((Date(), samples))
    }

    /// Signal end-of-input. The pump runs VAD flush + tail transcription, then
    /// `output` finishes. Caller should `for try await segment in output {…}`
    /// to receive each segment's text as it arrives.
    func finish() {
        sampleContinuation.finish()
    }

    /// Abort. Cancels the pump and finishes streams. The `output` stream may
    /// still emit one final yield if a transcribe call was already in flight.
    func cancel() {
        pumpTask?.cancel()
        sampleContinuation.finish()
    }

    // MARK: - Pump

    private func runPump() async {
        let vad = vadBox.model
        let lang = language.qwenName
        let ctx: String? = {
            guard let raw = context?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }()
        let maxSegmentDuration = tuning.maxSegmentDuration
        let padSamples = max(0, Int(tuning.paddingSeconds * 16000))

        // Reset VAD state at both ends so a previous live session can't bias
        // the hysteresis state machine. Same defensive pattern as `runStreaming`.
        vad.resetState()
        defer {
            vad.resetState()
            outputContinuation.finish()
        }

        let processor = StreamingVADProcessor(model: vad, config: tuning.buildVADConfig())
        var liveBuffer: [Float] = []
        liveBuffer.reserveCapacity(16_000 * 30)  // typical recording length
        var speechStartSample: Int?
        var emittedSegmentCount = 0

        // v0.7.1 #B6 instrumentation. Two layers:
        //  - per-segment window: reset after each `transcribeSegment` so the
        //    next segment's record describes only the cycles since the prior.
        //  - session totals: kept on the lock-guarded `_pumpMetrics` so
        //    `pumpMetricsSnapshot` reads consistent values after pump finishes.
        var winChunkLagMaxMs = 0
        var winPumpStallMaxMs = 0
        var winVadProcessSumMs = 0
        var winChunksSinceLast = 0
        var sessChunkLagMaxMs = 0
        var sessPumpStallMaxMs = 0
        var sessVadProcessSumMs = 0
        var sessIngestCount = 0
        var lastDrainAt: Date?

        // Closure captures `liveBuffer` by reference via inout-style access
        // through the enclosing function scope — Swift handles this correctly
        // for value types in nested funcs.
        let observer = segmentObserver
        func transcribeSegment(startSample: Int, endSample: Int, forceSplit: Bool, flushTriggered: Bool) {
            let paddedStart = max(0, startSample - padSamples)
            let paddedEnd = min(endSample + padSamples, liveBuffer.count)
            guard paddedStart < paddedEnd else { return }
            let segAudio = Array(liveBuffer[paddedStart..<paddedEnd])
            let segStart = Date()
            let (text, lockWaitMs) = recognizer.transcribeSegmentSync(
                samples: segAudio, language: lang, context: ctx
            )
            let transcribeMs = Int(Date().timeIntervalSince(segStart) * 1000)
            // Snapshot per-segment window metrics, then reset for the next segment.
            let evChunkLagMaxMs = winChunkLagMaxMs
            let evPumpStallMaxMs = winPumpStallMaxMs
            let evVadProcessSumMs = winVadProcessSumMs
            let evChunksSinceLast = winChunksSinceLast
            winChunkLagMaxMs = 0
            winPumpStallMaxMs = 0
            winVadProcessSumMs = 0
            winChunksSinceLast = 0
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let startSec = Double(paddedStart) / 16000
            let endSec = Double(paddedEnd) / 16000
            // Same hallucination filter v0.4.5 added on the batch streaming path.
            // Drops training-data tails (`谢谢观看`, `Thank you.`) and segments
            // that echo the bias `context` we passed (the `热词：…` regurgitation
            // observed on noisy short input). v0.7.3 #B6: classify return so
            // segments.jsonl can record which layer fired.
            let filterReason = HallucinationFilter.classify(segment: trimmed, context: ctx)
            let kept = (filterReason == nil)
            observer?(SegmentEvent(
                rawText: trimmed,
                kept: kept,
                filterReason: filterReason,
                startSec: startSec,
                endSec: endSec,
                transcribeMs: transcribeMs,
                lockWaitMs: lockWaitMs,
                chunkLagMaxMs: evChunkLagMaxMs,
                pumpStallMaxMs: evPumpStallMaxMs,
                vadProcessSumMs: evVadProcessSumMs,
                chunksSinceLast: evChunksSinceLast,
                forceSplit: forceSplit,
                flushTriggered: flushTriggered
            ))
            guard kept else {
                Log.dev(Log.asr, "Live hallucination filtered: \(trimmed)")
                return
            }
            emittedSegmentCount += 1
            // Per-segment yield (NOT cumulative). Consumer assembles deltas.
            outputContinuation.yield(trimmed)
        }

        for await (ingestedAt, chunk) in sampleStream {
            if Task.isCancelled { break }

            // ── per-chunk instrumentation ─────────────────────────────────
            let drainAt = Date()
            let chunkLagMs = Int(drainAt.timeIntervalSince(ingestedAt) * 1000)
            if chunkLagMs > winChunkLagMaxMs { winChunkLagMaxMs = chunkLagMs }
            if chunkLagMs > sessChunkLagMaxMs { sessChunkLagMaxMs = chunkLagMs }
            if let last = lastDrainAt {
                let gapMs = Int(drainAt.timeIntervalSince(last) * 1000)
                if gapMs > winPumpStallMaxMs { winPumpStallMaxMs = gapMs }
                if gapMs > sessPumpStallMaxMs { sessPumpStallMaxMs = gapMs }
            }
            lastDrainAt = drainAt
            winChunksSinceLast += 1
            sessIngestCount += 1
            // ──────────────────────────────────────────────────────────────

            liveBuffer.append(contentsOf: chunk)

            // StreamingVADProcessor buffers internally — feed chunks of any size.
            // The processor returns 0 or more events triggered by completed
            // 512-sample VAD windows.
            //
            // Wrapped with `TranscribeWatchdog` so a hung `model.processChunk`
            // (the v0.7.1 dogfood failure mode — Silero MLX call sometimes
            // sits 30+ s after long idle) auto-captures a `sample(1)` stack of
            // every thread mid-hang. The watchdog timer fires from a utility
            // queue; it cannot interrupt this thread but it can spawn an
            // observer that snapshots us. Threshold 5 s is well above warm
            // p99 (~50 ms) so healthy paths never trigger.
            let vadStart = Date()
            let events = TranscribeWatchdog.run(
                callsite: "live-vad-process",
                samples: chunk.count,
                language: lang,
                contextChars: ctx?.count ?? 0
            ) {
                processor.process(samples: chunk)
            }
            let vadMs = Int(Date().timeIntervalSince(vadStart) * 1000)
            winVadProcessSumMs += vadMs
            sessVadProcessSumMs += vadMs

            for event in events {
                switch event {
                case .speechStarted(let t):
                    vadObserver?(.speechStarted)
                    speechStartSample = Int(t * 16000)
                case .speechEnded(let seg):
                    vadObserver?(.speechEnded)
                    if let start = speechStartSample {
                        let endSample = min(Int(seg.endTime * 16000), liveBuffer.count)
                        transcribeSegment(startSample: start, endSample: endSample,
                                          forceSplit: false, flushTriggered: false)
                        speechStartSample = nil
                    }
                }
            }

            // Force-split if a single utterance exceeds maxSegmentDuration so
            // we don't exhaust Qwen's maxTokens budget on a runaway speech span.
            // v0.5.0 raised this from 10 → 25 s.
            if let start = speechStartSample {
                let now = processor.currentTime
                let speechStart = Float(start) / 16000
                if now - speechStart >= maxSegmentDuration {
                    let endSample = min(Int(now * 16000), liveBuffer.count)
                    transcribeSegment(startSample: start, endSample: endSample,
                                      forceSplit: true, flushTriggered: false)
                    speechStartSample = Int(now * 16000)
                }
            }

        }

        // Sample stream finished (caller called `finish()`). Flush VAD to emit
        // any tail event for an in-progress speech span.
        let flushEvents = processor.flush()
        for event in flushEvents {
            if case .speechEnded(let seg) = event, let start = speechStartSample {
                vadObserver?(.speechEnded)
                let endSample = min(Int(seg.endTime * 16000), liveBuffer.count)
                transcribeSegment(startSample: start, endSample: endSample,
                                  forceSplit: false, flushTriggered: true)
                speechStartSample = nil
            }
        }

        // Edge case: VAD never confirmed any speech (very short / soft / noisy).
        // Mirror the batch path's fallback so the user still gets some output.
        if emittedSegmentCount == 0 && liveBuffer.count >= 400 {
            transcribeSegment(startSample: 0, endSample: liveBuffer.count,
                              forceSplit: false, flushTriggered: true)
        }

        // Publish session totals for `pumpMetricsSnapshot`. Swift 6 forbids
        // raw NSLock.lock()/unlock() across awaits; `withLock` is the
        // async-safe equivalent (no awaits inside, so trivially scoped).
        metricsLock.withLock {
            _pumpMetrics = PumpMetrics(
                chunkLagMaxMs: sessChunkLagMaxMs,
                pumpStallMaxMs: sessPumpStallMaxMs,
                vadProcessSumMs: sessVadProcessSumMs,
                ingestCount: sessIngestCount
            )
        }

        Log.asr.info("LiveTranscriber finished: \(liveBuffer.count) samples / \(emittedSegmentCount) segments emitted / chunkLagMax=\(sessChunkLagMaxMs)ms pumpStallMax=\(sessPumpStallMaxMs)ms vadSum=\(sessVadProcessSumMs)ms")
    }
}
