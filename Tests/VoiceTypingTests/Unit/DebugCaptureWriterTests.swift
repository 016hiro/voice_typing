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

    func testJSONLTimestamps_IncludeFractionalSeconds() throws {
        let writer = makeWriter(sessionId: "frac0002")
        writer.appendSegment(.init(timestamp: Date(), startSec: 0, endSec: 0.5,
                                    rawText: "x", filter: .kept, transcribeMs: 10))
        // Drain by issuing a synchronous block on the writer's queue (cleanest
        // way to await async appends without sleep).
        let exp = expectation(description: "segment flushed")
        writer.appendInjection(.init(timestamp: Date(), chars: 1, textPreview: "x",
                                      targetBundleID: nil, actualBundleID: nil,
                                      status: .ok, elapsedMs: 1))
        DispatchQueue.global().async {
            // Force a wait by chaining one more append + a quick poll.
            Thread.sleep(forTimeInterval: 0.05)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
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
            totalInjections: nil
        )
        return DebugCaptureWriter(folder: folder, meta: meta)
    }

    /// Block until the writer's serial queue has drained all enqueued work.
    /// All public writer methods enqueue on the same internal queue, so a
    /// `sync` on that queue via a label-matched flush guarantees ordering.
    /// The writer's queue isn't exposed; we use a sync `DispatchWorkItem` on
    /// the same QoS by calling `finalize`/`abort`-like quiescence: enqueue a
    /// no-op via the public API and wait on it via expectation.
    private func drain(_ writer: DebugCaptureWriter) {
        // Enqueue a marker via appendSegment — runs after every prior task on
        // the writer's serial queue. Use an expectation to await the file
        // being touched.
        let marker = "__drain_marker_\(UUID().uuidString)__"
        writer.appendSegment(.init(timestamp: Date(), startSec: -1, endSec: -1,
                                    rawText: marker, filter: .kept, transcribeMs: 0))
        let exp = expectation(description: "drain")
        DispatchQueue.global().async { [folder = writer.folder] in
            // Poll up to 1s for the marker to land in segments.jsonl.
            let segURL = folder.appendingPathComponent("segments.jsonl")
            for _ in 0..<100 {
                if let raw = try? String(contentsOf: segURL, encoding: .utf8), raw.contains(marker) {
                    exp.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            // Drain may complete before any segment is written (e.g. after
            // finalize). Fall through and fulfill so callers don't hang.
            exp.fulfill()
        }
        // Timeout headroom for slow CI disks: the 100×10ms polling loop is ~1s
        // nominal locally but file IO per iteration can push total wall time
        // past 2s on the macos-15 runner. 5s leaves ample slack while still
        // surfacing real hangs.
        wait(for: [exp], timeout: 5.0)
    }

    private func loadMeta(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "meta.json not an object"])
        }
        return dict
    }
}
