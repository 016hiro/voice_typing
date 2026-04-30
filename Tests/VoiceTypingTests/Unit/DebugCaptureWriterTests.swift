import XCTest
@testable import VoiceTyping

/// v0.5.3 fixes for the writer:
///   - Bug 1: `begin()` writes a partial meta.json immediately so crashed /
///     force-quit sessions still leave metadata on disk (v0.5.2 dogfood: only
///     12% of sessions had usable meta).
///   - Bug 2: ISO8601 timestamps include fractional seconds so `live_drain.py`
///     can compute sub-second drain deltas.
final class DebugCaptureWriterTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingTests-DebugCaptureWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempRoot, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Bug 1: partial meta written at begin()

    func testInit_WritesPartialMetaImmediately() throws {
        let writer = makeWriter(sessionId: "abcd1234")

        // Writer enqueues partial-meta write to its serial queue. Drain to
        // ensure the write completes before we read.
        drain(writer)

        let metaURL = writer.folder.appendingPathComponent("meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path),
                      "begin() must write meta.json immediately, not wait for finalize/abort")

        let meta = try loadMeta(at: metaURL)
        XCTAssertEqual(meta["sessionId"] as? String, "abcd1234")
        XCTAssertNotNil(meta["startedAt"], "startedAt is known at begin() — must be present")
        XCTAssertNil(meta["endedAt"], "endedAt unknown until finalize/abort — must be absent")
        XCTAssertNil(meta["totalAudioSec"])
        XCTAssertNil(meta["totalSegments"])
        XCTAssertNil(meta["totalInjections"])
    }

    func testFinalize_UpdatesMetaWithEndedAtAndTotals() throws {
        let writer = makeWriter(sessionId: "fin01234")

        writer.appendSegment(.init(timestamp: Date(), startSec: 0, endSec: 1.0,
                                    rawText: "hello", filter: .kept, transcribeMs: 50))
        writer.appendInjection(.init(timestamp: Date(), chars: 5, textPreview: "hello",
                                      targetBundleID: "com.test", actualBundleID: "com.test",
                                      status: .ok, elapsedMs: 10))
        writer.finalize(audio: AudioBuffer(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000))
        drain(writer)

        let meta = try loadMeta(at: writer.folder.appendingPathComponent("meta.json"))
        XCTAssertNotNil(meta["endedAt"], "finalize must populate endedAt")
        XCTAssertEqual(meta["totalSegments"] as? Int, 1)
        XCTAssertEqual(meta["totalInjections"] as? Int, 1)
        if let dur = meta["totalAudioSec"] as? Double {
            XCTAssertEqual(dur, 1.0, accuracy: 0.001)
        } else {
            XCTFail("totalAudioSec must be present after finalize")
        }
    }

    func testAbort_UpdatesMetaWithoutAudio() throws {
        let writer = makeWriter(sessionId: "abrt0123")
        writer.abort()
        drain(writer)

        let meta = try loadMeta(at: writer.folder.appendingPathComponent("meta.json"))
        XCTAssertNotNil(meta["endedAt"], "abort must populate endedAt")
        XCTAssertNil(meta["totalAudioSec"], "abort writes no audio, must not set totalAudioSec")

        let audioURL = writer.folder.appendingPathComponent("audio.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path),
                       "abort writes no audio.wav")
    }

    // MARK: - Bug 2: ISO8601 with fractional seconds

    func testMetaTimestamps_IncludeFractionalSeconds() throws {
        let writer = makeWriter(sessionId: "frac0001")
        writer.finalize(audio: AudioBuffer(samples: [Float](repeating: 0, count: 1_600), sampleRate: 16_000))
        drain(writer)

        let raw = try String(contentsOf: writer.folder.appendingPathComponent("meta.json"), encoding: .utf8)
        // Default `.iso8601` emits `2026-04-23T19:13:19Z` (no fractional).
        // Our custom formatter emits `2026-04-23T19:13:19.123Z`.
        XCTAssertTrue(raw.contains("."),
                       "meta.json timestamps must include fractional seconds — without them live_drain.py reports 0 ms drain")
        // Sanity: timezone marker still there.
        XCTAssertTrue(raw.contains("Z") || raw.contains("+"),
                       "ISO8601 timestamps must retain timezone marker")
    }

    // MARK: - v0.6.3 dogfood Bug A: queue closures must outlive writer ref

    func testFinalize_AfterWriterRefDropped_StillWritesAudioAndMeta() throws {
        // Regression for the "all sessions only have meta.json + segments.jsonl"
        // bug seen during v0.6.3 R8 dogfood. Pre-fix code captured `[weak self]`
        // on every queue.async closure; in production the writer is only held by
        // a `let captureWriter = currentDebugWriter` local in pipelineTask, and
        // finalize is the LAST thing enqueued before that Task ends + drops the
        // local. Race: Task ends → captureWriter dies → writer dies → queue's
        // weak self is nil → finalize's `guard let self else { return }` silently
        // drops audio.wav + endedAt write. This test reproduces by enclosing the
        // writer in a do-block scope so the strong ref is gone when we check.
        let folder = tempRoot.appendingPathComponent("session-bugA", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = DebugCaptureWriter.Meta(
            sessionId: "bugA0001", appVersion: "test", startedAt: Date(), endedAt: nil,
            backend: "qwen", language: "zh", liveMode: false, frontmostBundleID: nil,
            profileSnippet: nil, asrContextChars: 0,
            totalAudioSec: nil, totalSegments: nil, totalInjections: nil, totalRefines: nil
        )
        let audio = AudioBuffer(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)

        do {
            let writer = DebugCaptureWriter(folder: folder, meta: meta)
            writer.finalize(audio: audio)
            // Scope ends → writer's only strong ref drops here. Pre-fix: the
            // queue closure's weak self was nil by the time it ran, so finalize
            // never wrote audio.wav. Post-fix: closure strong-captures self so
            // the writer stays alive until the queue drains.
        }

        // No writer reference → can't call waitUntilIdleForTesting. Poll the
        // filesystem until both audio.wav and a finalized meta appear, or 2 s
        // elapses (ample for a single utility-qos closure).
        let metaURL = folder.appendingPathComponent("meta.json")
        let audioURL = folder.appendingPathComponent("audio.wav")
        let deadline = Date().addingTimeInterval(2.0)
        var sawFinalized = false
        while Date() < deadline {
            if let data = try? Data(contentsOf: metaURL),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               dict["endedAt"] != nil,
               FileManager.default.fileExists(atPath: audioURL.path) {
                sawFinalized = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(sawFinalized,
                      "finalize must complete after writer ref is dropped (Bug A regression)")
    }

    // MARK: - v0.6.3 #R8: refine I/O capture

    func testAppendRefine_WritesJSONLAndUpdatesMetaTotal() throws {
        let writer = makeWriter(sessionId: "ref00001")

        let r1 = DebugCaptureWriter.RefineRecord(
            timestamp: Date(),
            input: "hello world",
            output: "Hello, world.",
            mode: "light",
            backend: "cloud",
            latencyMs: 312,
            glossary: "热词：World, Hello",
            profileSnippet: nil,
            rawFirst: false
        )
        let r2 = DebugCaptureWriter.RefineRecord(
            timestamp: Date(),
            input: "uh another sentence",
            output: "Another sentence.",
            mode: "aggressive",
            backend: "local",
            latencyMs: 745,
            glossary: nil,
            profileSnippet: "Prefer terse, technical phrasing.",
            rawFirst: true
        )
        writer.appendRefine(r1)
        writer.appendRefine(r2)
        writer.finalize(audio: AudioBuffer(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000))
        drain(writer)

        // 1. refines.jsonl exists with one line per record
        let jsonlURL = writer.folder.appendingPathComponent("refines.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonlURL.path),
                      "refines.jsonl must be written when appendRefine is called")
        let raw = try String(contentsOf: jsonlURL, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "two appendRefine calls must produce two JSONL lines")

        // 2. Schema fidelity — round-trip first line, verify all fields
        guard let firstData = lines[0].data(using: .utf8),
              let first = try JSONSerialization.jsonObject(with: firstData) as? [String: Any] else {
            XCTFail("first refine line must be parseable JSON object"); return
        }
        XCTAssertEqual(first["input"] as? String, "hello world")
        XCTAssertEqual(first["output"] as? String, "Hello, world.")
        XCTAssertEqual(first["mode"] as? String, "light")
        XCTAssertEqual(first["backend"] as? String, "cloud")
        XCTAssertEqual(first["latencyMs"] as? Int, 312)
        XCTAssertEqual(first["glossary"] as? String, "热词：World, Hello")
        XCTAssertEqual(first["rawFirst"] as? Bool, false)

        // 3. Meta.totalRefines reflects the count after finalize
        let meta = try loadMeta(at: writer.folder.appendingPathComponent("meta.json"))
        XCTAssertEqual(meta["totalRefines"] as? Int, 2,
                       "finalize must populate totalRefines from append count")
    }

    func testAppendRefine_AfterFinalize_DropsRecord() throws {
        // Mirrors the dropped-after-finalize behavior of appendSegment /
        // appendInjection: late writes from a still-running Task must not
        // corrupt finalized session state.
        let writer = makeWriter(sessionId: "ref00002")
        writer.finalize(audio: AudioBuffer(samples: [Float](repeating: 0, count: 1_600), sampleRate: 16_000))
        drain(writer)

        writer.appendRefine(.init(timestamp: Date(), input: "late", output: "late",
                                   mode: "light", backend: "cloud",
                                   latencyMs: 100, glossary: nil, profileSnippet: nil, rawFirst: false))
        drain(writer)

        let jsonlURL = writer.folder.appendingPathComponent("refines.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonlURL.path),
                       "appendRefine after finalize must be a no-op (no JSONL written)")

        // Meta.totalRefines should reflect the in-window count (zero), not be
        // bumped by the dropped late append.
        let meta = try loadMeta(at: writer.folder.appendingPathComponent("meta.json"))
        XCTAssertEqual(meta["totalRefines"] as? Int, 0)
    }

    func testJSONLTimestamps_IncludeFractionalSeconds() throws {
        let writer = makeWriter(sessionId: "frac0002")
        writer.appendSegment(.init(timestamp: Date(), startSec: 0, endSec: 0.5,
                                    rawText: "x", filter: .kept, transcribeMs: 10))
        writer.appendInjection(.init(timestamp: Date(), chars: 1, textPreview: "x",
                                      targetBundleID: nil, actualBundleID: nil,
                                      status: .ok, elapsedMs: 1))
        drain(writer)

        let segPath = writer.folder.appendingPathComponent("segments.jsonl")
        let raw = try String(contentsOf: segPath, encoding: .utf8)
        XCTAssertTrue(raw.contains("."),
                       "segments.jsonl timestamps must include fractional seconds")
    }

    // MARK: - Helpers

    private func makeWriter(sessionId: String) -> DebugCaptureWriter {
        let folder = tempRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = DebugCaptureWriter.Meta(
            sessionId: sessionId,
            appVersion: "test",
            startedAt: Date(),
            endedAt: nil,
            backend: "qwen",
            language: "zh",
            liveMode: false,
            frontmostBundleID: "com.test.app",
            profileSnippet: nil,
            asrContextChars: 0,
            totalAudioSec: nil,
            totalSegments: nil,
            totalInjections: nil,
            totalRefines: nil
        )
        return DebugCaptureWriter(folder: folder, meta: meta)
    }

    /// Block until the writer's serial queue has drained all enqueued work.
    /// This must not rely on marker appends: finalize/abort intentionally
    /// drops subsequent appends, which made the old file-polling helper flaky.
    private func drain(_ writer: DebugCaptureWriter) {
        writer.waitUntilIdleForTesting()
    }

    private func loadMeta(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "meta.json not an object"])
        }
        return dict
    }
}
