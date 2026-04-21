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

    private let recognizer: QwenASRRecognizer
    private let vadBox: SharedVADBox
    private let tuning: QwenASRRecognizer.StreamingTuning
    private let language: Language
    private let context: String?

    let output: AsyncThrowingStream<String, Error>
    private let outputContinuation: AsyncThrowingStream<String, Error>.Continuation

    private let sampleStream: AsyncStream<[Float]>
    private let sampleContinuation: AsyncStream<[Float]>.Continuation

    private var pumpTask: Task<Void, Never>?

    init(
        recognizer: QwenASRRecognizer,
        vadBox: SharedVADBox,
        tuning: QwenASRRecognizer.StreamingTuning,
        language: Language,
        context: String?
    ) {
        self.recognizer = recognizer
        self.vadBox = vadBox
        self.tuning = tuning
        self.language = language
        self.context = context

        let (out, outCont) = AsyncThrowingStream<String, Error>.makeStream()
        self.output = out
        self.outputContinuation = outCont

        // `.unbounded`: live samples must never be dropped — VAD relies on
        // continuous input to maintain its hidden-state hysteresis.
        let (samples, samplesCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
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
    func ingest(samples: [Float]) {
        guard !samples.isEmpty else { return }
        sampleContinuation.yield(samples)
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

        // Closure captures `liveBuffer` by reference via inout-style access
        // through the enclosing function scope — Swift handles this correctly
        // for value types in nested funcs.
        func transcribeSegment(startSample: Int, endSample: Int) {
            let paddedStart = max(0, startSample - padSamples)
            let paddedEnd = min(endSample + padSamples, liveBuffer.count)
            guard paddedStart < paddedEnd else { return }
            let segAudio = Array(liveBuffer[paddedStart..<paddedEnd])
            let text = recognizer.transcribeSegmentSync(
                samples: segAudio, language: lang, context: ctx
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Same hallucination filter v0.4.5 added on the batch streaming path.
            // Drops training-data tails (`谢谢观看`, `Thank you.`) and segments
            // that echo the bias `context` we passed (the `热词：…` regurgitation
            // observed on noisy short input).
            if HallucinationFilter.isLikelyHallucination(segment: trimmed, context: ctx) {
                Log.dev(Log.asr, "Live hallucination filtered: \(trimmed)")
                return
            }
            emittedSegmentCount += 1
            // Per-segment yield (NOT cumulative). Consumer assembles deltas.
            outputContinuation.yield(trimmed)
        }

        for await chunk in sampleStream {
            if Task.isCancelled { break }

            liveBuffer.append(contentsOf: chunk)

            // StreamingVADProcessor buffers internally — feed chunks of any size.
            // The processor returns 0 or more events triggered by completed
            // 512-sample VAD windows.
            let events = processor.process(samples: chunk)
            for event in events {
                switch event {
                case .speechStarted(let t):
                    speechStartSample = Int(t * 16000)
                case .speechEnded(let seg):
                    if let start = speechStartSample {
                        let endSample = min(Int(seg.endTime * 16000), liveBuffer.count)
                        transcribeSegment(startSample: start, endSample: endSample)
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
                    transcribeSegment(startSample: start, endSample: endSample)
                    speechStartSample = Int(now * 16000)
                }
            }

        }

        // Sample stream finished (caller called `finish()`). Flush VAD to emit
        // any tail event for an in-progress speech span.
        let flushEvents = processor.flush()
        for event in flushEvents {
            if case .speechEnded(let seg) = event, let start = speechStartSample {
                let endSample = min(Int(seg.endTime * 16000), liveBuffer.count)
                transcribeSegment(startSample: start, endSample: endSample)
                speechStartSample = nil
            }
        }

        // Edge case: VAD never confirmed any speech (very short / soft / noisy).
        // Mirror the batch path's fallback so the user still gets some output.
        if emittedSegmentCount == 0 && liveBuffer.count >= 400 {
            transcribeSegment(startSample: 0, endSample: liveBuffer.count)
        }

        Log.asr.info("LiveTranscriber finished: \(liveBuffer.count) samples / \(emittedSegmentCount) segments emitted")
    }
}
