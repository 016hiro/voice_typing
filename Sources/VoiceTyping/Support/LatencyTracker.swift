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
///     t.log(backend: "qwen-1.7b", mode: "aggressive", dictEntries: 14, rawFirst: false)
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

    func log(backend: String, mode: String, dictEntries: Int, rawFirst: Bool) {
        let asr    = ms(.asrStart, .asrEnd)
        let llm    = ms(.llmStart, .llmEnd)
        let inject = ms(.injectStart, .injectEnd)
        let total  = Int(((CFAbsoluteTimeGetCurrent() - createdAt) * 1000).rounded())

        Log.app.info(
            "latency backend=\(backend, privacy: .public) mode=\(mode, privacy: .public) dict=\(dictEntries, privacy: .public) rawFirst=\(rawFirst, privacy: .public) asr_ms=\(asr, privacy: .public) llm_ms=\(llm, privacy: .public) inject_ms=\(inject, privacy: .public) total_ms=\(total, privacy: .public)"
        )
    }
}
