import XCTest
@testable import VoiceTyping

@MainActor
final class CustomDictionaryTests: XCTestCase {

    private var tempURL: URL!
    private var dict: CustomDictionary!

    override func setUp() async throws {
        try await super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingDictTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("dictionary.json")
        dict = CustomDictionary(fileURL: tempURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        tempURL = nil
        dict = nil
        try await super.tearDown()
    }

    // MARK: - Basic CRUD

    func testUpsert_addsAndTrimsWhitespace() {
        let added = dict.upsert(DictionaryEntry(term: "  Combine  "))
        XCTAssertTrue(added)
        XCTAssertEqual(dict.entries.count, 1)
        XCTAssertEqual(dict.entries[0].term, "Combine")
    }

    func testUpsert_rejectsEmptyTerm() {
        let ok = dict.upsert(DictionaryEntry(term: "   "))
        XCTAssertFalse(ok)
        XCTAssertTrue(dict.entries.isEmpty)
    }

    func testUpsert_dedupCaseInsensitive() {
        let original = DictionaryEntry(term: "SwiftUI")
        _ = dict.upsert(original)
        // Same dedup key, different id — should replace into original slot.
        let dup = DictionaryEntry(term: "swiftui")
        _ = dict.upsert(dup)
        XCTAssertEqual(dict.entries.count, 1)
        // Preserves original id even though we upserted with a new-id copy.
        XCTAssertEqual(dict.entries[0].id, original.id)
    }

    func testRemove_byId() {
        let e = DictionaryEntry(term: "SwiftUI")
        _ = dict.upsert(e)
        dict.remove(id: e.id)
        XCTAssertTrue(dict.entries.isEmpty)
    }

    func testReplaceAll_respectsSoftCap() {
        let many = (0..<(CustomDictionary.softEntryCap + 10)).map {
            DictionaryEntry(term: "term\($0)")
        }
        dict.replaceAll(many)
        XCTAssertEqual(dict.entries.count, CustomDictionary.softEntryCap)
    }

    // MARK: - Import / export roundtrip

    func testExportImportRoundtrip() throws {
        _ = dict.upsert(DictionaryEntry(term: "SwiftUI"))
        _ = dict.upsert(DictionaryEntry(
            term: "Combine",
            pronunciationHints: ["com bine"]
        ))
        let exported = try dict.exportJSON()

        // Fresh dictionary at a different path.
        let freshURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VTDictTestsImport-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: freshURL) }
        let fresh = CustomDictionary(fileURL: freshURL)
        XCTAssertTrue(fresh.entries.isEmpty)

        try fresh.importJSON(exported)
        XCTAssertEqual(fresh.entries.count, 2)
        XCTAssertEqual(Set(fresh.entries.map(\.term)), ["SwiftUI", "Combine"])
    }

    // MARK: - LRU

    func testUpdateLastMatched_bumpsRecency() {
        let e = DictionaryEntry(
            term: "SwiftUI",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = dict.upsert(e)
        let bumpDate = Date(timeIntervalSince1970: 2_000)
        dict.updateLastMatched(ids: [e.id], at: bumpDate)
        XCTAssertEqual(dict.entries[0].lastMatchedAt, bumpDate)
    }
}
