import XCTest
import Foundation
@testable import VoiceTyping

/// Benchmark-only sweep: compares VAD tuning presets against the batch path
/// on every fixture. Used during the v0.5 planning phase to decide whether
/// shipping tuned VAD + segment padding as v0.4.5 is worth the complexity.
///
/// Gated behind `VT_BENCHMARK=1` so `make test-e2e` stays fast; run via:
///   `make benchmark-vad`
///
/// The comparison metric is character-level similarity to the **batch** Qwen
/// transcript for the same fixture — i.e. "how much does segmentation degrade
/// vs. single-shot transcription". Not a WER against ground truth, because
/// batch is already the model's best effort; what we care about is segment
/// strategy, not model quality.
@MainActor
final class E2EVADTuningBenchmarkTests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = true
        MLXSupport.overrideAvailable = ProcessInfo.processInfo.environment["VT_MLX_TEST_READY"] == "1"
    }

    override func tearDown() async throws {
        MLXSupport.overrideAvailable = nil
    }

    func testE2E_VADTuning_Sweep() async throws {
        guard ProcessInfo.processInfo.environment["VT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VT_BENCHMARK=1 to run the tuning benchmark (≈4× normal e2e time).")
        }
        guard MLXSupport.isAvailable else {
            throw XCTSkip("MLX unavailable — run `make benchmark-vad` which stages mlx.metallib.")
        }
        let backend: ASRBackend = .qwenASR17B
        guard ModelStore.isDownloaded(backend) else {
            throw XCTSkip("\(backend.displayName) not downloaded — launch the app once first.")
        }

        let names = try FixtureLoader.allNames()
        guard !names.isEmpty else {
            throw XCTSkip("No fixtures under Tests/Fixtures/.")
        }

        // Skip fixtures above this duration — a 97s fixture × 4 transcribe runs
        // (batch + 3 presets with ~17 force-split segments each) blows MLX memory
        // on the 3rd preset even with cacheClear between runs. The shorter
        // fixtures (≤60s) give enough signal; long ones can be benchmarked
        // separately by overriding `VT_BENCHMARK_MAX_DUR` in seconds.
        let maxDur: Double = {
            if let raw = ProcessInfo.processInfo.environment["VT_BENCHMARK_MAX_DUR"],
               let d = Double(raw) { return d }
            return 60.0
        }()
        print("VAD benchmark: \(names.count) candidate fixtures; will skip any > \(maxDur)s")

        // Each config mirrors a candidate Phase 1 shipping default. Names are
        // padded to the same width so per-fixture rows align in the recap.
        struct Preset {
            let label: String           // fixed width, for print alignment
            let tuning: QwenASRRecognizer.StreamingTuning
        }
        // The full sweep history lives in docs/devlog/v0.4.5.md and v0.5.0.md.
        // After v0.4.5 picked (0.3, 0.7) + HallucinationFilter, v0.5.0 bumped the
        // force-split threshold 10 → 25 s. This benchmark is now a regression
        // check on three configs:
        //   - baseline:       Silero defaults (no tuning, no filter)
        //   - production10s:  v0.4.5 shipping config (force-split 10 s)
        //   - production:     v0.5.0 shipping config (force-split 25 s)
        // Expected: production ≥ production10s on similarity for fixtures with
        // continuous 10-25 s speech spans, equal otherwise.
        let presets: [Preset] = [
            Preset(
                label: "baseline   ",
                tuning: .default  // Silero default: minSpeech 0.25, minSilence 0.10, no filter
            ),
            Preset(
                label: "prod10s    ",
                tuning: QwenASRRecognizer.StreamingTuning(  // v0.4.5 shipping config — kept for regression
                    minSpeechDuration: 0.3,
                    minSilenceDuration: 0.7,
                    paddingSeconds: 0,
                    maxSegmentDuration: 10.0
                )
            ),
            Preset(
                label: "production ",
                tuning: .production  // v0.5.0 shipping default (25 s force-split)
            )
        ]

        let rec = QwenASRRecognizer(backend: backend, cacheDir: ModelStore.directory(for: backend))
        try await rec.prepare()
        defer { rec.unload() }

        struct Result {
            let label: String
            let text: String
            let simToBatchPct: Int
            let ms: Int
            let partials: Int
        }
        struct RecapRow {
            let name: String
            let duration: String
            let language: String
            let batchText: String
            let batchMs: Int
            let results: [Result]
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
            if fixture.audio.duration > maxDur {
                print("  skipped \(name) (\(String(format: "%.1f", fixture.audio.duration))s > \(maxDur)s)")
                continue
            }

            // ---- BATCH (reference) ----
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

            // ---- Each preset ----
            var results: [Result] = []
            for preset in presets {
                let t0 = Date()
                var partials = 0
                var streamText = ""
                do {
                    let stream = rec.transcribeStreaming(
                        fixture.audio,
                        language: fixture.expected.languageEnum,
                        context: nil,
                        tuning: preset.tuning
                    )
                    for try await partial in stream {
                        partials += 1
                        streamText = partial
                    }
                } catch {
                    XCTFail("[\(name)] preset \(preset.label.trimmingCharacters(in: .whitespaces)) threw: \(error)")
                    continue
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let sim = Int((normalizedSimilarity(batchText, streamText) * 100).rounded())
                results.append(Result(
                    label: preset.label,
                    text: streamText,
                    simToBatchPct: sim,
                    ms: ms,
                    partials: partials
                ))
            }

            // Per-fixture block
            let dur = String(format: "%.1f", fixture.audio.duration)
            print("\n── \(name) (\(dur)s · \(fixture.expected.language)) ─────────────")
            print("  batch      [\(batchMs) ms]                       │ \(batchText)")
            for r in results {
                let header = "  \(r.label)[\(r.ms) ms, \(r.partials) partials, \(r.simToBatchPct)% vs batch]"
                let padded = header.padding(toLength: 53, withPad: " ", startingAt: 0)
                print("\(padded)│ \(r.text)")
            }

            recap.append(RecapRow(
                name: name,
                duration: "\(dur)s",
                language: fixture.expected.language,
                batchText: batchText,
                batchMs: batchMs,
                results: results
            ))
        }

        // ---- End recap ----
        guard !recap.isEmpty else { return }

        print("\n" + String(repeating: "=", count: 88))
        print("VAD tuning benchmark recap — \(recap.count) fixtures, Qwen 1.7B (similarity = char-level vs batch)")
        print(String(repeating: "=", count: 88))

        let nameWidth = max(recap.map(\.name.count).max() ?? 24, 8)
        let headerName = "fixture".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        var header = "  \(headerName)  dur     lang "
        for p in presets {
            header += " │ \(p.label.trimmingCharacters(in: .whitespaces).padding(toLength: 10, withPad: " ", startingAt: 0)) sim% / ms / partials"
        }
        print(header)
        print("  " + String(repeating: "-", count: header.count - 2))

        for row in recap {
            let name = row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let dur = row.duration.padding(toLength: 6, withPad: " ", startingAt: 0)
            let lang = row.language.padding(toLength: 4, withPad: " ", startingAt: 0)
            var line = "  \(name)  \(dur)  \(lang) "
            for r in row.results {
                let lbl = r.label.trimmingCharacters(in: .whitespaces)
                    .padding(toLength: 10, withPad: " ", startingAt: 0)
                let simStr = String(r.simToBatchPct).leftPadded(to: 4)
                let msStr = String(r.ms).leftPadded(to: 5)
                let partStr = String(r.partials).leftPadded(to: 2)
                line += " │ \(lbl)  \(simStr)% / \(msStr)ms / \(partStr)"
            }
            print(line)
        }

        // Aggregates: simple arithmetic mean across fixtures
        print("  " + String(repeating: "-", count: header.count - 2))
        var avgLine = "  " + "average".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "               "
        for (idx, preset) in presets.enumerated() {
            let sims = recap.map { Double($0.results[idx].simToBatchPct) }
            let mss = recap.map { Double($0.results[idx].ms) }
            let parts = recap.map { Double($0.results[idx].partials) }
            let avgSim = sims.reduce(0, +) / Double(sims.count)
            let avgMs = mss.reduce(0, +) / Double(mss.count)
            let avgPart = parts.reduce(0, +) / Double(parts.count)
            let lbl = preset.label.trimmingCharacters(in: .whitespaces)
                .padding(toLength: 10, withPad: " ", startingAt: 0)
            let simStr = String(Int(avgSim.rounded())).leftPadded(to: 4)
            let msStr = String(Int(avgMs.rounded())).leftPadded(to: 5)
            let partStr = String(format: "%2.1f", avgPart)
            avgLine += " │ \(lbl)  \(simStr)% / \(msStr)ms / \(partStr)"
        }
        print(avgLine)

        // Also print a diff view: for each fixture, show the delta vs baseline
        // for the tuned + tuned+pad presets. Useful when baseline is already
        // near-100% — absolute numbers all cluster, but the deltas reveal which
        // fixtures are actually improved / regressed.
        if presets.count >= 2 {
            print("\n" + String(repeating: "-", count: 88))
            print("delta vs baseline (Δ sim%, Δ partials) — positive Δ sim = closer to batch")
            print(String(repeating: "-", count: 88))
            for row in recap {
                let baseSim = row.results[0].simToBatchPct
                let basePart = row.results[0].partials
                var line = "  \(row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))"
                for idx in 1..<presets.count {
                    let r = row.results[idx]
                    let dSim = r.simToBatchPct - baseSim
                    let dPart = r.partials - basePart
                    let label = presets[idx].label.trimmingCharacters(in: .whitespaces)
                    let dSimStr = (dSim >= 0 ? "+" : "") + String(dSim)
                    let dPartStr = (dPart >= 0 ? "+" : "") + String(dPart)
                    line += "  \(label): Δsim=\(dSimStr.leftPadded(to: 3))  Δpartials=\(dPartStr.leftPadded(to: 2))"
                }
                print(line)
            }
        }
    }
}

private extension String {
    /// Right-align this string in a column `width` wide.
    func leftPadded(to width: Int) -> String {
        let pad = width - self.count
        return pad > 0 ? String(repeating: " ", count: pad) + self : self
    }
}
