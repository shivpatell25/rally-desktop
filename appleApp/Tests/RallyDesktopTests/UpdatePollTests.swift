import XCTest
@testable import RallyCore

/// Update poll states + prerelease-aware compare (Android RallyUpdateManager).
final class UpdatePollTests: XCTestCase {
    private func checker() -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return UpdateChecker(session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubURLProtocol.result = nil
        super.tearDown()
    }

    func testCompareChannels() {
        let c = UpdateChecker()
        XCTAssertGreaterThan(c.compareVersions("v1.2.0", "1.1.0"), 0)
        XCTAssertEqual(c.compareVersions("1.0.0", "1.0.0"), 0)
        XCTAssertGreaterThan(c.compareVersions("1.0.0", "1.0.0-beta1"), 0)
        XCTAssertGreaterThan(c.compareVersions("1.0.0-rc2", "1.0.0-beta10"), 0)
        XCTAssertGreaterThan(c.compareVersions("1.0.0-beta2", "1.0.0-beta1"), 0)
        XCTAssertLessThan(c.compareVersions("1.0.0", "1.0.1"), 0)
        XCTAssertEqual(c.compareVersions("1.0", "1.0.0"), 0)
    }

    func testPollFindsMacAsset() async {
        StubURLProtocol.result = { _ in (200, [:], """
            {"tag_name": "v0.5.0", "name": "Rally 0.5.0", "body": "Notes",
             "html_url": "https://github.com/shivpatell25/rally-desktop/releases/tag/v0.5.0",
             "assets": [{"name": "Rally-0.5.0-macOS.dmg",
                         "browser_download_url": "https://github.com/shivpatell25/rally-desktop/releases/download/v0.5.0/Rally-0.5.0-macOS.dmg",
                         "size": 42000000}]}
            """.data(using: .utf8)) }
        let poll = await checker().poll(currentVersion: "0.4.0")
        guard case .available(let rel) = poll else { return XCTFail("expected available, got \(poll)") }
        XCTAssertEqual(rel.tag, "v0.5.0")
        XCTAssertTrue(rel.assetUrl.hasSuffix(".dmg"))
    }

    func testPollRejectsForeignAsset() async {
        StubURLProtocol.result = { _ in (200, [:], """
            {"tag_name": "v0.5.0", "assets": [
              {"name": "app.apk", "browser_download_url": "https://github.com/shivpatell25/rally-desktop/releases/download/v0.5.0/app.apk", "size": 1},
              {"name": "evil.dmg", "browser_download_url": "https://evil.example/evil.dmg", "size": 1}]}
            """.data(using: .utf8)) }
        let poll = await checker().poll(currentVersion: "0.4.0")
        // APK is not macOS; evil.dmg is outside our releases — both refused.
        guard case .failed = poll else { return XCTFail("expected failed, got \(poll)") }
    }

    func testPollUpToDate() async {
        StubURLProtocol.result = { _ in (200, [:], """
            {"tag_name": "v0.4.0", "assets": []}
            """.data(using: .utf8)) }
        let poll = await checker().poll(currentVersion: "0.4.0")
        XCTAssertEqual(poll, .upToDate)
    }

    func testPollFailureSurfaced() async {
        StubURLProtocol.result = nil
        StubURLProtocol.body = nil
        let poll = await checker().poll(currentVersion: "0.4.0")
        guard case .failed(let message) = poll else { return XCTFail("expected failed, got \(poll)") }
        XCTAssertFalse(message.isEmpty)
    }
}
