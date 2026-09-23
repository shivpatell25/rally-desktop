import XCTest
@testable import RallyCore

/// Save-time validation + first-run gate (Android saveConfiguration/startDest).
final class OnboardingTests: XCTestCase {
    private func validate(provider: IptvProvider = .stalker, portal: String = "", mac: String = "",
                          server: String = "", user: String = "", pass: String = "",
                          addons: [String] = []) -> String? {
        SettingsValidator.validate(provider: provider, portal: portal, mac: mac,
                                    server: server, user: user, pass: pass, addons: addons)
    }

    func testEmptyDraftIsValid() {
        XCTAssertNil(validate())
        XCTAssertNil(validate(provider: .xtream))
    }

    func testBadMacBlocked() {
        XCTAssertNotNil(validate(portal: "http://portal.tv/c", mac: "not-a-mac"))
        XCTAssertNil(validate(portal: "http://portal.tv/c", mac: "00:1A:79:AA:BB:CC"))
        XCTAssertNil(validate(portal: "http://portal.tv/c", mac: ""))
        XCTAssertNil(validate(portal: "", mac: "junk"))
    }

    func testXtreamAllOrNothing() {
        XCTAssertNotNil(validate(provider: .xtream, server: "http://line.tv:8080"))
        XCTAssertNotNil(validate(provider: .xtream, server: "http://line.tv:8080", user: "u"))
        XCTAssertNil(validate(provider: .xtream, server: "http://line.tv:8080", user: "u", pass: "p"))
    }

    func testBadAddonBlocked() {
        XCTAssertNotNil(validate(addons: [":::"]))
        XCTAssertNil(validate(addons: ["https://sports.highfly.to/manifest.json"]))
        XCTAssertNil(validate(addons: ["sports.highfly.to"]))
    }

    @MainActor func testNeedsOnboarding() {
        let defaults = UserDefaults(suiteName: "RallyOnboardingTests")!
        defaults.removePersistentDomain(forName: "RallyOnboardingTests")
        let store = SettingsStore(defaults: defaults)
        // Fresh install: only the bundled default addon -> onboarding required.
        XCTAssertTrue(store.needsOnboarding)
        XCTAssertFalse(store.hasUserCredentials)
        XCTAssertTrue(store.hasCredentials) // legacy flag still sees the default addon
        store.portalUrl = "example.to:8080/c"
        XCTAssertFalse(store.needsOnboarding)
        XCTAssertTrue(store.hasUserCredentials)
        defaults.removePersistentDomain(forName: "RallyOnboardingTests")
    }

    @MainActor func testUserAddonCountsAsCredential() {
        let defaults = UserDefaults(suiteName: "RallyOnboardingTests2")!
        defaults.removePersistentDomain(forName: "RallyOnboardingTests2")
        let store = SettingsStore(defaults: defaults)
        store.stremioAddonUrls = ["https://sports.highfly.to/manifest.json", "https://other.example/manifest.json"]
        XCTAssertTrue(store.hasUserCredentials)
        XCTAssertFalse(store.needsOnboarding)
        defaults.removePersistentDomain(forName: "RallyOnboardingTests2")
    }
}
