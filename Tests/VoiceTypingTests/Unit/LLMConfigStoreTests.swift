import XCTest
@testable import VoiceTyping

/// Drives `LLMConfigStore.loadCore` against an isolated UserDefaults suite
/// so the schema migrations don't see (or pollute) the developer's real
/// llmConfig + Keychain. Covers:
///   - v0.3.2 baseURL append migration (pre-existing — guarded against
///     accidental removal during the v0.6.3 refactor)
///   - v0.6.3 timeout floor migration (NEW — bump anything <30s up to the
///     new default; pre-fix every install was stuck at 8s and timed out
///     on every cloud refine, see commit 1621078)
final class LLMConfigStoreTests: XCTestCase {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "LLMConfigStoreTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    /// Writes a raw JSON-shaped config dict directly into UserDefaults under
    /// the same key the production code reads (`llmConfig`). Bypasses
    /// `JSONEncoder` so we can simulate legacy on-disk shapes that the
    /// current `LLMConfig` struct wouldn't naturally produce.
    private func writeRawConfig(_ raw: [String: Any], to ud: UserDefaults) throws {
        let data = try JSONSerialization.data(withJSONObject: raw)
        ud.set(data, forKey: "llmConfig")
    }

    // MARK: - v0.6.3 timeout floor migration

    func testLoad_LegacyTimeout8_BumpedToNewDefault() throws {
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "https://api.openai.com/v1/chat/completions",
            "model": "gpt-4o-mini",
            "timeout": 8     // pre-v0.6.3 default
        ], to: ud)
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.timeout, LLMConfig.default.timeout,
                       "Persisted timeout=8 must be migrated to the new default (60)")
    }

    func testLoad_TimeoutBelowFloor_BumpedToNewDefault() throws {
        // Anything < 30 should clamp; covers users who manually set 15-25s.
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "https://api.openai.com/v1/chat/completions",
            "model": "gpt-4o-mini",
            "timeout": 20
        ], to: ud)
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.timeout, LLMConfig.default.timeout)
    }

    func testLoad_TimeoutExactlyAtFloor_NotChanged() throws {
        // Boundary: 30 is the floor — at it, leave alone.
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "https://api.openai.com/v1/chat/completions",
            "model": "gpt-4o-mini",
            "timeout": 30
        ], to: ud)
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.timeout, 30, "Boundary value must survive untouched")
    }

    func testLoad_TimeoutAboveDefault_NotClamped() throws {
        // Migration is bump-only: don't downward-clamp users who deliberately
        // set a long timeout for a slow self-hosted endpoint.
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "https://api.openai.com/v1/chat/completions",
            "model": "gpt-4o-mini",
            "timeout": 120
        ], to: ud)
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.timeout, 120)
    }

    func testLoad_TimeoutMigration_Idempotent() throws {
        // Running load() twice on the same defaults must yield the same
        // result. Important because AppState may load multiple times during
        // a session (e.g. after Settings save).
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "https://api.openai.com/v1/chat/completions",
            "model": "gpt-4o-mini",
            "timeout": 8
        ], to: ud)
        let cfg1 = LLMConfigStore.loadCore(defaults: ud)
        let cfg2 = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg1.timeout, cfg2.timeout)
        XCTAssertEqual(cfg1.timeout, LLMConfig.default.timeout)
    }

    // MARK: - v0.3.2 baseURL migration (regression — was already in load())

    func testLoad_LegacyBaseURL_AppendsChatCompletions() throws {
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "https://api.openai.com/v1",
            "model": "gpt-4o-mini",
            "timeout": 60
        ], to: ud)
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.baseURL, "https://api.openai.com/v1/chat/completions")
    }

    func testLoad_LegacyBaseURLWithTrailingSlash_AppendsCleanly() throws {
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "https://api.openai.com/v1/",
            "model": "gpt-4o-mini",
            "timeout": 60
        ], to: ud)
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.baseURL, "https://api.openai.com/v1/chat/completions",
                       "Trailing slash must not produce a double slash")
    }

    func testLoad_AlreadyFullURL_NotDoubled() throws {
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "https://openrouter.ai/api/v1/chat/completions",
            "model": "openai/gpt-4o-mini",
            "timeout": 60
        ], to: ud)
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.baseURL, "https://openrouter.ai/api/v1/chat/completions",
                       "Already-complete URL must survive load() unchanged")
    }

    func testLoad_EmptyBaseURL_NotMigrated() throws {
        // Edge: empty baseURL means "user hasn't configured yet". Don't
        // append /chat/completions to "" — leaves a confusing "/chat/completions"
        // URL that would silently be sent to the server.
        let ud = makeIsolatedDefaults()
        try writeRawConfig([
            "enabled": true,
            "baseURL": "",
            "model": "",
            "timeout": 60
        ], to: ud)
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.baseURL, "")
    }

    // MARK: - Defaults fallback

    func testLoad_NoStoredConfig_ReturnsLLMConfigDefault() {
        let ud = makeIsolatedDefaults()
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.timeout, LLMConfig.default.timeout)
        XCTAssertEqual(cfg.baseURL, LLMConfig.default.baseURL)
        XCTAssertEqual(cfg.model, LLMConfig.default.model)
    }

    func testLoad_CorruptStoredConfig_ReturnsLLMConfigDefault() {
        // Garbage bytes (not valid JSON) should fall through to defaults
        // rather than crash. UserDefaults stores arbitrary data so this
        // can happen if a foreign process scribbled into the plist.
        let ud = makeIsolatedDefaults()
        ud.set(Data([0xFF, 0x00, 0x42]), forKey: "llmConfig")
        let cfg = LLMConfigStore.loadCore(defaults: ud)
        XCTAssertEqual(cfg.baseURL, LLMConfig.default.baseURL)
    }
}
