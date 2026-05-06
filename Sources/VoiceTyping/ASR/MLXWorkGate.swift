import Foundation

/// Coordinates MLX work across user-visible callers (live transcribe, batch
/// transcribe, refiner) and background callers (`ASRKeepAlive` ticks).
///
/// Why this exists — v0.7.1 #B6 root cause
/// ----------------------------------------
/// MLX's `compile()` produces a process-global `CompiledFunction` cache; each
/// entry holds an `NSRecursiveLock` taken inside `innerCall` and held across
/// `eval()` → `mlx::core::Event::wait()` → `IOSurfaceSharedEvent
/// waitUntilSignaledValue:`. When the GPU event takes 30+ s to fire (cold
/// path / power state / memory pressure), every other caller of the same
/// compiled function in the same process serialises behind it.
///
/// `relu` is shared across `Qwen3AudioEncoder` and `SileroVADNetwork.forward`
/// — so `ASRKeepAlive`'s background dummy transcribe can hold the lock and
/// block a user-visible Fn↓ for 30+ s. The hang stack at
/// `~/Library/Application Support/VoiceTyping/hang-stacks/2026-05-03T15-02-15Z_live-vad-process.txt`
/// shows three threads converging on the same lock.
///
/// What this fixes
/// ---------------
/// We can't release the MLX lock — it's internal. We *can* refuse to start
/// a keep-alive tick while the user is mid-call, so the lock contention
/// window collapses to "user vs user" (which is fine — `transcribeLock`
/// serialises those serially without the cross-callsite blocking) plus
/// "first-cold-press after long idle" (which was the original v0.6.4 problem
/// keep-alive was meant to mitigate; we're trading off the cold-press slowness
/// against the keep-alive-induced hang).
///
/// What this does NOT fix
/// ----------------------
/// A keep-alive tick that has already entered `model.transcribe` cannot be
/// interrupted. If the user presses Fn during that window, they still wait.
/// The gate only prevents NEW concurrent ticks; it can't cancel one in flight.
///
/// Logging
/// -------
/// Every begin/end goes through `.notice` in `Log.asr` so dogfood Console can
/// see exactly which callsite holds MLX at any moment without Developer
/// logging on. Dogfood signal we want to confirm post-fix:
///   - `MLXWorkGate keep-alive '...' denied` lines should appear when user
///     presses Fn during a tick — proves the gate is doing its job.
///   - User-visible MLX call elapsed times stay sub-second.
final class MLXWorkGate: @unchecked Sendable {

    static let shared = MLXWorkGate()

    private let lock = NSLock()
    /// Per-callsite count of in-flight user-visible MLX work. Map (not just
    /// int) so logs can name the callsite.
    private var userInflight: [String: Int] = [:]
    /// Single in-flight keep-alive callsite (if any). At most one keep-alive
    /// can be running at a time — that's a contract enforced here.
    private var keepAliveInflight: String?

    private init() {}

    // MARK: - User-visible work

    /// Wrap a user-visible MLX call. Always proceeds; logs begin/end and
    /// drives the keep-alive gate. Use this for synchronous bodies; use
    /// `beginUser`/`endUser` directly for streaming/async work that can't
    /// fit the closure shape (e.g. `LocalMLXRefiner.streamResponse`).
    func runUser<T>(callsite: String, body: () -> T) -> T {
        beginUser(callsite: callsite)
        defer { endUser(callsite: callsite) }
        return body()
    }

    func beginUser(callsite: String) {
        let total: Int = lock.withLock {
            userInflight[callsite, default: 0] += 1
            return userInflight.values.reduce(0, +)
        }
        Log.asr.notice("MLXWorkGate user begin '\(callsite, privacy: .public)' (totalUser=\(total, privacy: .public))")
    }

    func endUser(callsite: String) {
        let total: Int = lock.withLock {
            let n = userInflight[callsite] ?? 0
            if n <= 1 {
                userInflight.removeValue(forKey: callsite)
            } else {
                userInflight[callsite] = n - 1
            }
            return userInflight.values.reduce(0, +)
        }
        Log.asr.notice("MLXWorkGate user end   '\(callsite, privacy: .public)' (totalUser=\(total, privacy: .public))")
    }

    // MARK: - Keep-alive (try-acquire)

    /// Try to run a keep-alive MLX call. Returns `body()`'s value if accepted,
    /// or `nil` if denied (because user-visible work is already in flight, or
    /// another keep-alive tick is already running).
    func tryRunKeepAlive<T>(callsite: String, body: () -> T) -> T? {
        let acquired: Bool = lock.withLock {
            guard userInflight.values.reduce(0, +) == 0,
                  keepAliveInflight == nil else { return false }
            keepAliveInflight = callsite
            return true
        }
        guard acquired else {
            Log.asr.notice("MLXWorkGate keep-alive '\(callsite, privacy: .public)' DENIED (user work in flight or another tick already running)")
            return nil
        }
        Log.asr.notice("MLXWorkGate keep-alive '\(callsite, privacy: .public)' begin")
        let started = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lock.withLock { keepAliveInflight = nil }
            Log.asr.notice("MLXWorkGate keep-alive '\(callsite, privacy: .public)' end (\(ms, privacy: .public)ms)")
        }
        return body()
    }
}
