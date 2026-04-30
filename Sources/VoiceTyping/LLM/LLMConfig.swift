import Foundation

struct LLMConfig: Codable, Equatable {
    /// Legacy v0.1/v0.2 flag; superseded by `AppState.refineMode` in v0.3.
    /// Kept on disk for migration only — newly-saved configs always leave it `true`.
    var enabled: Bool
    var baseURL: String

    /// Not persisted via this struct — stored in `KeychainStore` as of v0.4.0.
    /// Defaults to empty on decode so legacy UserDefaults JSON that still
    /// carries an `apiKey` field can be decoded without injecting the
    /// plaintext into the in-memory struct. `LLMConfigStore` fills this in
    /// from Keychain after decoding.
    var apiKey: String = ""
    var model: String
    var timeout: TimeInterval

    private enum CodingKeys: String, CodingKey {
        // apiKey intentionally excluded — stored in Keychain via KeychainStore.
        case enabled, baseURL, model, timeout
    }

    /// v0.6.3: bumped default timeout 8 → 60 after dogfood hit persistent
    /// timeouts on OpenRouter. The 8 s limit was originally sized for direct
    /// OpenAI gpt-4o-mini (1-3 s typical), but most production paths today
    /// add 2-5 s of routing/queueing (OpenRouter, Together) before any
    /// upstream work, and reasoning models (o1/o3/r1/:thinking/gpt-5) buffer
    /// their full reasoning trace before responding when streaming is off.
    /// `CloudLLMRefiner` now uses streaming so 60 s is generous tailroom,
    /// not a hot path; reasoning-heavy model ids auto-bump to 90 s in
    /// `CloudLLMRefiner.chat`.
    static let `default` = LLMConfig(
        enabled: true,
        baseURL: "https://api.openai.com/v1/chat/completions",
        apiKey: "",
        model: "gpt-4o-mini",
        timeout: 60
    )

    /// True when base URL, API key, and model are all populated — i.e. the config
    /// *could* actually hit an endpoint. Independent of whether refinement is on.
    var hasCredentials: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum LLMConfigStore {
    private static let key = "llmConfig"

    /// Set by `migrateIfNeeded()` when the v0.3.x → v0.4.0 Keychain migration
    /// ran but failed to write the extracted plaintext key into Keychain.
    /// `AppDelegate` checks this after launch and shows a one-shot alert
    /// telling the user to re-enter the key. Plaintext is always cleared
    /// from UserDefaults regardless — we never leave a half-migrated state.
    ///
    /// MainActor-isolated: only written by `migrateIfNeeded()` (called
    /// from `applicationDidFinishLaunching`) and only read from the
    /// post-launch alert flow, both on the main thread.
    @MainActor static private(set) var migrationFailure: String?

    static func load() -> LLMConfig {
        var cfg = loadCore(defaults: .standard)
        // Keychain read kept out of `loadCore` so unit tests can exercise the
        // schema migrations against an isolated UserDefaults without touching
        // the developer's real Keychain.
        cfg.apiKey = KeychainStore.readAPIKey() ?? ""
        return cfg
    }

    /// Decoder + migration pipeline, parameterized over `UserDefaults` so
    /// `LLMConfigStoreTests` can drive each migration branch from an
    /// isolated suite. Production callers should use `load()`.
    static func loadCore(defaults: UserDefaults) -> LLMConfig {
        guard let data = defaults.data(forKey: key),
              var cfg = try? JSONDecoder().decode(LLMConfig.self, from: data) else {
            return LLMConfig.default
        }
        // v0.3.2 schema change: pre-v0.3.2 stored a "base URL" (e.g. `.../v1`)
        // and the refiner appended `/chat/completions`. v0.3.2 stores the full
        // endpoint URL literally (pass-through to URLSession). Upgrade old
        // values once so existing installs keep working without a manual fix.
        let trimmed = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !trimmed.contains("/chat/completions") {
            let separator = trimmed.hasSuffix("/") ? "" : "/"
            cfg.baseURL = trimmed + separator + "chat/completions"
        }
        // v0.6.3 migration: existing installs persist the old 8 s default,
        // which causes near-100% refine timeouts on OpenRouter and any
        // reasoning model. Clamp anything below the new floor up to the new
        // default. Idempotent — repeated load() calls are no-ops once
        // migrated.
        if cfg.timeout < 30 {
            cfg.timeout = LLMConfig.default.timeout
        }
        return cfg
    }

    /// Persists the struct to UserDefaults (minus `apiKey`, which goes to
    /// Keychain). If the Keychain write fails, the struct is still saved;
    /// the in-memory `apiKey` will mismatch the stored one until the next
    /// successful save. Callers should surface errors via the UI if they
    /// need strong consistency — current callers (AppState.didSet) are
    /// fire-and-forget.
    static func save(_ cfg: LLMConfig) {
        // Keychain first: if it fails we still persist the non-sensitive
        // fields so the app remains usable, but the key won't be updated.
        if !cfg.apiKey.isEmpty {
            do {
                try KeychainStore.writeAPIKey(cfg.apiKey)
            } catch {
                Log.llm.error("Failed to write API key to Keychain: \(String(describing: error), privacy: .public)")
            }
        } else {
            // Empty string means "unset" — clear Keychain to match.
            try? KeychainStore.deleteAPIKey()
        }

        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// One-shot v0.3.x → v0.4.0 migration. Looks for a plaintext `apiKey`
    /// field inside the persisted UserDefaults JSON; if present, attempts
    /// to move it into Keychain and rewrites UserDefaults without the
    /// field. On Keychain write failure we still remove the plaintext
    /// (no half-state) and record `migrationFailure` so the UI can prompt.
    ///
    /// Call once during app startup before anything reads `llmConfig`.
    /// Safe to call repeatedly — second+ invocations are no-ops because
    /// the `apiKey` field is no longer present in the stored JSON.
    @MainActor
    static func migrateIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        // Decode as raw dictionary to detect the legacy field without
        // tying ourselves to the `LLMConfig` CodingKeys (which now
        // excludes apiKey — a normal decode would hide the plaintext).
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let legacyKey = raw["apiKey"] as? String else {
            return
        }
        let trimmed = legacyKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip the plaintext field regardless of migration outcome.
        var stripped = raw
        stripped.removeValue(forKey: "apiKey")

        if !trimmed.isEmpty {
            do {
                try KeychainStore.writeAPIKey(trimmed)
                Log.llm.info("Migrated API key from UserDefaults to Keychain")
            } catch {
                migrationFailure = String(describing: error)
                Log.llm.error("API key migration to Keychain failed: \(String(describing: error), privacy: .public); plaintext cleared from UserDefaults")
            }
        }

        if let reencoded = try? JSONSerialization.data(withJSONObject: stripped) {
            UserDefaults.standard.set(reencoded, forKey: key)
        }
    }
}
