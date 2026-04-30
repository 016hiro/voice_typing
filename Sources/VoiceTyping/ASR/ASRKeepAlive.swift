import Foundation

/// Subset of `QwenASRRecognizer` that `ASRKeepAlive` actually needs. Lets unit
/// tests drive a fake without spinning up MLX shaders + downloads.
protocol KeepAliveTarget: AnyObject, Sendable {
    var state: RecognizerState { get }
    func transcribeSegmentSync(samples: [Float], language: String, context: String?) -> String
}

extension QwenASRRecognizer: KeepAliveTarget {}

/// v0.6.4: periodic dummy transcribe so macOS unified-memory compressor
/// can't compress the MLX weight pages while the user idles. Without this,
/// first-press ASR after 1-2h idle takes 9-30s (cold-decompress) instead of
/// the 99-550ms warm baseline. See `docs/todo/v0.6.4.md` for the full design.
///
/// Lifecycle is owned by `AppDelegate`: started when the recognizer reaches
/// `.ready`, stopped on backend swap / non-ready state / app terminate.
/// Whisper backends bypass this entirely (CoreML weights live in the ANE
/// pool, unaffected by compressor).
final class ASRKeepAlive: @unchecked Sendable {

    /// Production cadence. Compressor's typical decision window is 5-10
    /// minutes; 90 s sits comfortably inside it at ~0.3% sustained CPU.
    /// Bumping past ~180 s starts losing reliability; dropping below 60 s
    /// burns measurable battery for no benefit. Hard-coded — not exposed
    /// to Settings per v0.6.4 scope decision (no UI cost worth the knob).
    static let defaultInterval: TimeInterval = 90

    /// 200 ms of silence at 16 kHz = 3200 samples. Must exceed
    /// `WhisperFeatureExtractor`'s minimum 400-sample window or the
    /// `transcribeSegmentSync` early-return fires before the model
    /// touches its weight pages — defeating the whole point. Longer than
    /// 200 ms risks ANE-queue contention with a real user request that
    /// happens to land on the same tick.
    static let dummySamples: [Float] = Array(repeating: 0, count: 16_000 / 5)

    /// Language is irrelevant for an all-silence buffer — VAD-equivalent
    /// preprocessing inside Qwen will yield empty token output regardless.
    /// Pinned to a constant to avoid a needless dependency on `AppState`.
    static let dummyLanguage: String = "en"

    private let interval: TimeInterval
    private let lock = NSLock()
    private weak var target: KeepAliveTarget?
    private var timer: Timer?

    init(interval: TimeInterval = ASRKeepAlive.defaultInterval) {
        self.interval = interval
    }

    deinit {
        timer?.invalidate()
    }

    /// Replace any existing target and (re)start the timer. Safe to call
    /// repeatedly — each call cancels the previous timer first, so backend
    /// swaps don't leave a stale tick driving an unloaded recognizer.
    @MainActor
    func start(target: KeepAliveTarget) {
        stop()
        lock.lock()
        self.target = target
        lock.unlock()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Tick runs `transcribeSegmentSync` which blocks for ~50-200 ms;
            // dispatch off-main so the tick can never stall the UI runloop.
            Task.detached(priority: .background) { [weak self] in
                self?.tick()
            }
        }
        timer = t
        Log.dev(Log.asr, "ASRKeepAlive started (interval=\(Int(interval))s)")
    }

    @MainActor
    func stop() {
        timer?.invalidate()
        timer = nil
        lock.lock()
        target = nil
        lock.unlock()
    }

    /// Internal so unit tests can drive a tick deterministically. Skips when
    /// the recognizer isn't `.ready` so we don't start dispatching dummy
    /// transcribes against a half-loaded model.
    func tick() {
        let snapshot: KeepAliveTarget? = {
            lock.lock(); defer { lock.unlock() }
            return target
        }()
        guard let t = snapshot else { return }
        guard case .ready = t.state else {
            Log.dev(Log.asr, "ASRKeepAlive tick skipped (state != .ready)")
            return
        }
        _ = t.transcribeSegmentSync(
            samples: ASRKeepAlive.dummySamples,
            language: ASRKeepAlive.dummyLanguage,
            context: nil
        )
        Log.dev(Log.asr, "ASRKeepAlive tick")
    }
}
