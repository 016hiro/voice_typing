import AppKit
import MLX

// v0.7.3 #B8b: cap MLX's GPU buffer pool. Without this, mlx-swift uses
// Metal's `recommendedMaxWorkingSetSize` as the implicit cache ceiling —
// on a 24 GB Mac that's ~16 GB, and the pool fills with ~2.4 GB after the
// very first refine and 5+ GB within 7 minutes (per #B8a telemetry).
// Left unconstrained the process bloats to 15+ GB IOAccelerator RSS after
// ~2 days uptime, the compressor swaps ~14 GB of those GPU pages, and
// subsequent refine latency walks from 1.3 s p50 → 2.6 s p50 as MLX
// touches pages that must be decompressed first.
// 1 GB ceiling covers one refine's working-set (~1.3 GB peak delta) +
// modest reuse headroom; excess buffers get freed back to Metal on the
// next dealloc rather than parked in the pool. Set before AppDelegate
// constructs so the first ASR / refiner load runs under the cap.
MLX.Memory.cacheLimit = 1_000_000_000

MainActor.assumeIsolated {
    // v0.3.x → v0.4.0: move API key from UserDefaults plaintext to the
    // Keychain. Must run before `AppDelegate()` because the delegate owns
    // an `AppState` stored property whose initializer reads `llmConfig` —
    // if migration ran after, the in-memory struct would still have an
    // empty apiKey until an unrelated save triggered a reload.
    LLMConfigStore.migrateIfNeeded()

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
    app.run()
}
