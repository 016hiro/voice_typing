import Foundation
import AVFoundation

/// v0.5.1 Debug Data Capture writer. One instance per dictation session;
/// serializes session metadata + audio + per-segment transcripts + per-inject
/// results to disk. Per `todo/v0.5.1.md` decisions:
///   - #1 audio captured by default (this writer always writes audio.wav)
///   - #2 LLM refine I/O **NOT** captured (no `appendRefine` API)
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

    // MARK: - Lifecycle

    let folder: URL
    private let queue: DispatchQueue
    private var meta: Meta
    private var segmentCount = 0
    private var injectionCount = 0
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
            totalInjections: nil
        )
        return DebugCaptureWriter(folder: folder, meta: meta)
    }

    private init(folder: URL, meta: Meta) {
        self.folder = folder
        self.meta = meta
        self.queue = DispatchQueue(label: "voicetyping.debugcapture.\(meta.sessionId)", qos: .utility)
    }

    // MARK: - Append API

    func appendSegment(_ rec: SegmentRecord) {
        queue.async { [weak self] in
            guard let self, !self.finalized else { return }
            self.segmentCount += 1
            self.appendJSONL(rec, file: self.folder.appendingPathComponent("segments.jsonl"))
        }
    }

    func appendInjection(_ rec: InjectionRecord) {
        queue.async { [weak self] in
            guard let self, !self.finalized else { return }
            self.injectionCount += 1
            self.appendJSONL(rec, file: self.folder.appendingPathComponent("injections.jsonl"))
        }
    }

    /// Write audio.wav + meta.json. Subsequent appends are no-ops. Synchronous
    /// from the queue's perspective (other appends already enqueued before
    /// `finalize` will land first; appends enqueued after will be dropped).
    func finalize(audio: AudioBuffer) {
        queue.async { [weak self] in
            guard let self, !self.finalized else { return }
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
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(self.meta)
                try data.write(to: self.folder.appendingPathComponent("meta.json"), options: .atomic)
            } catch {
                Log.app.warning("DebugCaptureWriter: meta.json write failed: \(error.localizedDescription, privacy: .public)")
            }
            Log.app.info("DebugCapture session: \(self.meta.sessionId, privacy: .public) — \(self.segmentCount, privacy: .public) seg, \(self.injectionCount, privacy: .public) inj, \(audio.duration, format: .fixed(precision: 1))s audio → \(self.folder.lastPathComponent, privacy: .public)")
        }
    }

    /// Best-effort cancel. Same semantics as finalize but no audio is written —
    /// the partial session dir is left on disk so the user can inspect it.
    /// Used when stopRecording bails early (e.g. buffer too short).
    func abort() {
        queue.async { [weak self] in
            guard let self, !self.finalized else { return }
            self.finalized = true
            self.meta.endedAt = Date()
            self.meta.totalSegments = self.segmentCount
            self.meta.totalInjections = self.injectionCount
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(self.meta)
                try data.write(to: self.folder.appendingPathComponent("meta.json"), options: .atomic)
            } catch {
                // Swallow — abort is best-effort.
            }
        }
    }

    // MARK: - File helpers

    private func appendJSONL<T: Encodable>(_ rec: T, file url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(rec)
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
            AVLinearPCMIsNonInterleaved: false,
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
