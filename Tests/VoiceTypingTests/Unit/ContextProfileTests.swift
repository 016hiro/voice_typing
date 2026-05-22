import XCTest
@testable import VoiceTyping

/// v0.8.0 #B5 (ADR-0005): per-app independent hotwords. Each profile carries
/// its own private `entries` plus an `includeGlobal` toggle; the effective
/// hotword set is `(includeGlobal ? global : []) + entries`. Every pipeline
/// consumer (ASR bias / refine glossary / #S1 skip-gate guard) routes through
/// `effectiveEntries(global:)`, so these tests pin that helper plus the
/// Codable path that has to ignore the dropped `systemPromptSnippet` (v0.7.x)
/// and `dictionaryFilter` (pre-release v0.8.0) fields.
final class ContextProfileTests: XCTestCase {

    private let g1 = DictionaryEntry(term: "Claude")
    private let g2 = DictionaryEntry(term: "Qwen")
    private var global: [DictionaryEntry] { [g1, g2] }

    private let priv1 = DictionaryEntry(term: "张三")
    private let priv2 = DictionaryEntry(term: "黄老板")

    // MARK: - effectiveEntries semantics

    func testEffective_GlobalOnly_WhenNoPrivateAndIncludeGlobal() {
        let p = ContextProfile(name: "Cursor", bundleID: "com.cursor",
                               entries: [], includeGlobal: true)
        XCTAssertEqual(p.effectiveEntries(global: global).map(\.id),
                       global.map(\.id))
    }

    func testEffective_GlobalUnionPrivate() {
        let p = ContextProfile(name: "Cursor", bundleID: "com.cursor",
                               entries: [priv1, priv2], includeGlobal: true)
        let got = p.effectiveEntries(global: global).map(\.id)
        XCTAssertEqual(got, [g1.id, g2.id, priv1.id, priv2.id],
                       "Effective = global first, then private additions")
    }

    func testEffective_PrivateOnly_WhenGlobalOff() {
        let p = ContextProfile(name: "WeChat", bundleID: "com.tencent.xinWeChat",
                               entries: [priv1, priv2], includeGlobal: false)
        XCTAssertEqual(p.effectiveEntries(global: global).map(\.id),
                       [priv1.id, priv2.id],
                       "includeGlobal=false drops the global baseline entirely")
    }

    func testEffective_Empty_WhenGlobalOffAndNoPrivate() {
        let p = ContextProfile(name: "iMessage", bundleID: "com.apple.MobileSMS",
                               entries: [], includeGlobal: false)
        XCTAssertTrue(p.effectiveEntries(global: global).isEmpty,
                      "global off + no private = clean dictation, zero hotwords")
    }

    func testDefaults_MatchUnconfiguredApp() {
        // A bare profile (just name + bundle) must behave like an app with no
        // profile: global only.
        let p = ContextProfile(name: "X", bundleID: "com.x")
        XCTAssertTrue(p.includeGlobal)
        XCTAssertTrue(p.entries.isEmpty)
        XCTAssertEqual(p.effectiveEntries(global: global).map(\.id), global.map(\.id))
    }

    // MARK: - Codable: forward + legacy

    func testCodable_RoundtripPreservesEntriesAndToggle() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        for include in [true, false] {
            let p = ContextProfile(name: "n", bundleID: "b",
                                   entries: [priv1, priv2], includeGlobal: include)
            let data = try encoder.encode(p)
            let rt = try decoder.decode(ContextProfile.self, from: data)
            XCTAssertEqual(rt.includeGlobal, include)
            XCTAssertEqual(rt.entries.map(\.id), [priv1.id, priv2.id])
        }
    }

    func testCodable_LegacyV073SnippetIgnored() throws {
        // v0.7.x profiles.json: has systemPromptSnippet, no entries/includeGlobal.
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Slack",
          "bundleID": "com.tinyspeck.slackmacgap",
          "systemPromptSnippet": "Prefer casual tone.",
          "enabled": true,
          "createdAt": "2026-05-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(ContextProfile.self, from: json)
        XCTAssertEqual(p.id, id)
        XCTAssertEqual(p.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertTrue(p.includeGlobal, "missing includeGlobal → default true")
        XCTAssertTrue(p.entries.isEmpty, "missing entries → default empty")
    }

    func testCodable_LegacyPreReleaseDictionaryFilterIgnored() throws {
        // pre-release v0.8.0 profiles.json: has dictionaryFilter (whitelist),
        // no entries/includeGlobal. ADR-0005 deliberately does NOT reconstruct
        // the whitelist — the profile resets to "global only".
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Cursor",
          "bundleID": "com.cursor",
          "dictionaryFilter": ["\(UUID().uuidString)", "\(UUID().uuidString)"],
          "enabled": true,
          "createdAt": "2026-05-20T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(ContextProfile.self, from: json)
        XCTAssertTrue(p.includeGlobal)
        XCTAssertTrue(p.entries.isEmpty)
    }

    func testCodable_RoundtripStripsLegacyFields() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Slack",
          "bundleID": "com.test",
          "systemPromptSnippet": "leftover",
          "dictionaryFilter": ["\(UUID().uuidString)"],
          "enabled": true,
          "createdAt": "2026-05-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(ContextProfile.self, from: json)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reEncoded = try encoder.encode(p)
        let asString = String(data: reEncoded, encoding: .utf8) ?? ""
        XCTAssertFalse(asString.contains("systemPromptSnippet"))
        XCTAssertFalse(asString.contains("dictionaryFilter"),
                       "Re-encoded profile must carry neither deprecated field")
    }

    // MARK: - hasContent contract

    func testHasContent_RequiresOnlyBundleID() {
        XCTAssertTrue(ContextProfile(name: "", bundleID: "com.x").hasContent)
        XCTAssertFalse(ContextProfile(name: "labeled", bundleID: "").hasContent)
        XCTAssertFalse(ContextProfile(name: "labeled", bundleID: "   ").hasContent)
    }
}
