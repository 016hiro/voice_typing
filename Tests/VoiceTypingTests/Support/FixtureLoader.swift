import Foundation
import AVFoundation
import XCTest
@testable import VoiceTyping

/// Locates fixtures under `$VT_FIXTURE_ROOT` (set by the Makefile test targets
/// to `<repo>/Tests/Fixtures`). Tests skip themselves when the env var is
/// missing or the specific fixture hasn't been recorded / downloaded yet.
enum FixtureLoader {

    struct Expected: Codable {
        /// Optional keywords. If empty, the comparison test skips per-backend
        /// keyword assertions — length bounds + batch-vs-streaming similarity
        /// still apply. For a new fixture you don't have to hand-pick keywords
        /// up front; drop the WAV in and run, read the printed transcripts, and
        /// only add keywords later if you want a hard bar on specific terms.
        var keywords: [String] = []
        /// Lower bound on transcript length; guards against empty / near-empty
        /// output that still happened to match a keyword subset by luck.
        var minChars: Int = 0
        /// Upper bound on transcript length; guards against runaway hallucination
        /// where the model invents a much longer text.
        var maxChars: Int = 10_000
        /// Streaming only: minimum number of partial yields we expect. >1 means
        /// the recording genuinely contains VAD-splittable utterances.
        var streamingMinPartials: Int = 1
        /// Rawvalue of `Language` enum. Defaults to `en`.
        var language: String = "en"

        var languageEnum: Language {
            Language(rawValue: language) ?? .en
        }

        // Custom decoder so missing fields fall back to the defaults declared
        // above — Swift's synthesised Codable init would throw on any missing
        // key. This lets a new fixture's expected.json be a minimal stub
        // (even `{}` works).
        private enum CodingKeys: String, CodingKey {
            case keywords, minChars, maxChars, streamingMinPartials, language
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
            self.minChars = try c.decodeIfPresent(Int.self, forKey: .minChars) ?? 0
            self.maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? 10_000
            self.streamingMinPartials = try c.decodeIfPresent(Int.self, forKey: .streamingMinPartials) ?? 1
            self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        }
    }

    struct LoadedFixture {
        let audio: VoiceTyping.AudioBuffer
        let expected: Expected
        let name: String
    }

    /// Returns the fixture root; throws XCTSkip if unset or missing.
    static func root(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["VT_FIXTURE_ROOT"] else {
            throw XCTSkip("VT_FIXTURE_ROOT not set (run via `make test-e2e`).",
                          file: file, line: line)
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Fixture root does not exist: \(url.path)",
                          file: file, line: line)
        }
        return url
    }

    /// Returns the names of all `*.wav` fixtures that have a matching
    /// `*.expected.json` sidecar. Skips if fixture root is unavailable.
    static func allNames(file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let root = try root(file: file, line: line)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "wav" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { name in
                FileManager.default.fileExists(atPath: root.appendingPathComponent("\(name).expected.json").path)
            }
            .sorted()
    }

    /// Loads `<root>/<name>.wav` + `<root>/<name>.expected.json`, decoded to a
    /// 16 kHz mono Float32 `VoiceTyping.AudioBuffer`. Skips if either file is missing.
    static func load(_ name: String,
                     file: StaticString = #filePath,
                     line: UInt = #line) throws -> LoadedFixture {
        let root = try root(file: file, line: line)
        let wav = root.appendingPathComponent("\(name).wav")
        let meta = root.appendingPathComponent("\(name).expected.json")

        guard FileManager.default.fileExists(atPath: wav.path) else {
            throw XCTSkip("Fixture audio missing: \(wav.lastPathComponent) — add it under Tests/Fixtures/",
                          file: file, line: line)
        }
        guard FileManager.default.fileExists(atPath: meta.path) else {
            throw XCTSkip("Fixture metadata missing: \(meta.lastPathComponent)",
                          file: file, line: line)
        }

        let audio = try loadWAV(at: wav)
        let expected = try JSONDecoder().decode(
            Expected.self, from: Data(contentsOf: meta)
        )
        return LoadedFixture(audio: audio, expected: expected, name: name)
    }

    /// Reads a 16 kHz mono Float32 WAV into our `VoiceTyping.AudioBuffer`. Fails if the file
    /// is in a different format — the fixture scripts pre-convert so this is a
    /// lightweight reader, not a resampler.
    private static func loadWAV(at url: URL) throws -> VoiceTyping.AudioBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        guard Int(format.sampleRate) == 16_000, format.channelCount == 1 else {
            throw NSError(
                domain: "FixtureLoader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Fixture must be 16 kHz mono (got \(Int(format.sampleRate)) Hz, \(format.channelCount) ch). Re-generate via fixture script."]
            )
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(
                domain: "FixtureLoader", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate read buffer"]
            )
        }
        try file.read(into: buffer)

        let frames = Int(buffer.frameLength)
        guard frames > 0, let ch = buffer.floatChannelData else {
            return VoiceTyping.AudioBuffer(samples: [], sampleRate: 16_000)
        }
        var samples = [Float](repeating: 0, count: frames)
        let ptr = ch[0]
        for i in 0..<frames { samples[i] = ptr[i] }
        return VoiceTyping.AudioBuffer(samples: samples, sampleRate: 16_000)
    }
}

/// Case-insensitive keyword containment with a useful failure message.
func XCTAssertContainsKeywords(
    _ transcript: String,
    _ keywords: [String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let lower = transcript.lowercased()
    let missing = keywords.filter { !lower.contains($0.lowercased()) }
    XCTAssertTrue(
        missing.isEmpty,
        "transcript missing keywords \(missing) — got: \"\(transcript)\"",
        file: file, line: line
    )
}
