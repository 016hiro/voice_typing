import XCTest
import Foundation
@testable import VoiceTyping

/// End-to-end check for v0.5.0 live-mic streaming. Simulates a mic feed by
/// pumping fixtures into `LiveTranscriber` in 341-sample chunks (the size
/// AudioCapture emits after resampling 1024-frame native taps from 48 kHz
/// down to 16 kHz). Compares the accumulated transcript to the batch path
/// to verify the live pipeline produces equivalent text.
///
/// Why the chunk size matters: VAD's hysteresis state machine processes
/// 512-sample windows, so feeding much larger chunks would batch multiple
/// state transitions per call and potentially mask ordering bugs. 341 is
/// what the production audio path actually delivers.
///
/// Pump rate: as fast as possible (no realtime sleep). LiveTranscriber's
/// pump operates on sample order, not wall-clock — pumping fast just makes
/// the test finish faster. Real-mic timing only matters for the user's
/// perceived latency, which this test doesn't measure.
@MainActor
final class E2ELiveTranscriberTests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = true
        MLXSupport.overrideAvailable = ProcessInfo.processInfo.environment["VT_MLX_TEST_READY"] == "1"
    }

    override func tearDown() async throws {
        MLXSupport.overrideAvailable = nil
    }

    func testE2E_LiveTranscriber_MatchesBatch_OnRepresentativeFixtures() async throws {
        guard MLXSupport.isAvailable else {
            throw XCTSkip("MLX unavailable — run via `make test-e2e`.")
        }
        let backend: ASRBackend = .qwenASR17B
        guard ModelStore.isDownloaded(backend) else {
            throw XCTSkip("\(backend.displayName) not downloaded — launch the app once first.")
        }

        // A small representative slice rather than every fixture: short en,
        // medium zh, longer en, longer zh. The full sweep across all fixtures
        // happens via `make benchmark-vad` which already validates the same
        // VAD-segmentation logic; this test specifically covers the async
        // sample-feed pump that LiveTranscriber adds on top.
        let candidates = [
            "librispeech_1273_128104_short",  // ~6 s en (likely missing → falls through)
            "librispeech_1272_128104_short",  // ~6 s en
            "fleurs_zh_med_7s_m_1548",        // ~7 s zh
            "librispeech_1988_147956_short",  // ~9 s en
            "fleurs_zh_xlong_18s_m_1542"     // ~18 s zh — exercises 25 s force-split boundary
        ]
        let names = (try FixtureLoader.allNames()).filter { candidates.contains($0) }
        guard !names.isEmpty else {
            throw XCTSkip("No representative fixtures found under Tests/Fixtures/.")
        }

        let rec = QwenASRRecognizer(backend: backend, cacheDir: ModelStore.directory(for: backend))
        try await rec.prepare()
        defer { rec.unload() }

        // Same VAD that AppDelegate's pre-warm hits — load via the actor so
        // the test exercises the production code path end-to-end.
        let vadBox = try await QwenASRRecognizer.vadActor.get()

        struct Result {
            let name: String
            let lang: String
            let durationSec: Double
            let batchText: String
            let liveText: String
            let similarity: Double
            let chunks: Int
        }
        var results: [Result] = []

        for name in names {
            let fixture: FixtureLoader.LoadedFixture
            do {
                fixture = try FixtureLoader.load(name)
            } catch {
                XCTFail("[\(name)] load failed: \(error)")
                continue
            }

            // ---- Batch reference ----
            let batchText: String
            do {
                batchText = try await rec.transcribe(
                    fixture.audio,
                    language: fixture.expected.languageEnum,
                    context: nil
                )
            } catch {
                XCTFail("[\(name)] batch threw: \(error)")
                continue
            }

            // ---- Live simulation ----
            let lt = LiveTranscriber(
                recognizer: rec,
                vadBox: vadBox,
                tuning: .production,
                language: fixture.expected.languageEnum,
                context: nil
            )
            lt.start()

            // Pump the fixture in 341-sample chunks (production AudioCapture
            // chunk size at 48 kHz native → 16 kHz output). For non-multiple
            // tail samples, send the remainder in one final chunk.
            let chunkSize = 341
            let samples = fixture.audio.samples
            var chunks = 0
            var i = 0
            while i < samples.count {
                let end = min(i + chunkSize, samples.count)
                lt.ingest(samples: Array(samples[i..<end]))
                chunks += 1
                i = end
            }
            lt.finish()

            // Drain output — each yield is one segment's text. Accumulate to
            // the same shape AppDelegate's live inject task uses (first segment
            // verbatim, subsequent joined with " "). v0.5.0 changed `.output`
            // from cumulative to per-segment so AppDelegate can inject deltas
            // into the focused app live, mid-recording.
            var liveText = ""
            var segmentTexts: [String] = []
            do {
                for try await segment in lt.output {
                    segmentTexts.append(segment)
                    liveText = liveText.isEmpty ? segment : liveText + " " + segment
                }
            } catch {
                XCTFail("[\(name)] live drain threw: \(error)")
                continue
            }

            let sim = normalizedSimilarity(batchText, liveText)
            results.append(Result(
                name: name,
                lang: fixture.expected.language,
                durationSec: fixture.audio.duration,
                batchText: batchText,
                liveText: liveText,
                similarity: sim,
                chunks: chunks
            ))

            print("\n── \(name) (\(String(format: "%.1f", fixture.audio.duration))s · \(fixture.expected.language)) ─────────────")
            print("  batch (\(batchText.count) chars) │ \(batchText)")
            print("  live  (\(liveText.count) chars, \(chunks) chunks fed, \(segmentTexts.count) segments) │ \(liveText)")
            print("  similarity: \(Int((sim * 100).rounded()))%")
        }

        // Assertion: every fixture must be at least 80 % similar to batch, and
        // the average across the sample must be at least 90 %. The batch
        // benchmark recap shows ≥99 % when both paths use the same audio +
        // tuning, so 80 % per-fixture leaves headroom for a chunked-feed
        // ordering bug to actually fail rather than blip past on noise.
        XCTAssertFalse(results.isEmpty, "no fixtures ran")
        for r in results {
            XCTAssertGreaterThanOrEqual(r.similarity, 0.80,
                "[\(r.name)] live transcript similarity \(Int((r.similarity * 100).rounded()))% < 80% threshold\n  batch: \(r.batchText)\n  live:  \(r.liveText)")
        }
        let avgSim = results.map(\.similarity).reduce(0, +) / Double(results.count)
        XCTAssertGreaterThanOrEqual(avgSim, 0.90,
            "average live-vs-batch similarity \(Int((avgSim * 100).rounded()))% < 90% threshold")
        print("\n── E2E LiveTranscriber recap: \(results.count) fixtures, avg sim \(Int((avgSim * 100).rounded()))% ──")
    }
}
