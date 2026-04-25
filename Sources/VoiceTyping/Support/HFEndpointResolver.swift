import Foundation
import os

/// Decide which HuggingFace endpoint (official vs hf-mirror.com) to use,
/// based on a one-shot bandwidth probe at app launch. Sets the `HF_ENDPOINT`
/// environment variable so swift-transformers' `HubApi` picks it up
/// transparently for all model downloads (WhisperKit + speech-swift).
///
/// Decision policy lives in `chooseEndpoint(...)` for testability.
enum HFEndpointResolver {

    // MARK: - Endpoints

    static let officialURL = URL(string: "https://huggingface.co")!
    static let mirrorURL   = URL(string: "https://hf-mirror.com")!

    // MARK: - Probe knobs

    /// File used for the bandwidth probe. Must exist on BOTH official and
    /// mirror; large enough that a 512 KB Range request always returns
    /// useful data. Chosen: AudioEncoder weight from
    /// `argmaxinc/whisperkit-coreml`'s large-v3 model (~600 MB; we already
    /// depend on this repo for the default Whisper backend).
    static let probePath = "argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-large-v3/AudioEncoder.mlmodelc/weights/weight.bin"

    /// 512 KiB. Range request reads exactly this many bytes regardless of
    /// total file size.
    static let probeBytes: Int64 = 524_288

    /// Per-source probe timeout. Generous enough to cover real-world TLS +
    /// redirect chains over slow international links (observed: hf-mirror
    /// TTFB 9.5 s from a CN home network behind a proxy). At the OK
    /// threshold (100 KB/s) the 512 KB transfer takes ~5 s, well under
    /// this budget. Sources slower than ~25 KB/s get classified as failed.
    static let probeTimeoutSec: TimeInterval = 20

    /// Max time `awaitResolutionIfPending` will block before falling back
    /// to whatever endpoint is already set. Sized to cover the probe budget
    /// plus a small margin so the lazy-await path actually waits for the
    /// in-flight race instead of giving up early on slow links.
    static let lazyAwaitTimeoutSec: TimeInterval = 22

    // MARK: - Decision thresholds

    /// Below this, a source is "too slow to be acceptable".
    static let okThresholdKBps: Double = 100

    /// Mirror must beat official by at least this multiple to win when
    /// both are above the OK threshold (avoids edge-noise flapping).
    static let mirrorBigWinMultiplier: Double = 5.0

    // MARK: - Cache TTL (asymmetric: bias toward official as source-of-truth)

    static let officialCacheTTL: TimeInterval = 24 * 3600
    static let mirrorCacheTTL: TimeInterval   = 6 * 3600

    // MARK: - UserDefaults keys

    private enum Keys {
        static let cachedURL    = "hfEndpointCachedURL"
        static let cachedAt     = "hfEndpointCachedAt"
        static let cachedSource = "hfEndpointCachedSource"  // "official" | "mirror"
        /// Hidden override. Not exposed in Settings UI; debug only.
        /// CLI: `defaults write voice_typing voice_typing.hfEndpoint <url>`
        static let manualOverride = "voice_typing.hfEndpoint"
    }

    // MARK: - In-flight state

