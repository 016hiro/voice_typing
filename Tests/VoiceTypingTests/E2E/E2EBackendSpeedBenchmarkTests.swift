import XCTest
import Foundation
@testable import VoiceTyping

/// Per-backend × per-fixture batch transcription speed benchmark. Measures
/// wall-clock ms + RTF (real-time factor = transcribe_ms / audio_ms; <1 means
/// faster than realtime). Used to:
///   1. Inform the default-backend choice (Qwen 0.6B 4bit vs 1.7B 8bit) with
///      evidence rather than vibes.
///   2. Establish a baseline for the local MLX refiner sizing discussion.
///   3. Catch regressions when upstream `speech-swift` or `WhisperKit` updates.
///
/// Gated behind `VT_BENCHMARK=1` so `make test-e2e` stays fast; run via
/// `make benchmark-speed`. Each backend's first fixture is treated as warmup
/// (timing discarded) so the table reflects steady-state performance, not
/// cold-start cost. Backends not downloaded are skipped silently — a user with
/// only Qwen installed still gets a useful Qwen-only recap.
@MainActor
final class E2EBackendSpeedBenchmarkTests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = true
        MLXSupport.overrideAvailable = ProcessInfo.processInfo.environment["VT_MLX_TEST_READY"] == "1"
    }

    override func tearDown() async throws {
        MLXSupport.overrideAvailable = nil
    }

    func testE2E_BackendSpeed_AllBackends_AcrossFixtures() async throws {
        guard ProcessInfo.processInfo.environment["VT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VT_BENCHMARK=1 to run the speed benchmark (≈3 backends × all fixtures).")
        }
        guard MLXSupport.isAvailable else {
            throw XCTSkip("MLX unavailable — run `make benchmark-speed` which stages mlx.metallib.")
        }
        let names = try FixtureLoader.allNames()
        guard !names.isEmpty else {
            throw XCTSkip("No fixtures under Tests/Fixtures/.")
        }

        // Load all fixtures upfront so a malformed file fails fast before we
        // burn time loading models. Filtering here also lets the same fixture
        // index align across backends in the recap table.
        struct LoadedRow {
            let name: String
            let durationSec: Double
            let language: String
            let fixture: FixtureLoader.LoadedFixture
            var msByBackend: [ASRBackend: Int] = [:]
            var charsByBackend: [ASRBackend: Int] = [:]
        }
        var rows: [LoadedRow] = []
        for name in names {
            do {
                let f = try FixtureLoader.load(name)
                rows.append(LoadedRow(
                    name: name,
                    durationSec: f.audio.duration,
                    language: f.expected.language,
                    fixture: f
                ))
            } catch {
                print("  skipped fixture \(name): \(error)")
            }
        }
        guard !rows.isEmpty else { throw XCTSkip("No loadable fixtures.") }

        // Order matters. WhisperKit doesn't expose `unload()` upstream, so
        // running it last avoids carrying its weights through subsequent Qwen
        // loads (would risk OOM on 16 GB Macs). Qwen 0.6B before 1.7B for the
        // same reason — tear down small before bringing up large.
        let backendOrder: [ASRBackend] = [.qwenASR06B, .qwenASR17B, .whisperLargeV3]

        for backend in backendOrder {
            guard ModelStore.isDownloaded(backend) else {
                print("\n\n── \(backend.displayName) ─ SKIPPED (model not downloaded) ──")
                continue
            }

            print("\n\n══ \(backend.displayName) ════════════════════════════════════════")

            let rec = RecognizerFactory.make(backend)
            let prepStart = Date()
            do {
                try await rec.prepare()
            } catch {
                XCTFail("[\(backend.rawValue)] prepare failed: \(error)")
                continue
            }
            let prepMs = Int(Date().timeIntervalSince(prepStart) * 1000)
            print("  prepare: \(prepMs) ms")

            // Warmup: transcribe the first fixture once and discard timing.
            // For Qwen this overlaps with prepare()'s built-in 1 s silence
            // warmup but exercises the actual fixture-shaped tensor path; for
            // Whisper this is the only warmup. Cheaper than running every
            // fixture twice.
            let warmupFixture = rows[0].fixture
            do {
                _ = try await rec.transcribe(
                    warmupFixture.audio,
                    language: warmupFixture.expected.languageEnum,
                    context: nil
                )
            } catch {
                print("  warmup threw (continuing): \(error)")
            }

            // Measure each fixture
            for idx in rows.indices {
                let row = rows[idx]
                let t0 = Date()
                let text: String
                do {
                    text = try await rec.transcribe(
                        row.fixture.audio,
                        language: row.fixture.expected.languageEnum,
                        context: nil
                    )
                } catch {
                    print("  [\(row.name)] threw: \(error)")
                    continue
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let rtf = Double(ms) / 1000.0 / row.durationSec
                rows[idx].msByBackend[backend] = ms
                rows[idx].charsByBackend[backend] = text.count

                let durStr = String(format: "%.1f", row.durationSec)
                let rtfStr = String(format: "%.2f", rtf)
                let nameCol = row.name.padding(toLength: 36, withPad: " ", startingAt: 0)
                print("  \(nameCol) \(durStr)s → \(String(ms).leftPadded(to: 5))ms (\(rtfStr)×) [\(text.count) chars]")
            }

            // Free Qwen weights between backends. Whisper has no unload (per
            // backendOrder rationale) — left in memory for the test process
            // tail and torn down by deinit.
            if let qwen = rec as? QwenASRRecognizer {
                qwen.unload()
            }
        }

        // ---- Cross-backend recap ----
        print("\n\n" + String(repeating: "=", count: 110))
        print("Backend speed benchmark recap — \(rows.count) fixtures × up to \(backendOrder.count) backends")
        print(String(repeating: "=", count: 110))

        let nameWidth = max(rows.map(\.name.count).max() ?? 24, 8)
        let cellWidth = 17
        var header = "  \("fixture".padding(toLength: nameWidth, withPad: " ", startingAt: 0))  dur "
        for backend in backendOrder {
            let label = backendShortLabel(backend).padding(toLength: cellWidth, withPad: " ", startingAt: 0)
            header += " │ \(label)"
        }
        print(header)
        print("  " + String(repeating: "-", count: header.count - 2))

        for row in rows {
            let name = row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let dur = String(format: "%.1fs", row.durationSec).padding(toLength: 5, withPad: " ", startingAt: 0)
            var line = "  \(name)  \(dur)"
            for backend in backendOrder {
                if let ms = row.msByBackend[backend] {
                    let rtf = Double(ms) / 1000.0 / row.durationSec
                    let cell = "\(String(ms).leftPadded(to: 5))ms / \(String(format: "%.2f", rtf))×"
                    line += " │ \(cell.padding(toLength: cellWidth, withPad: " ", startingAt: 0))"
                } else {
                    line += " │ \("—".padding(toLength: cellWidth, withPad: " ", startingAt: 0))"
                }
            }
            print(line)
        }

        // Average row — only fixtures the backend actually ran are included
        // for that backend's average (skipped fixtures don't pull it down).
        print("  " + String(repeating: "-", count: header.count - 2))
        var avgLine = "  " + "average".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "       "
        for backend in backendOrder {
            let measured: [(Int, Double)] = rows.compactMap { row in
                guard let ms = row.msByBackend[backend] else { return nil }
                return (ms, row.durationSec)
            }
            if measured.isEmpty {
                avgLine += " │ \("—".padding(toLength: cellWidth, withPad: " ", startingAt: 0))"
            } else {
                let avgMs = Int(measured.map { Double($0.0) }.reduce(0, +) / Double(measured.count))
                let avgRtf = measured.map { Double($0.0) / 1000.0 / $0.1 }.reduce(0, +) / Double(measured.count)
                let cell = "\(String(avgMs).leftPadded(to: 5))ms / \(String(format: "%.2f", avgRtf))×"
                avgLine += " │ \(cell.padding(toLength: cellWidth, withPad: " ", startingAt: 0))"
            }
        }
        print(avgLine)

        // Hardware footer — readers should know what machine produced these
        // numbers when comparing across runs / PRs.
        print("\n  hardware: \(hardwareDescription())")
    }

    private func backendShortLabel(_ b: ASRBackend) -> String {
        switch b {
        case .whisperLargeV3: return "Whisper l-v3"
        case .qwenASR06B:     return "Qwen 0.6B 4bit"
        case .qwenASR17B:     return "Qwen 1.7B 8bit"
        }
    }

    /// `sysctl -n machdep.cpu.brand_string` + total RAM. Best-effort — falls
    /// back to "unknown" if anything throws or returns non-utf8.
    private func hardwareDescription() -> String {
        let cpu = (try? shellOut("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])) ?? "unknown CPU"
        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        return "\(cpu.trimmingCharacters(in: .whitespacesAndNewlines)) · \(ramGB) GB RAM"
    }

    private func shellOut(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension String {
    /// Right-align this string in a column `width` wide.
    func leftPadded(to width: Int) -> String {
        let pad = width - self.count
        return pad > 0 ? String(repeating: " ", count: pad) + self : self
    }
}
