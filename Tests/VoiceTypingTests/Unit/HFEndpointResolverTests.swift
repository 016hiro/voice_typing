import XCTest
@testable import VoiceTyping

/// Covers the pure decision logic + cache TTL behavior of HFEndpointResolver.
/// Network-dependent code (the actual probe) isn't covered here — that's a
/// dogfood / E2E concern.
final class HFEndpointResolverTests: XCTestCase {

    // MARK: - Decision table

    func testChoose_BothFail_ReturnsOfficialSoRealDownloadSurfacesError() {
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: nil, mirror: nil)
        XCTAssertEqual(url, HFEndpointResolver.officialURL)
        XCTAssertEqual(src, "official")
    }

    func testChoose_OfficialFailsMirrorOK_ReturnsMirror() {
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: nil, mirror: 200)
        XCTAssertEqual(url, HFEndpointResolver.mirrorURL)
        XCTAssertEqual(src, "mirror")
    }

    func testChoose_OfficialFailsMirrorTooSlow_ReturnsOfficial() {
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: nil, mirror: 50)
        XCTAssertEqual(url, HFEndpointResolver.officialURL)
        XCTAssertEqual(src, "official")
    }

    func testChoose_OfficialOK_MirrorNotBigEnoughWin_ReturnsOfficial() {
        // 200 KB/s vs 800 KB/s = 4x; below 5x threshold → stay on official
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: 200, mirror: 800)
        XCTAssertEqual(url, HFEndpointResolver.officialURL)
        XCTAssertEqual(src, "official")
    }

    func testChoose_OfficialOK_MirrorBigWin_ReturnsMirror() {
        // 200 KB/s vs 1100 KB/s = 5.5x → mirror wins
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: 200, mirror: 1100)
        XCTAssertEqual(url, HFEndpointResolver.mirrorURL)
        XCTAssertEqual(src, "mirror")
    }

    func testChoose_OfficialOK_MirrorExactly5x_ReturnsMirror() {
        // 100 vs 500 = exactly 5x; ≥ multiplier → mirror
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: 100, mirror: 500)
        XCTAssertEqual(url, HFEndpointResolver.mirrorURL)
        XCTAssertEqual(src, "mirror")
    }

    func testChoose_OfficialOK_MirrorJustBelow5x_ReturnsOfficial() {
        // 100 vs 499 = 4.99x; below multiplier → official
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: 100, mirror: 499)
        XCTAssertEqual(url, HFEndpointResolver.officialURL)
        XCTAssertEqual(src, "official")
    }

    func testChoose_OfficialTooSlow_MirrorOK_ReturnsMirror() {
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: 50, mirror: 200)
        XCTAssertEqual(url, HFEndpointResolver.mirrorURL)
        XCTAssertEqual(src, "mirror")
    }

    func testChoose_BothTooSlow_ReturnsOfficial() {
        let (url, src) = HFEndpointResolver.chooseEndpoint(official: 50, mirror: 60)
        XCTAssertEqual(url, HFEndpointResolver.officialURL)
        XCTAssertEqual(src, "official")
    }

    // MARK: - Cache TTL & defaults

    private func makeIsolatedDefaults() -> UserDefaults {
        // Per-test suite name → isolated, then nuke on tearDown.
        let suite = "HFEndpointResolverTests-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        return ud
    }

    func testDecide_NoCache_NoOverride_ReturnsOfficial() {
        let ud = makeIsolatedDefaults()
        let result = HFEndpointResolver.decideCachedOrDefault(defaults: ud, now: Date())
        XCTAssertEqual(result, HFEndpointResolver.officialURL)
    }

    func testDecide_FreshOfficialCache_ReturnsCached() {
        let ud = makeIsolatedDefaults()
        let now = Date()
        ud.set(HFEndpointResolver.officialURL.absoluteString, forKey: "hfEndpointCachedURL")
        ud.set(now.addingTimeInterval(-3600), forKey: "hfEndpointCachedAt")  // 1h old
        ud.set("official", forKey: "hfEndpointCachedSource")

        let result = HFEndpointResolver.decideCachedOrDefault(defaults: ud, now: now)
        XCTAssertEqual(result, HFEndpointResolver.officialURL)
    }

    func testDecide_FreshMirrorCache_ReturnsMirror() {
        let ud = makeIsolatedDefaults()
        let now = Date()
        ud.set(HFEndpointResolver.mirrorURL.absoluteString, forKey: "hfEndpointCachedURL")
        ud.set(now.addingTimeInterval(-3600), forKey: "hfEndpointCachedAt")  // 1h old
        ud.set("mirror", forKey: "hfEndpointCachedSource")

        let result = HFEndpointResolver.decideCachedOrDefault(defaults: ud, now: now)
        XCTAssertEqual(result, HFEndpointResolver.mirrorURL)
    }

    func testDecide_StaleOfficialCacheBeyond24h_FallsBackToOfficialDefault() {
        let ud = makeIsolatedDefaults()
        let now = Date()
        ud.set("https://example.invalid", forKey: "hfEndpointCachedURL")
        ud.set(now.addingTimeInterval(-(25 * 3600)), forKey: "hfEndpointCachedAt")  // 25h old
        ud.set("official", forKey: "hfEndpointCachedSource")

        let result = HFEndpointResolver.decideCachedOrDefault(defaults: ud, now: now)
        XCTAssertEqual(result, HFEndpointResolver.officialURL)
    }

    func testDecide_MirrorCache6hPlusOneSec_FallsBackToOfficial() {
        // Mirror TTL is 6h; just past should drop the cache.
        let ud = makeIsolatedDefaults()
        let now = Date()
        ud.set(HFEndpointResolver.mirrorURL.absoluteString, forKey: "hfEndpointCachedURL")
        ud.set(now.addingTimeInterval(-(6 * 3600 + 1)), forKey: "hfEndpointCachedAt")
        ud.set("mirror", forKey: "hfEndpointCachedSource")

        let result = HFEndpointResolver.decideCachedOrDefault(defaults: ud, now: now)
        XCTAssertEqual(result, HFEndpointResolver.officialURL)
    }

    func testDecide_MirrorCacheJustUnder6h_StillReturnsMirror() {
        let ud = makeIsolatedDefaults()
        let now = Date()
        ud.set(HFEndpointResolver.mirrorURL.absoluteString, forKey: "hfEndpointCachedURL")
        ud.set(now.addingTimeInterval(-(6 * 3600 - 60)), forKey: "hfEndpointCachedAt")
        ud.set("mirror", forKey: "hfEndpointCachedSource")

        let result = HFEndpointResolver.decideCachedOrDefault(defaults: ud, now: now)
        XCTAssertEqual(result, HFEndpointResolver.mirrorURL)
    }

    // MARK: - Hidden override priority

    func testDecide_ManualOverride_BeatsCache() {
        let ud = makeIsolatedDefaults()
        let now = Date()
        // Cache says mirror...
        ud.set(HFEndpointResolver.mirrorURL.absoluteString, forKey: "hfEndpointCachedURL")
        ud.set(now, forKey: "hfEndpointCachedAt")
        ud.set("mirror", forKey: "hfEndpointCachedSource")
        // ...but override says something different.
        ud.set("https://my-internal-mirror.example.com", forKey: "voice_typing.hfEndpoint")

        let result = HFEndpointResolver.decideCachedOrDefault(defaults: ud, now: now)
        XCTAssertEqual(result.absoluteString, "https://my-internal-mirror.example.com")
    }

    func testDecide_EmptyOverride_FallsThrough() {
        let ud = makeIsolatedDefaults()
        let now = Date()
        ud.set("", forKey: "voice_typing.hfEndpoint")  // empty string → skip

        let result = HFEndpointResolver.decideCachedOrDefault(defaults: ud, now: now)
        XCTAssertEqual(result, HFEndpointResolver.officialURL)
    }
}
