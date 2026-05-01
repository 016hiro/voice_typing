import Foundation
import os

/// Lightweight latency breakdown per utterance. Emits a single os_log line per
/// completed pipeline run with ms for each stage, so Console.app (or `log show`)
/// can be used to audit p50/p95 without shipping any metrics infrastructure.
///
/// Usage:
///     let t = LatencyTracker()
///     t.mark(.asrStart)
///     // ... run ASR ...
///     t.mark(.asrEnd)
///     t.mark(.llmStart)
///     // ... refine ...
///     t.mark(.llmEnd)
///     t.mark(.injectStart)
///     // ... paste ...
///     t.mark(.injectEnd)
///     t.log(backend: "qwen-1.7b", mode: "aggressive", dictEntries: 14, delivery: "streaming")
final class LatencyTracker: @unchecked Sendable {

    enum Stage: String {
        case asrStart, asrEnd
        case llmStart, llmEnd
        case injectStart, injectEnd
    }

    private var marks: [Stage: CFAbsoluteTime] = [:]
    private let lock = NSLock()
    private let createdAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    func mark(_ stage: Stage) {
        lock.lock(); defer { lock.unlock() }
        marks[stage] = CFAbsoluteTimeGetCurrent()
    }

    private func ms(_ from: Stage, _ to: Stage) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let a = marks[from], let b = marks[to] else { return -1 }
        return Int(((b - a) * 1000).rounded())
    }

    /// `delivery` is one of `RefineDelivery.rawValue` (streaming/rawFirst/
    /// batch) or `"live"` for live-mode runs that skip refine entirely.
    /// v0.7.0 #R6 generalized the pre-existing `rawFirst: Bool` field —
    /// dogfood log parsers should read `delivery=...` instead.
    ///
    /// `overrideLlmMs` (#R9 redo follow-up) — for the local-per-segment
    /// live path the refine happens inside `liveInjectTask` (detached,
    /// outside this tracker's scope), so `mark(.llmStart/.llmEnd)` is
    /// never called and `ms(.llmStart, .llmEnd)` would return -1. Caller
    /// passes the aggregated per-segment infer_ms here so the log line
    /// reflects reality.
    func log(backend: String, mode: String, dictEntries: Int, delivery: String, overrideLlmMs: Int? = nil) {
        let asr    = ms(.asrStart, .asrEnd)
        let llm    = overrideLlmMs ?? ms(.llmStart, .llmEnd)
        let inject = ms(.injectStart, .injectEnd)
        let total  = Int(((CFAbsoluteTimeGetCurrent() - createdAt) * 1000).rounded())

        // .notice so `log stream` sees it without `--level info`. This is a
        // summary metric, not debug spam — one line per completed utterance,
        // worth first-class visibility in Console.
        Log.app.notice(
            "latency backend=\(backend, privacy: .public) mode=\(mode, privacy: .public) dict=\(dictEntries, privacy: .public) delivery=\(delivery, privacy: .public) asr_ms=\(asr, privacy: .public) llm_ms=\(llm, privacy: .public) inject_ms=\(inject, privacy: .public) total_ms=\(total, privacy: .public)"
        )
    }
}
