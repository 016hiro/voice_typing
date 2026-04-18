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
    @Published var capsuleText: String = ""
    @Published var capsuleVisible: Bool = false

    @Published var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    @Published var llmConfig: LLMConfig {
        didSet { LLMConfigStore.save(llmConfig) }
    }

    /// v0.3: replaces `LLMConfig.enabled` as the master on/off + intensity knob.
    /// `.off` bypasses the refiner entirely; `.conservative` matches v0.2 behavior.
    @Published var refineMode: RefineMode {
        didSet { UserDefaults.standard.set(refineMode.rawValue, forKey: "refineMode") }
    }

    /// v0.3: when true, paste raw ASR output immediately and replace with refined
    /// text in the background once the LLM returns. Trades visual jitter for
    /// dramatically reduced perceived latency. Off by default.
    @Published var rawFirstEnabled: Bool {
        didSet { UserDefaults.standard.set(rawFirstEnabled, forKey: "rawFirstEnabled") }
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

    var labelTextForCapsule: String {
        switch status {
        case .idle, .recording:
            return capsuleText.isEmpty ? "Listening" : capsuleText
        case .transcribing:
            return capsuleText.isEmpty ? "Transcribing" : capsuleText
        case .refining:
            return "Refining"
        case .info(let msg):
            return msg
        }
    }
}
