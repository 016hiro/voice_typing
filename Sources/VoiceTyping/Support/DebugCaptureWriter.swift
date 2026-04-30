import Foundation
import AVFoundation

/// v0.5.1 Debug Data Capture writer. One instance per dictation session;
/// serializes session metadata + audio + per-segment transcripts + per-inject
/// results to disk. Per `todo/v0.5.1.md` decisions:
///   - #1 audio captured by default (this writer always writes audio.wav)
///   - #2 LLM refine I/O **was** punted in v0.5.1 — landed in v0.6.3 #R8 as
///        `appendRefine` + `refines.jsonl` so cloud↔local refiner quality
///        can be A/B'd offline (the local MLX refiner is the use case)
///   - #3 per-session subdirectory layout
///   - #6 covers VAD replay / backend compare / hallucination ± / load-time
///        / inject latency / focus-change drop
///
/// Layout under `<support>/debug-captures/`:
/// ```
/// 2026-04-21_17-50-00_a1b2c3d4/
///   meta.json         session metadata + final stats
///   audio.wav         16 kHz mono Float32 — raw mic
///   segments.jsonl    one JSON per ASR segment (kept + filtered)
///   injections.jsonl  one JSON per inject attempt
///   refines.jsonl     one JSON per refine call (v0.6.3+; absent if no refine ran)
/// ```
///
/// Concurrency: append methods are called from background tasks (LiveTranscriber
/// pump + AppDelegate inject task); finalize from main actor at stopRecording.
/// All writes go through a serial DispatchQueue so the JSONL files stay
/// well-formed and the audio.wav write doesn't race with append.
final class DebugCaptureWriter: @unchecked Sendable {

    // MARK: - Records (also the on-disk schema)

    enum FilterDecision: String, Codable, Sendable {
        case kept                  // passed HallucinationFilter
        case hallucinationFiltered // dropped by HallucinationFilter
    }

    struct Meta: Codable {
        let sessionId: String
        let appVersion: String
        let startedAt: Date
        var endedAt: Date?
        let backend: String
        let language: String
        let liveMode: Bool
        let frontmostBundleID: String?
        let profileSnippet: String?
        let asrContextChars: Int
        var totalAudioSec: Double?
        var totalSegments: Int?
        var totalInjections: Int?
        var totalRefines: Int?       // v0.6.3 #R8 — populated by finalize/abort
    }

    struct SegmentRecord: Codable {
        let timestamp: Date
        let startSec: Double          // within session audio (0 if unknown)
        let endSec: Double
        let rawText: String           // before HallucinationFilter
        let filter: FilterDecision
        let transcribeMs: Int
    }

    enum InjectStatus: String, Codable, Sendable {
        case ok
        case focusChanged             // user switched apps mid-recording
        case skipped                  // empty text or pre-flight failure
    }

    struct InjectionRecord: Codable {
        let timestamp: Date
        let chars: Int
        let textPreview: String       // first 120 chars; full text is in segments.jsonl
        let targetBundleID: String?
        let actualBundleID: String?   // current frontmost — differs from target on focusChanged
        let status: InjectStatus
        let elapsedMs: Int
    }

    /// v0.6.3 #R8 — one record per `LLMRefining.refine(...)` call. Captured
    /// **only when** debug capture is enabled AND the call actually ran (mode
    /// `.off` / empty input early-returns are not recorded). Field set is
    /// designed for the cloud↔local A/B analysis: identical input + glossary +
    /// profile → compare `output` and `latencyMs` across `backend` values.
    struct RefineRecord: Codable {
        let timestamp: Date
        let input: String              // the raw text fed into refine (post-ASR, post-hallucination-filter)
        let output: String             // refiner's reply (or input if refine failed/no-op)
        let mode: String               // RefineMode.rawValue: light/aggressive/conservative
        let backend: String            // "cloud" or "local"
        let latencyMs: Int             // wall-clock of the refine() await
        let glossary: String?          // GlossaryBuilder.buildLLMGlossary output (nil if dictionary empty)
        let profileSnippet: String?    // per-app override snippet (nil if none)
        let rawFirst: Bool             // false = paste-after-refine; true = paste-then-refine flow
    }

