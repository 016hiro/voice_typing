import Foundation
import AppKit

/// Subset of `QwenASRRecognizer` that `ASRKeepAlive` actually needs. Lets unit
/// tests drive a fake without spinning up MLX shaders + downloads.
///
/// v0.7.1 #B6: returns `(text, lockWaitMs)` so live-mode callers can record
/// `transcribeLock` wait time per segment. Keep-alive itself ignores
/// `lockWaitMs` (it's not on the user-visible critical path), but the
/// live pump uses it to fill `SegmentRecord.lockWaitMs`.
///
/// v0.7.1 #B6 follow-up: `maxTokens` is now explicit at the protocol level so
/// the keep-alive can pass a much smaller cap (silent input has no real EOS
/// signal; the decoder otherwise runs the full 448-token budget on a cold
/// MLX path → 30-45 s tick). Live/batch callers keep the 448 default via
/// `QwenASRRecognizer`'s concrete implementation.
protocol KeepAliveTarget: AnyObject, Sendable {
    var state: RecognizerState { get }
    func transcribeSegmentSync(samples: [Float], language: String, context: String?, maxTokens: Int) -> (text: String, lockWaitMs: Int)
}

extension QwenASRRecognizer: KeepAliveTarget {}

/// v0.6.4: periodic dummy transcribe so macOS unified-memory compressor
/// can't compress the MLX weight pages while the user idles. Without this,
/// first-press ASR after 1-2h idle takes 9-30s (cold-decompress) instead of
/// the 99-550ms warm baseline. See `docs/todo/v0.6.4.md` for the full design.
///
/// v0.7.1 fixes (post-dogfood): the v0.6.4 ship made outliers WORSE
/// (≥5s rate 2.2% → 5.3% across versions in segment_latency.py output).
/// Three independent reasons the timer was effectively dead in dogfood:
///   1. App Nap throttled `.accessory` LSUIElement processes — `beginActivity`
///      now suppresses it explicitly.
///   2. mac sleep/wake paged out weights AND kept the timer dormant past
///      the first user keypress — `NSWorkspace.didWakeNotification` now
///      fires an immediate tick on wake.
///   3. `Log.dev` was off in release dogfood, so we had ZERO observability
///      whether ticks ran at all — now logs at `.notice` and the tick
///      counter is exposed for `DebugCaptureWriter` to record per session.
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
    /// `QwenASRRecognizer.transcribeSegmentSync`'s 400-sample early-return
    /// (line 211) or the model layer is never reached — defeating the whole
    /// point. Longer than 200 ms risks Metal-queue contention with a real
    /// user request that happens to land on the same tick.
    static let dummySamples: [Float] = Array(repeating: 0, count: 16_000 / 5)

    /// Language is irrelevant for an all-silence buffer — VAD-equivalent
    /// preprocessing inside Qwen will yield empty token output regardless.
    /// Pinned to a constant to avoid a needless dependency on `AppState`.
    static let dummyLanguage: String = "en"

    /// v0.7.1 #B6: silent input has no real EOS signal — the decoder can
    /// happily run the full 448-token budget on a cold MLX path, taking
    /// 30-45 s per tick (observed in dogfood `2026-05-04_15-24-38` where a
    /// concurrent live press waited 42.5 s on `transcribeLock`). 4 tokens
    /// is enough to exercise audio encoder + first decoder pass + a couple
    /// follow-ups so MLX weights / Metal queue stay warm; bounds the worst-
    /// case cold-tick at `4 × per_token` (a few seconds at most).
    static let dummyMaxTokens: Int = 4

    private let interval: TimeInterval
    private let lock = NSLock()
    private weak var target: KeepAliveTarget?
    private var timer: Timer?
    private var activityToken: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// Monotonic count of completed ticks since process start. Read via
    /// `tickCountSnapshot` — the only intended consumer is `DebugCaptureWriter`
    /// which records it per session so dogfood data answers "did the timer
    /// actually fire?" without requiring Developer logging to be on.
    private var tickCount: Int = 0

    init(interval: TimeInterval = ASRKeepAlive.defaultInterval) {
        self.interval = interval
    }

    deinit {
        timer?.invalidate()
    }

    var tickCountSnapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return tickCount
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

        // Suppress App Nap. `.userInitiated` is the standard recipe used by
        // background-utility apps (Slack/Dropbox/etc.) — it asks macOS to
        // keep us scheduling-eligible without preventing system sleep
        // (`.idleSystemSleepDisabled` would, and we don't want that —
        // battery + thermal cost too high for a background ping).
        self.activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "VoiceTyping ASR keep-alive (anti-compressor)"
        )

        // Wake-from-sleep handler: while sleeping the timer is dormant AND
        // macOS pages out our MLX weights, so the first user keypress after
        // wake (within ~90s of the next scheduled tick) hits the original
        // cold-decompress bug. Fire an immediate tick on wake instead.
        let center = NSWorkspace.shared.notificationCenter
        self.wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Log.asr.notice("ASRKeepAlive wake-from-sleep — firing immediate tick")
            Task.detached(priority: .utility) { [weak self] in
                self?.tick()
            }
        }

        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Tick runs `transcribeSegmentSync` which blocks for ~50-200 ms;
            // dispatch off-main so the tick can never stall the UI runloop.
            // `.utility` (not `.background`) so App Nap / QoS scheduler can't
            // defer the work indefinitely — `.background` is the lowest QoS
            // and was a contributing factor to v0.6.4 dogfood ineffectiveness.
            Task.detached(priority: .utility) { [weak self] in
                self?.tick()
            }
        }
        timer = t
        Log.asr.notice("ASRKeepAlive started (interval=\(Int(self.interval), privacy: .public)s, App Nap suppressed)")
    }

    @MainActor
    func stop() {
        timer?.invalidate()
        timer = nil

        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }

        lock.lock()
        target = nil
        lock.unlock()
    }

    /// Internal so unit tests can drive a tick deterministically. Skips when
    /// the recognizer isn't `.ready` so we don't start dispatching dummy
    /// transcribes against a half-loaded model.
    ///
    /// v0.7.1 #B6: gated through `MLXWorkGate.shared.tryRunKeepAlive`. If
    /// any user-visible MLX call is in flight (live transcribe / batch /
    /// refiner), the tick is denied and the dummy transcribe never runs.
    /// This stops the original hang signature where a 30s cold-path tick
    /// held MLX's per-CompiledFunction lock and blocked the user's
    /// next Fn↓ for the same 30s.
    func tick() {
        let snapshot: KeepAliveTarget? = {
            lock.lock(); defer { lock.unlock() }
            return target
        }()
        guard let t = snapshot else { return }
        guard case .ready = t.state else {
            Log.asr.notice("ASRKeepAlive tick skipped (state != .ready)")
            return
        }
        let started = Date()
        let ran: Bool = MLXWorkGate.shared.tryRunKeepAlive(callsite: "asrKeepAlive") {
            _ = t.transcribeSegmentSync(
                samples: ASRKeepAlive.dummySamples,
                language: ASRKeepAlive.dummyLanguage,
                context: nil,
                maxTokens: ASRKeepAlive.dummyMaxTokens
            )
            return true
        } ?? false

        guard ran else { return }   // gate denied — don't bump tickCount
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        lock.lock()
        tickCount += 1
        let n = tickCount
        lock.unlock()

        Log.asr.notice("ASRKeepAlive tick #\(n, privacy: .public) (\(elapsedMs, privacy: .public)ms)")
    }
}