    private static let stateLock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var inflightTask: Task<URL, Never>?
    }

    // MARK: - Public API: sync (call before any HubApi is constructed)

    /// Sync entry called from `applicationWillFinishLaunching`. Sets
    /// `HF_ENDPOINT` based on hidden override → cache → default fall-through.
    static func applyCachedOrDefault() {
        let chosen = decideCachedOrDefault(defaults: .standard, now: Date())
        setenv("HF_ENDPOINT", chosen.absoluteString, 1)
        Log.app.info("HFEndpointResolver applyCachedOrDefault → \(chosen.absoluteString, privacy: .public)")
    }

    /// Pure decision used by `applyCachedOrDefault`. Visible for tests.
    static func decideCachedOrDefault(defaults ud: UserDefaults, now: Date) -> URL {
        if let manual = ud.string(forKey: Keys.manualOverride),
           !manual.isEmpty,
           let url = URL(string: manual) {
            return url
        }

        if let urlStr = ud.string(forKey: Keys.cachedURL),
           let url = URL(string: urlStr),
           let cachedAt = ud.object(forKey: Keys.cachedAt) as? Date,
           let source = ud.string(forKey: Keys.cachedSource) {
            let ttl = (source == "mirror") ? mirrorCacheTTL : officialCacheTTL
            if now.timeIntervalSince(cachedAt) < ttl {
                return url
            }
        }

        return officialURL
    }

    // MARK: - Public API: async (background race + lazy await)

    /// Probe both endpoints concurrently, choose per the decision table,
    /// persist to cache, and update `HF_ENDPOINT`. Idempotent under
    /// concurrent invocation — the second caller awaits the first's task.
    @discardableResult
    static func resolveAndApply() async -> URL {
        if let manual = UserDefaults.standard.string(forKey: Keys.manualOverride),
           !manual.isEmpty,
           let url = URL(string: manual) {
            return url
        }

        let task: Task<URL, Never> = stateLock.withLock { state in
            if let existing = state.inflightTask {
                return existing
            }
            let new = Task<URL, Never> { await Self.runProbeAndChoose() }
            state.inflightTask = new
            return new
        }

        let chosen = await task.value
        stateLock.withLock { $0.inflightTask = nil }
        return chosen
    }

    /// If a probe is currently in flight (started by the background task in
    /// `applicationDidFinishLaunching`), block up to `timeout` for it.
    /// Otherwise return immediately. Used right before the download trigger
    /// so first-time installs don't race the env.
    static func awaitResolutionIfPending(timeout: TimeInterval = lazyAwaitTimeoutSec) async {
        let inflight: Task<URL, Never>? = stateLock.withLock { $0.inflightTask }
        guard let task = inflight else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Decision (pure, testable)

    /// Returns the chosen URL plus source label ("official" | "mirror").
    /// `nil` for either side means "probe failed / timed out".
    static func chooseEndpoint(official: Double?, mirror: Double?) -> (URL, String) {
        guard let off = official, off > 0 else {
            if let m = mirror, m >= okThresholdKBps {
                return (mirrorURL, "mirror")
            }
            return (officialURL, "official")
        }

        if off >= okThresholdKBps {
            if let m = mirror, m >= off * mirrorBigWinMultiplier {
                return (mirrorURL, "mirror")
            }
            return (officialURL, "official")
        }

        if let m = mirror, m >= okThresholdKBps {
            return (mirrorURL, "mirror")
        }
        return (officialURL, "official")
    }

    // MARK: - Internals

    private static func runProbeAndChoose() async -> URL {
        async let off = probe(base: officialURL)
        async let mir = probe(base: mirrorURL)
        let (offSpeed, mirSpeed) = await (off, mir)
        let (chosen, source) = chooseEndpoint(official: offSpeed, mirror: mirSpeed)
        persist(chosen: chosen, source: source)
        setenv("HF_ENDPOINT", chosen.absoluteString, 1)
        Log.app.info("HFEndpointResolver probed: official=\(formatSpeed(offSpeed), privacy: .public) mirror=\(formatSpeed(mirSpeed), privacy: .public) → \(source, privacy: .public)")
        return chosen
    }

    private static func formatSpeed(_ kbps: Double?) -> String {
        guard let v = kbps else { return "fail" }
        return String(format: "%.0fKB/s", v)
    }

    /// Single-endpoint probe. Returns KB/s, or nil on any failure/timeout.
    /// Logs the underlying reason on failure so diagnosis doesn't require
    /// reproducing the network condition.
    private static func probe(base: URL) async -> Double? {
        guard let url = URL(string: base.absoluteString + "/" + probePath) else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=0-\(probeBytes - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = probeTimeoutSec
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeoutSec
        config.timeoutIntervalForResource = probeTimeoutSec
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let start = Date()
        do {
            let (data, response) = try await session.data(for: req)
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed > 0 else { return nil }
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                Log.app.info("HFEndpointResolver probe \(base.host ?? "?", privacy: .public): http \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                return nil
            }
            let bytes = Double(data.count)
            return (bytes / 1024.0) / elapsed
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            Log.app.info("HFEndpointResolver probe \(base.host ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public) after \(String(format: "%.1f", elapsed), privacy: .public)s")
            return nil
        }
    }

    private static func persist(chosen: URL, source: String) {
        let ud = UserDefaults.standard
        ud.set(chosen.absoluteString, forKey: Keys.cachedURL)
        ud.set(Date(), forKey: Keys.cachedAt)
        ud.set(source, forKey: Keys.cachedSource)
    }
}