    // MARK: - Lifecycle

    let folder: URL
    private let queue: DispatchQueue
    private var meta: Meta
    private var segmentCount = 0
    private var injectionCount = 0
    private var refineCount = 0
    private var finalized = false

    /// Returns nil when `state.debugCaptureEnabled` is off — call sites can
    /// pass through unconditionally. Creates the per-session directory eagerly
    /// so even a recording that crashes mid-session leaves an audit trail.
    /// `@MainActor` because it reads `AppState`; downstream `appendSegment` /
    /// `appendInjection` / `finalize` are thread-safe via the internal queue.
    @MainActor
    static func begin(
        state: AppState,
        backend: ASRBackend,
        language: Language,
        liveMode: Bool,
        frontmostBundleID: String?,
        profileSnippet: String?,
        asrContext: String?
    ) -> DebugCaptureWriter? {
        guard state.debugCaptureEnabled else { return nil }
        let started = Date()
        let sessionId = String(UUID().uuidString.prefix(8)).lowercased()
        let dirName = "\(Self.timestampFormatter.string(from: started))_\(sessionId)"
        let folder = DebugCapture.folderURL.appendingPathComponent(dirName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.app.warning("DebugCaptureWriter: failed to create session dir: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let meta = Meta(
            sessionId: sessionId,
            appVersion: appVersion,
            startedAt: started,
            endedAt: nil,
            backend: backend.rawValue,
            language: language.rawValue,
            liveMode: liveMode,
            frontmostBundleID: frontmostBundleID,
            profileSnippet: profileSnippet,
            asrContextChars: asrContext?.count ?? 0,
            totalAudioSec: nil,
            totalSegments: nil,
            totalInjections: nil,
            totalRefines: nil
        )
        return DebugCaptureWriter(folder: folder, meta: meta)
    }

    /// Internal so tests can construct a writer rooted at a temp folder
    /// without going through `begin(state:...)`. Production callers must use
    /// `begin(...)` so the AppState toggle is honored and the directory is
    /// created with the canonical timestamped name.
    init(folder: URL, meta: Meta) {
        self.folder = folder
        self.meta = meta
        self.queue = DispatchQueue(label: "voicetyping.debugcapture.\(meta.sessionId)", qos: .utility)
        // v0.5.3 fix: write a partial meta.json immediately. Previously meta
        // was only written from finalize/abort, so any crash / force-quit /
        // early bail left the session dir without metadata (12% of dogfood
        // sessions had usable meta in v0.5.2).
        //
        // v0.6.3 fix (#R8 dogfood): closures used to capture `[weak self]`,
        // which silently dropped writes whenever the writer's only strong
        // reference (the `captureWriter` local in pipelineTask) was released
        // before the queue scheduled the work. That race always lost for the
        // last enqueued operations — finalize() and the appendInjection just
        // before it — explaining why ~every dogfood session on disk had only
        // meta.json + segments.jsonl, never audio.wav or full meta. Now each
        // closure strong-captures self so the writer survives until the
        // queue drains. No retain cycle: each closure releases self when it
        // completes, and the queue itself is owned by self for its full life.
        queue.async {
            self.writeMeta()
        }
    }

    // MARK: - Append API

    func appendSegment(_ rec: SegmentRecord) {
        queue.async {
            guard !self.finalized else { return }
            self.segmentCount += 1
            self.appendJSONL(rec, file: self.folder.appendingPathComponent("segments.jsonl"))
        }
    }

    func appendInjection(_ rec: InjectionRecord) {
        queue.async {
            guard !self.finalized else { return }
            self.injectionCount += 1
            self.appendJSONL(rec, file: self.folder.appendingPathComponent("injections.jsonl"))
        }
    }

    /// v0.6.3 #R8 — append a single refine record. Only invoked when
    /// `state.debugCaptureEnabled` was true at session begin (writer instance
    /// would be nil otherwise) AND the refine call actually produced output
    /// (callers skip recording on the .off / empty-input early-returns inside
    /// `LLMRefining` implementations).
    func appendRefine(_ rec: RefineRecord) {
        queue.async {
            guard !self.finalized else { return }
            self.refineCount += 1
            self.appendJSONL(rec, file: self.folder.appendingPathComponent("refines.jsonl"))
        }
    }

    /// Write audio.wav + meta.json. Subsequent appends are no-ops. Synchronous
    /// from the queue's perspective (other appends already enqueued before
    /// `finalize` will land first; appends enqueued after will be dropped).
    func finalize(audio: AudioBuffer) {
        queue.async {
            guard !self.finalized else { return }
            self.finalized = true
            // Audio first — it's the largest file; if disk is full we want
            // meta.json to still reflect what was attempted.
            do {
                try Self.writeWAV(samples: audio.samples, sampleRate: 16_000,
                                   to: self.folder.appendingPathComponent("audio.wav"))
            } catch {
                Log.app.warning("DebugCaptureWriter: audio.wav write failed: \(error.localizedDescription, privacy: .public)")
            }
            self.meta.endedAt = Date()
            self.meta.totalAudioSec = audio.duration
            self.meta.totalSegments = self.segmentCount
            self.meta.totalInjections = self.injectionCount
            self.meta.totalRefines = self.refineCount
            self.writeMeta()
            Log.app.info("DebugCapture session: \(self.meta.sessionId, privacy: .public) — \(self.segmentCount, privacy: .public) seg, \(self.injectionCount, privacy: .public) inj, \(self.refineCount, privacy: .public) ref, \(audio.duration, format: .fixed(precision: 1))s audio → \(self.folder.lastPathComponent, privacy: .public)")
        }
    }

    /// Best-effort cancel. Same semantics as finalize but no audio is written —
    /// the partial session dir is left on disk so the user can inspect it.
    /// Used when stopRecording bails early (e.g. buffer too short).
    func abort() {
        queue.async {
            guard !self.finalized else { return }
            self.finalized = true
            self.meta.endedAt = Date()
            self.meta.totalSegments = self.segmentCount
            self.meta.totalInjections = self.injectionCount
            self.meta.totalRefines = self.refineCount
            self.writeMeta()
        }
    }

    // MARK: - File helpers

    /// Test support: block until all writer work enqueued before this call has
    /// completed. This is intentionally not used by production code.
    func waitUntilIdleForTesting() {
        queue.sync {}
    }

    /// Writes meta.json with the current `meta` value. Called from the serial
    /// queue; safe to invoke multiple times (init writes partial; finalize/abort
    /// overwrite atomically with final fields populated).
    private func writeMeta() {
        do {
            let data = try Self.metaEncoder.encode(self.meta)
            try data.write(to: self.folder.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            Log.app.warning("DebugCaptureWriter: meta.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendJSONL<T: Encodable>(_ rec: T, file url: URL) {
        do {
            var data = try Self.jsonlEncoder.encode(rec)
            data.append(0x0A) // '\n'
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            Log.app.warning("DebugCaptureWriter: JSONL append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // v0.5.3 fix: ISO8601 with fractional seconds. The default `.iso8601`
    // strategy emits seconds-only timestamps, which collapsed `endedAt -
    // last inject` deltas to 0 ms in live_drain.py. ISO8601DateFormatter is
    // documented thread-safe but predates Sendable; the `nonisolated(unsafe)`
    // is the explicit acknowledgement.
    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let metaEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Fractional.string(from: date))
        }
        return e
    }()

    private static let jsonlEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Fractional.string(from: date))
        }
        return e
    }()

    /// Writes a 16 kHz mono Float32 WAV. Standard PCM Float32 format —
    /// readable by ffmpeg, sox, Audacity, QuickTime, and the test
    /// `FixtureLoader` in this repo.
    static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "DebugCaptureWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate write buffer"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let ptr = buffer.floatChannelData?.pointee {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    ptr.update(from: base, count: samples.count)
                }
            }
        }
        try file.write(from: buffer)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
