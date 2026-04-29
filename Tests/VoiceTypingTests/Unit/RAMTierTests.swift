import XCTest
@testable import VoiceTyping

final class RAMTierTests: XCTestCase {

    // MARK: - Boundaries (forBytes pure logic)

    func testForBytes_8GB_IsLow() {
        XCTAssertEqual(RAMTier.forBytes(8 * gib), .low)
    }

    func testForBytes_15GB_IsLow() {
        XCTAssertEqual(RAMTier.forBytes(15 * gib), .low)
    }

    func testForBytes_16GB_IsMid_LowerBoundInclusive() {
        XCTAssertEqual(RAMTier.forBytes(16 * gib), .mid)
    }

    func testForBytes_23GB_IsMid_UpperBoundExclusive() {
        XCTAssertEqual(RAMTier.forBytes(23 * gib), .mid)
    }

    func testForBytes_24GB_IsHigh_LowerBoundInclusive() {
        XCTAssertEqual(RAMTier.forBytes(24 * gib), .high)
    }

    func testForBytes_64GB_IsHigh() {
        XCTAssertEqual(RAMTier.forBytes(64 * gib), .high)
    }

    func testForBytes_192GB_IsHigh() {
        // M3 Ultra Mac Studio max config — verify we don't overflow / crash
        XCTAssertEqual(RAMTier.forBytes(192 * gib), .high)
    }

    func testForBytes_Zero_IsLow_FailureFallback() {
        // sysctl failure path uses 0 → we want to deny RAM-hungry features
        // when we can't confirm the actual amount.
        XCTAssertEqual(RAMTier.forBytes(0), .low)
    }

    // MARK: - Live sysctl

    func testCurrent_ReturnsValidTier() {
        // We can't assert WHICH tier (depends on dev/CI hardware), only that
        // sysctl ran and returned one of the three valid values. On any real
        // Mac, sysctl never fails so this exercises the success path.
        let tier = RAMTier.current
        XCTAssertTrue([.low, .mid, .high].contains(tier))
    }

    // MARK: - Helpers

    private let gib: UInt64 = 1024 * 1024 * 1024
}
