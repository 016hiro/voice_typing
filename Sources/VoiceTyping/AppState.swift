import Foundation
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    enum CapsuleStatus: Equatable {
        case idle
        case recording
        case transcribing
        case refining
        case info(String)
    }

    /// v0.5.2: user-facing "when do I want text to appear?" choice. Three
    /// mutually-exclusive options backed by the existing
    /// `streamingEnabled` / `liveStreamingEnabled` UserDefaults keys (no new
    /// key, no migration). `live` takes precedence over `postrecord` — see
    /// `transcriptionTiming`'s getter. Replaces the pre-v0.5.2 dual-toggle UI
    /// that users found confusing ("two Streamings?").
    enum TranscriptionTiming: String, CaseIterable, Identifiable {
        case oneshot
        case postrecord
        case live

        var id: String { rawValue }
    }

    @Published var status: CapsuleStatus = .idle
    @Published var capsuleVisible: Bool = false

    /// v0.5.1: optional text the capsule shows in place of the status-derived
    /// label (`statusTextForCapsule`). Used by AppDelegate's recording-duration
    /// timer to flash "Xs left" near the cap without changing `status` (which
    /// would break the `status == .recording` gate that `stopRecording` checks).
    /// Nil ⇒ capsule falls back to the status-derived label.
    @Published var capsuleOverlayText: String?

    /// v0.5.3: true while a hands-free session is active (between Fn↑ that
    /// triggered hands-free and stopRecording). Drives the capsule's
    /// distinct visual state — colour shift + "HF" badge + early "tap Fn to
    /// cancel" overlay — so the user can tell which mode they're in. Not
    /// persisted; transient runtime flag managed by AppDelegate's hands-free
    /// state machine.
    @Published var handsFreeActive: Bool = false

    @Published var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    @Published var llmConfig: LLMConfig {
        didSet { LLMConfigStore.save(llmConfig) }
    }

    /// v0.3: replaces `LLMConfig.enabled` as the master on/off + intensity knob.
    /// `.off` bypasses the refiner entirely. v0.4.4 flipped the default to `.off`
    /// so new installs don't incur LLM latency until the user opts in.
    @Published var refineMode: RefineMode {
        didSet { UserDefaults.standard.set(refineMode.rawValue, forKey: "refineMode") }
    }

    /// v0.7.0 #R7: how refined text reaches the focused app. Three mutually-
    /// exclusive modes — see `RefineDelivery` for semantics. Replaces the
    /// pre-v0.7.0 `rawFirstEnabled` boolean (migration in `init` reads the
    /// old key and maps `true → .rawFirst`, `false/missing → .streaming`).
    @Published var refineDelivery: RefineDelivery {
        didSet { UserDefaults.standard.set(refineDelivery.rawValue, forKey: "refineDelivery") }
    }

    /// v0.4.2 experimental: route transcription through VAD-segmented streaming
    /// so the capsule reveals text progressively and long (>60s) recordings work.
    /// Qwen backends only — Whisper has no streaming path. Off by default.
    ///
    /// v0.5.2: surfaced via `transcriptionTiming` as the "post-record" choice;
    /// the UserDefaults key is kept for backward compat and remains the
    /// backing store.
    @Published var streamingEnabled: Bool {
        didSet { UserDefaults.standard.set(streamingEnabled, forKey: "streamingEnabled") }
    }

    /// v0.5.0 experimental: true live-mic transcription. ASR runs while you
    /// hold Fn (per VAD-detected segment) instead of waiting until release;
    /// perceived post-release latency drops from `ASR(total_audio)` to
    /// `ASR(last_segment) + drain`.
    ///
    /// v0.5.2: now surfaced via `transcriptionTiming` (the "live" choice).
    /// The UserDefaults key is still the backing store so
    /// `defaults write com.voicetyping.app liveStreamingEnabled -bool true`
    /// still works as an alternate entry point.
    /// Qwen backends only; takes precedence over `streamingEnabled` when on.
    @Published var liveStreamingEnabled: Bool {
        didSet { UserDefaults.standard.set(liveStreamingEnabled, forKey: "liveStreamingEnabled") }
    }

    /// v0.4.4: unlocks the `Log.dev(...)` call sites (setup / bias / profile
    /// diagnostics) and shows them in `log stream` without `--level info`.
    /// Off by default — keep user-facing log output quiet unless someone is
    /// actively debugging a pipeline issue.
    @Published var developerMode: Bool {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: "developerMode")
            Log.devMode = developerMode
        }
    }

    /// v0.6.3: when true, refinement uses on-device MLX (LocalMLXRefiner)
    /// instead of the cloud API (CloudLLMRefiner). Independent of `refineMode`
    /// — `.off` still bypasses both. Hidden in Settings UI on RAMTier `.low`
    /// (< 16 GB) since the 2.6 GB weights would push such Macs into hard swap.
    /// Default off so existing users see no behavior change at upgrade time.
    @Published var localRefinerEnabled: Bool {
        didSet { UserDefaults.standard.set(localRefinerEnabled, forKey: "localRefinerEnabled") }
    }

    /// v0.5.1 Debug Data Capture — when on, every recording session's audio +
    /// per-segment text + inject result land under
    /// `~/Library/Application Support/VoiceTyping/debug-captures/<session>/`.
    /// Off by default. See `todo/v0.5.1.md` "Debug 数据捕获 toggle" for the
    /// schema decisions and `DebugCapture` namespace for the file layout.
    @Published var debugCaptureEnabled: Bool {
        didSet { UserDefaults.standard.set(debugCaptureEnabled, forKey: "debugCaptureEnabled") }
    }

    /// v0.5.1: number of days to keep captured sessions before the launch-time
    /// purge sweeps them. 0 means "never auto-purge" (user manages manually).
    /// Allowed values are listed in `DebugCapture.retentionDayOptions`.
    @Published var debugCaptureRetentionDays: Int {
        didSet { UserDefaults.standard.set(debugCaptureRetentionDays, forKey: "debugCaptureRetentionDays") }
    }

    /// v0.5.3 hands-free mode. When on, a short Fn tap (< 200 ms) enters a
    /// hands-free recording state: audio capture continues after Fn↑ and the
    /// session auto-stops after 1.5 s of post-speech silence, or 10 s of no
    /// speech at all, or `RecordingPolicy.maxDuration` — whichever first.
    /// Tap Fn again to cancel (discard).
    ///
    /// Off by default for v0.5.3 (dogfood opt-in) — tap Fn was effectively a
    /// no-op before, so changing the gesture's meaning needs validation
    /// before the default flips. Qwen backend only; the Settings toggle is
    /// disabled when a Whisper backend is active.
    @Published var handsFreeEnabled: Bool {
        didSet { UserDefaults.standard.set(handsFreeEnabled, forKey: "handsFreeEnabled") }
    }

    /// v0.3 custom vocabulary. Persisted via `CustomDictionary` to a JSON file.
    let dictionary = CustomDictionary()

    /// Bumped whenever dictionary entries change; used by SwiftUI views to re-render.
    @Published var dictionaryTick: Int = 0

    /// v0.3.1 per-app context profiles. Mutate via the `upsertProfile` /
    /// `removeProfile` / `replaceProfiles` methods below so persistence and
    /// `profilesTick` stay in sync (same pattern as the dictionary).
    let profiles = ContextProfileStore()

    /// Bumped whenever profile entries change; drives SwiftUI refresh in Settings.
    @Published var profilesTick: Int = 0

    @Published var asrBackend: ASRBackend {
        didSet { UserDefaults.standard.set(asrBackend.rawValue, forKey: "asrBackend") }
    }

    @Published var recognizerState: RecognizerState = .unloaded
    @Published var accessibilityGranted: Bool = false
    @Published var microphoneGranted: Bool = false

    /// v0.7.0 #R8: count of characters the streaming refine has yielded so
    /// far. Bumped from `injectStreamingRefine`'s stream wrapper as each
    /// chunk arrives; reset to 0 when the pipeline returns to `.idle`.
    /// Capsule reads this to show "Refining (N chars)" while streaming —
    /// gives the user a visible "still working" signal even when the LLM
    /// pauses for a few hundred ms between tokens.
    @Published var streamingChars: Int = 0

    /// Bumped when model listings (downloaded/deleted/downloading) change, so menus can refresh.
    @Published var modelInventoryTick: Int = 0

    /// Last app (by bundle ID) other than VoiceTyping that became active in the
    /// foreground. Maintained by `AppDelegate` via NSWorkspace activation
    /// notifications — consumed by the Profiles settings tab so
    /// "Add frontmost app" targets the app the user was dictating into before
    /// they opened Settings (which would otherwise make VoiceTyping frontmost).
    @Published var lastNonSelfFrontmostBundleID: String?

    init() {
        let ud = UserDefaults.standard

        let raw = ud.string(forKey: "language") ?? Language.default.rawValue
        self.language = Language(rawValue: raw) ?? .default

        let loadedConfig = LLMConfigStore.load()
        self.llmConfig = loadedConfig

        // Migrate v0.2 → v0.3: if no refineMode key, derive from `LLMConfig.enabled`.
        // enabled=true → conservative (v0.2 behavior), enabled=false → off.
        if let modeRaw = ud.string(forKey: "refineMode"),
           let mode = RefineMode(rawValue: modeRaw) {
            self.refineMode = mode
        } else {
            self.refineMode = loadedConfig.enabled ? .conservative : .off
        }

        // v0.7.0 #R7 migration: prefer the new `refineDelivery` key; fall back
        // to the legacy `rawFirstEnabled` boolean (true → .rawFirst). Fresh
        // installs land on `.streaming` — the v0.7.0 default UX.
        if let deliveryRaw = ud.string(forKey: "refineDelivery"),
           let delivery = RefineDelivery(rawValue: deliveryRaw) {
            self.refineDelivery = delivery
        } else if ud.object(forKey: "rawFirstEnabled") as? Bool == true {
            self.refineDelivery = .rawFirst
        } else {
            self.refineDelivery = .streaming
        }
        self.streamingEnabled = ud.object(forKey: "streamingEnabled") as? Bool ?? false
        self.liveStreamingEnabled = ud.object(forKey: "liveStreamingEnabled") as? Bool ?? false

        let dev = ud.bool(forKey: "developerMode")
        self.developerMode = dev
        Log.devMode = dev

        self.localRefinerEnabled = ud.bool(forKey: "localRefinerEnabled")

        self.debugCaptureEnabled = ud.bool(forKey: "debugCaptureEnabled")
        // Default retention 7 days. `object(forKey:)` returns nil for never-set
        // (treat as default), but 0 must round-trip as "never" — so check
        // membership rather than truthiness.
        let storedRetention = ud.object(forKey: "debugCaptureRetentionDays") as? Int
        self.debugCaptureRetentionDays = storedRetention ?? 7

        self.handsFreeEnabled = ud.bool(forKey: "handsFreeEnabled")

        let backendRaw = ud.string(forKey: "asrBackend")
        let persisted = backendRaw.flatMap { ASRBackend(rawValue: $0) } ?? .default
        // Don't autoload a Qwen backend if MLX isn't bundled; downgrade to default
        // (which is itself MLX-aware). User can still manually pick Qwen from the menu;
        // they'll then see the "MLX shaders missing" error in Manage Models.
        if persisted.isQwen && !MLXSupport.isAvailable {
            self.asrBackend = .default
        } else {
            self.asrBackend = persisted
        }
    }

    // MARK: - Dictionary mutations (trigger UI refresh + persistence)

    func upsertDictionaryEntry(_ entry: DictionaryEntry) -> Bool {
        let ok = dictionary.upsert(entry)
        if ok { dictionaryTick &+= 1 }
        return ok
    }

    func removeDictionaryEntry(id: UUID) {
        dictionary.remove(id: id)
        dictionaryTick &+= 1
    }

    func replaceDictionary(_ entries: [DictionaryEntry]) {
        dictionary.replaceAll(entries)
        dictionaryTick &+= 1
    }

    func noteDictionaryMatches(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        dictionary.updateLastMatched(ids: ids)
        // Intentionally don't bump dictionaryTick — UI doesn't need to re-render
        // when only `lastMatchedAt` changes (not user-visible).
    }

    // MARK: - Profile mutations

    @discardableResult
    func upsertProfile(_ profile: ContextProfile) -> Bool {
        let ok = profiles.upsert(profile)
        if ok { profilesTick &+= 1 }
        return ok
    }

    func removeProfile(id: UUID) {
        profiles.remove(id: id)
        profilesTick &+= 1
    }

    func replaceProfiles(_ new: [ContextProfile]) {
        profiles.replaceAll(new)
        profilesTick &+= 1
    }

    /// Text shown in the capsule — v0.4.4 onwards only the pipeline phase is
    /// surfaced (transcript text was removed after it looked cramped/flashy).
    /// v0.7.0 adds a `(N chars)` suffix during streaming refine so the user
    /// sees forward progress between LLM tokens.
    var statusTextForCapsule: String {
        switch status {
        case .idle, .recording: return "Listening"
        case .transcribing:     return "Transcribing"
        case .refining:
            return streamingChars > 0
                ? "Refining (\(streamingChars) chars)"
                : "Refining"
        case .info(let msg):    return msg
        }
    }

    /// v0.5.2: single-choice view over the two streaming bool flags. Reads pick
    /// `live` first (matching runtime precedence), then `postrecord`, else
    /// `oneshot`. Writes zero the other bool so switching away from a mode
    /// leaves no stale flag behind (user flipping live → postrecord won't
    /// silently keep live running).
    var transcriptionTiming: TranscriptionTiming {
        get {
            if liveStreamingEnabled { return .live }
            if streamingEnabled { return .postrecord }
            return .oneshot
        }
        set {
            switch newValue {
            case .oneshot:
                streamingEnabled = false
                liveStreamingEnabled = false
            case .postrecord:
                streamingEnabled = true
                liveStreamingEnabled = false
            case .live:
                streamingEnabled = false
                liveStreamingEnabled = true
            }
        }
    }
}
