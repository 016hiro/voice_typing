import XCTest
@testable import VoiceTyping

/// Covers the v0.5.1 DebugCapture launch-time purge logic. The `root:` overload
/// accepts a temp directory so tests don't touch the user's real Application
/// Support folder.
final class DebugCapturePurgeTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingTests-DebugCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempRoot, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Purge by age

    func testPurgeByAge_RemovesOldSessions_KeepsRecent() throws {
        let now = Date()
        let oldSession = try seedSession(name: "2026-04-10_12-00-00_aaaa", mtime: now.addingTimeInterval(-10 * 86_400), bytes: 1024)
        let recentSession = try seedSession(name: "2026-04-19_12-00-00_bbbb", mtime: now.addingTimeInterval(-2 * 86_400), bytes: 1024)

        let removed = DebugCapture.purgeOlderThan(days: 7, now: now, root: tempRoot)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSession.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentSession.path))
    }

    func testPurgeByAge_ZeroDays_NoOp() throws {
        let now = Date()
        let session = try seedSession(name: "2026-04-10_12-00-00_aaaa", mtime: now.addingTimeInterval(-100 * 86_400), bytes: 1024)

        let removed = DebugCapture.purgeOlderThan(days: 0, now: now, root: tempRoot)

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path),
                      "Days=0 means never purge, even century-old sessions should survive")
    }

    func testPurgeByAge_AllRecent_NoOp() throws {
        let now = Date()
        let s1 = try seedSession(name: "session_a", mtime: now.addingTimeInterval(-1 * 86_400), bytes: 1024)
        let s2 = try seedSession(name: "session_b", mtime: now.addingTimeInterval(-3 * 86_400), bytes: 1024)

        let removed = DebugCapture.purgeOlderThan(days: 7, now: now, root: tempRoot)

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s2.path))
    }

    // MARK: - Purge by capacity

    func testPurgeByCapacity_NoOp_WhenUnderCap() throws {
        // 100 KB sessions, well under the 5 GB cap
        let s1 = try seedSession(name: "small_a", mtime: Date(), bytes: 100_000)
        let s2 = try seedSession(name: "small_b", mtime: Date(), bytes: 100_000)

        let removed = DebugCapture.purgeIfOverCap(root: tempRoot)

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s2.path))
    }

    func testPurgeByCapacity_RemovesOldestUntilUnderFloor_LargeStub() throws {
        // To exercise the cap path without writing GBs, we override file sizes
        // by writing fixed-content stubs and asserting via the public API.
        // Three "huge" stubs at exactly the cap threshold won't trigger
        // (purgeIfOverCap requires bytes > cap), so seed slightly over.
        //
        // We use three 2 GB stubs (total 6 GB); after purge, oldest dropped
        // → 4 GB total → still > 4 GB floor → next oldest dropped → 2 GB →
        // under floor, stop. So expect 2 removed.
        //
        // Writing 6 GB to disk is slow + risks filling the test machine's
        // disk. Skip this test unless explicitly requested. The over-cap
        // logic is otherwise covered by inspection.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VT_DEBUG_CAPTURE_LARGE_TEST"] == "1",
                           "Large-file purge test skipped — set VT_DEBUG_CAPTURE_LARGE_TEST=1 to run (writes 6 GB).")

        let now = Date()
        let oldest = try seedSession(name: "huge_old", mtime: now.addingTimeInterval(-3 * 86_400), bytes: 2 * 1024 * 1024 * 1024)
        let mid    = try seedSession(name: "huge_mid", mtime: now.addingTimeInterval(-2 * 86_400), bytes: 2 * 1024 * 1024 * 1024)
        let recent = try seedSession(name: "huge_new", mtime: now.addingTimeInterval(-1 * 86_400), bytes: 2 * 1024 * 1024 * 1024)

        let removed = DebugCapture.purgeIfOverCap(root: tempRoot)

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mid.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    // MARK: - Helpers

    /// Creates a fake session subdirectory with a file of `bytes` size and the
    /// given mtime (applied to the directory itself).
    @discardableResult
    private func seedSession(name: String, mtime: Date, bytes: Int) throws -> URL {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("audio.wav")
        let data = Data(repeating: 0, count: bytes)
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: dir.path)
        return dir
    }

    @discardableResult
    private func seedSession(name: String, mtime: Date, bytes: Int64) throws -> URL {
        return try seedSession(name: name, mtime: mtime, bytes: Int(bytes))
    }
}
