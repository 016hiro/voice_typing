import XCTest
import Foundation
@testable import VoiceTyping

/// End-to-end regression: for every fixture, run BOTH batch and streaming
/// through the Qwen backend and print the transcripts side-by-side with a
/// character-level similarity score. This surfaces the actual divergence
/// between the two paths on every run — the point of having both paths is
/// that they behave within an acceptable band, and that band is easier to
/// eyeball than to hard-code.
///
/// Assertions are deliberately loose:
///   - Both transcripts must be non-empty and within `[minChars, maxChars]`.
///   - Streaming must emit at least `streamingMinPartials` yields.
///   - Keywords are checked ONLY if `expected.json` has a non-empty array
///     (they're an optional "must-see term" bar; for new fixtures you can
///     skip them and judge by the printed diff).
///
/// There is intentionally NO hard similarity threshold — streaming vs batch
/// will always differ a bit (VAD segmentation, punctuation, short-burst
/// hallucination). The sim% is informational; judgement stays with the
/// developer reading the output.
///
/// Requirements:
///   - `mlx.metallib` colocated with the test binary (Makefile `test-e2e`
///     target stages it)
///   - Qwen 1.7B downloaded to `~/Library/Application Support/VoiceTyping/models/`
///     (launch the app once to trigger)
///   - At least one fixture WAV + expected.json in `Tests/Fixtures/`
@MainActor
final class E2EASRComparisonTests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = true
        MLXSupport.overrideAvailable = ProcessInfo.processInfo.environment["VT_MLX_TEST_READY"] == "1"
    }

    override func tearDown() async throws {
        MLXSupport.overrideAvailable = nil
    }

    func testE2E_Qwen_BatchVsStreaming_AllFixtures() async throws {
        guard MLXSupport.isAvailable else {
            throw XCTSkip("MLX unavailable — run `make test-e2e` to stage `mlx.metallib`.")
        }
        let backend: ASRBackend = .qwenASR17B
        guard ModelStore.isDownloaded(backend) else {
            throw XCTSkip("\(backend.displayName) not downloaded — launch the app once first.")
        }

        let names = try FixtureLoader.allNames()
        guard !names.isEmpty else {
            throw XCTSkip("No fixtures under Tests/Fixtures/.")
        }

        let rec = QwenASRRecognizer(backend: backend, cacheDir: ModelStore.directory(for: backend))
        try await rec.prepare()
        defer { rec.unload() }

        // Collect one-line entries for the end-of-run recap. Inline blocks
        // above show full transcripts; the recap is just the at-a-glance table.
        struct RecapRow {
            let name: String
            let duration: String
            let language: String
            let similarity: Int
            let batchKwMissing: [String]
            let streamKwMissing: [String]
            let hasKeywords: Bool
        }
        var recap: [RecapRow] = []

        for name in names {
            let fixture: FixtureLoader.LoadedFixture
            do {
                fixture = try FixtureLoader.load(name)
            } catch {
                XCTFail("[\(name)] failed to load: \(error)")
                continue
            }

            // ---- BATCH ----
            let batchT0 = Date()
            var batchText = ""
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
            let batchMs = Int(Date().timeIntervalSince(batchT0) * 1000)

            // ---- STREAMING ----
            let streamT0 = Date()
            var partials: [String] = []
            var streamText = ""
            do {
                let stream = rec.transcribeStreaming(
                    fixture.audio,
                    language: fixture.expected.languageEnum,
                    context: nil
                )
                for try await partial in stream {
                    partials.append(partial)
                    streamText = partial
                }
            } catch {
                XCTFail("[\(name)] streaming threw: \(error)")
                continue
            }
            let streamMs = Int(Date().timeIntervalSince(streamT0) * 1000)

            // ---- REPORT ----
            let sim = normalizedSimilarity(batchText, streamText)
            let simPct = Int((sim * 100).rounded())
            let block = buildReportBlock(
                name: name,
                fixture: fixture,
                batch: batchText, batchMs: batchMs,
                stream: streamText, streamMs: streamMs,
                partials: partials.count,
                similarity: simPct
            )
            print(block)
            recap.append(RecapRow(
                name: name,
                duration: String(format: "%.1fs", fixture.audio.duration),
                language: fixture.expected.language,
                similarity: simPct,
                batchKwMissing: fixture.expected.keywords.filter {
                    !batchText.lowercased().contains($0.lowercased())
                },
                streamKwMissing: fixture.expected.keywords.filter {
                    !streamText.lowercased().contains($0.lowercased())
                },
                hasKeywords: !fixture.expected.keywords.isEmpty
            ))

            // ---- ASSERTIONS ----
            XCTAssertFalse(batchText.isEmpty, "[\(name)] batch transcript is empty")
            XCTAssertFalse(streamText.isEmpty, "[\(name)] streaming transcript is empty")

            XCTAssertGreaterThanOrEqual(
                batchText.count, fixture.expected.minChars,
                "[\(name)] batch shorter than minChars"
            )
            XCTAssertLessThanOrEqual(
                batchText.count, fixture.expected.maxChars,
                "[\(name)] batch longer than maxChars"
            )
            XCTAssertGreaterThanOrEqual(
                streamText.count, fixture.expected.minChars,
                "[\(name)] streaming shorter than minChars"
            )
            XCTAssertLessThanOrEqual(
                streamText.count, fixture.expected.maxChars,
                "[\(name)] streaming longer than maxChars"
            )
            XCTAssertGreaterThanOrEqual(
                partials.count, fixture.expected.streamingMinPartials,
                "[\(name)] streaming yielded \(partials.count) partials, expected ≥ \(fixture.expected.streamingMinPartials)"
            )

            // Keywords are optional (empty array = skip). Checking both paths
            // catches "one path is fine, the other silently degraded".
            if !fixture.expected.keywords.isEmpty {
                XCTAssertContainsKeywords(batchText, fixture.expected.keywords,
                                          file: #filePath, line: #line)
                XCTAssertContainsKeywords(streamText, fixture.expected.keywords,
                                          file: #filePath, line: #line)
            }
        }

        // Final recap — one line per fixture. Prints even if earlier assertions
        // failed (continueAfterFailure = true), so the table is always visible.
        if !recap.isEmpty {
            print("\n" + String(repeating: "=", count: 72))
            print("Batch vs streaming recap (\(recap.count) fixtures)")
            print(String(repeating: "=", count: 72))
            let nameColumn = recap.map(\.name.count).max() ?? 24
            for row in recap {
                let pad = String(repeating: " ", count: max(0, nameColumn - row.name.count))
                let kwMark: String
                if !row.hasKeywords {
                    kwMark = "-"
                } else if row.batchKwMissing.isEmpty && row.streamKwMissing.isEmpty {
                    kwMark = "✓"
                } else {
                    kwMark = "✗ batch=\(row.batchKwMissing) stream=\(row.streamKwMissing)"
                }
                print(String(format: "  [%3d%%]  %@%@  %@  %@  %@",
                             row.similarity,
                             row.name as NSString,
                             pad as NSString,
                             row.duration.padding(toLength: 7, withPad: " ", startingAt: 0) as NSString,
                             row.language.padding(toLength: 6, withPad: " ", startingAt: 0) as NSString,
                             kwMark as NSString))
            }
        }
    }

    // MARK: - Formatting

    private func buildReportBlock(
        name: String,
        fixture: FixtureLoader.LoadedFixture,
        batch: String, batchMs: Int,
        stream: String, streamMs: Int,
        partials: Int,
        similarity: Int
    ) -> String {
        var lines: [String] = []
        let dur = String(format: "%.1f", fixture.audio.duration)
        lines.append("\n── \(name) (\(dur)s · \(fixture.expected.language)) ─────────────")
        lines.append("  batch     [\(batchMs) ms]            │ \(batch)")
        lines.append("  streaming [\(streamMs) ms, \(partials) partials] │ \(stream)")
        lines.append("  similarity                       │ \(similarity)%")
        if !fixture.expected.keywords.isEmpty {
            let bMiss = fixture.expected.keywords.filter { !batch.lowercased().contains($0.lowercased()) }
            let sMiss = fixture.expected.keywords.filter { !stream.lowercased().contains($0.lowercased()) }
            let bMark = bMiss.isEmpty ? "✓" : "✗ \(bMiss)"
            let sMark = sMiss.isEmpty ? "✓" : "✗ \(sMiss)"
            lines.append("  keywords                         │ batch \(bMark)  streaming \(sMark)")
        }
        return lines.joined(separator: "\n")
    }
}
