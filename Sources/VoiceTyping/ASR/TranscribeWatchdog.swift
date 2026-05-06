import Foundation
import os

/// v0.7.1 dogfood follow-up: passive watchdog around synchronous
/// `Qwen3ASRModel.transcribe` calls so a hung MLX dispatch leaves a trace.
///
/// Trigger: in 21 sessions of v0.7.1 dogfood we found one orphan capture
/// (`be8ac70b`) where the first segment transcribed in 145 ms but the second
/// never completed and the session was never finalized. `LiveTranscriber`
/// per-segment-locks `transcribeLock`, so it isn't a long-held-lock issue —
/// `model.transcribe` itself stopped returning. Without a watchdog the only
/// trace was an orphan session dir; with one, we get a `.error`-level log
/// (Console.app captures it even when the app is hung) plus call-site /
/// audio-length context that lets us correlate with `segments.jsonl`.
///
/// Cannot interrupt: `Qwen3ASRModel.transcribe` is synchronous with no
/// cancel hook (see `QwenASRRecognizer.cancel` for the same caveat). All we
/// can do is observe + log; the calling thread continues to wait for MLX.
enum TranscribeWatchdog {

    /// Production threshold. v0.6.1 baseline p99 was ~700 ms and v0.6.4 cold
    /// outliers topped out at ~30 s. 5 s is comfortably above warm p99 +
    /// cold-decompress so we don't spam logs in healthy paths, while still
    /// catching the orphan-session class within seconds of the hang starting.
    static let defaultThresholdSec: TimeInterval = 5.0

    struct Event: Sendable {
        let callsite: String
        let samples: Int
        let language: String
        let contextChars: Int
        let thresholdSec: TimeInterval
    }

    /// Default sink: emit at `.error` so the line shows in Console.app even
    /// without Developer logging on. Privacy `.public` because every field
    /// is operational metadata, not user content. Then fire `sample(1)`
    /// against our own PID so the hung thread's stack lands on disk —
    /// without this, all we know is "MLX call hung" but not WHERE inside
    /// MLX. With it, we can disambiguate H1 (compressor / mmap fault),
    /// H2 (Metal command queue wait), H3 (GPU power state), H4 (something
    /// else) on the next reproduction.
    static func defaultOnTimeout(_ e: Event) {
        Log.asr.error(
            "transcribe watchdog: still running after \(Int(e.thresholdSec), privacy: .public)s callsite=\(e.callsite, privacy: .public) samples=\(e.samples, privacy: .public) lang=\(e.language, privacy: .public) ctxChars=\(e.contextChars, privacy: .public)"
        )
        captureStack(callsite: e.callsite)
    }

    /// Spawn `/usr/bin/sample` against our own PID for 3 seconds and write
    /// its output to `~/Library/Application Support/VoiceTyping/hang-stacks/`.
    /// Fire-and-forget — we don't wait on the subprocess; if `sample` fails
    /// to attach (hardened-runtime restrictions on a notarised build, say),
    /// we just log and move on. The hung thread continues to wait inside
    /// MLX exactly as before; we're a passive observer.
    private static func captureStack(callsite: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let dir = appSupport.appendingPathComponent("VoiceTyping/hang-stacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeCallsite = callsite.replacingOccurrences(of: "/", with: "_")
        let outFile = dir.appendingPathComponent("\(stamp)_\(safeCallsite).txt").path

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        task.arguments = ["\(pid)", "3", "-file", outFile]
        do {
            try task.run()
            Log.asr.error("transcribe watchdog: sample(1) launched → \(outFile, privacy: .public)")
        } catch {
            Log.asr.error("transcribe watchdog: sample(1) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Run `body` synchronously on the current thread; if it hasn't returned
    /// by `threshold`, fire `onTimeout` exactly once on a utility queue.
    /// `onTimeout` may not run if `body` finishes first — `DispatchWorkItem`
    /// is cancelled in the cleanup path. The race window where both fire is
    /// effectively zero and a duplicate log is harmless if it ever happens.
    static func run<T>(
        callsite: String,
        samples: Int,
        language: String,
        contextChars: Int,
        threshold: TimeInterval = TranscribeWatchdog.defaultThresholdSec,
        onTimeout: @escaping @Sendable (Event) -> Void = TranscribeWatchdog.defaultOnTimeout,
        body: () -> T
    ) -> T {
        let event = Event(
            callsite: callsite,
            samples: samples,
            language: language,
            contextChars: contextChars,
            thresholdSec: threshold
        )
        let item = DispatchWorkItem { onTimeout(event) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + threshold, execute: item)
        defer { item.cancel() }
        return body()
    }
}
