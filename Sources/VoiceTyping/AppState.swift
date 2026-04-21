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

    @Published var status: CapsuleStatus = .idle
    @Published var capsuleVisible: Bool = false

    /// v0.5.1: optional text the capsule shows in place of the status-derived
    /// label (`statusTextForCapsule`). Used by AppDelegate's recording-duration
    /// timer to flash "Xs left" near the cap without changing `status` (which
    /// would break the `status == .recording` gate that `stopRecording` checks).
    /// Nil ⇒ capsule falls back to the status-derived label.
    @Published var capsuleOverlayText: String?

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

    /// v0.3: when true, paste raw ASR output immediately and replace with refined
    /// text in the background once the LLM returns. Trades visual jitter for
    /// dramatically reduced perceived latency. Off by default.
    @Published var rawFirstEnabled: Bool {
        didSet { UserDefaults.standard.set(rawFirstEnabled, forKey: "rawFirstEnabled") }
    }

    /// v0.4.2 experimental: route transcription through VAD-segmented streaming
    /// so the capsule reveals text progressively and long (>60s) recordings work.
    /// Qwen backends only — Whisper has no streaming path. Off by default.
    @Published var streamingEnabled: Bool {
        didSet { UserDefaults.standard.set(streamingEnabled, forKey: "streamingEnabled") }
    }

    /// v0.5.0 experimental: true live-mic transcription. ASR runs while you
    /// hold Fn (per VAD-detected segment) instead of waiting until release;
    /// perceived post-release latency drops from `ASR(total_audio)` to
    /// `ASR(last_segment) + drain`.
    ///
    /// No Settings UI yet — toggle via:
    ///   `defaults write com.voicetyping.app liveStreamingEnabled -bool true`
    /// Will get a UI toggle once dogfood data confirms VAD quality on real
    /// mic noise matches what fixtures showed (the v0.5.0 release plan).
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

        self.rawFirstEnabled = ud.object(forKey: "rawFirstEnabled") as? Bool ?? false
        self.streamingEnabled = ud.object(forKey: "streamingEnabled") as? Bool ?? false
        self.liveStreamingEnabled = ud.object(forKey: "liveStreamingEnabled") as? Bool ?? false

        let dev = ud.bool(forKey: "developerMode")
        self.developerMode = dev
        Log.devMode = dev

        self.debugCaptureEnabled = ud.bool(forKey: "debugCaptureEnabled")
        // Default retention 7 days. `object(forKey:)` returns nil for never-set
        // (treat as default), but 0 must round-trip as "never" — so check
        // membership rather than truthiness.
        let storedRetention = ud.object(forKey: "debugCaptureRetentionDays") as? Int
        self.debugCaptureRetentionDays = storedRetention ?? 7

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
    var statusTextForCapsule: String {
        switch status {
        case .idle, .recording: return "Listening"
        case .transcribing:     return "Transcribing"
        case .refining:         return "Refining"
        case .info(let msg):    return msg
        }
    }
}
