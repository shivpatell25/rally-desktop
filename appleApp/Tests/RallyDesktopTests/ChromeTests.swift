import XCTest
@testable import RallyCore

/// League curation, scoped clear, portable backup (Android SportsSettings/support).
final class ChromeTests: XCTestCase {
    @MainActor
    private func store(_ suite: String) -> (SettingsStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsStore(defaults: defaults), defaults)
    }

    @MainActor
    func testLeagueToggleSemantics() {
        let (s, d) = store("RallyChrome1")
        XCTAssertTrue(s.isLeagueEnabled("NFL")) // empty means all
        s.toggleLeague("NFL")
        XCTAssertFalse(s.isLeagueEnabled("NFL"))
        XCTAssertTrue(s.isLeagueEnabled("NBA"))
        s.toggleLeague("NFL")
        XCTAssertTrue(s.isLeagueEnabled("NFL"))
        s.toggleFavoriteSport("NBA")
        XCTAssertTrue(s.favoriteSports.contains("NBA"))
        d.removePersistentDomain(forName: "RallyChrome1")
    }

    @MainActor
    func testSportReorder() {
        let (s, d) = store("RallyChrome2")
        s.sportsOrder = ["NFL", "NBA", "MLB"]
        s.moveSportUp("NBA")
        XCTAssertEqual(s.sportsOrder, ["NBA", "NFL", "MLB"])
        s.moveSportUp("NBA") // top stays
        XCTAssertEqual(s.sportsOrder.first, "NBA")
        s.moveSportDown("MLB") // bottom stays
        XCTAssertEqual(s.sportsOrder.last, "MLB")
        s.moveSportDown("NFL")
        XCTAssertEqual(s.sportsOrder, ["NBA", "MLB", "NFL"])
        d.removePersistentDomain(forName: "RallyChrome2")
    }

    @MainActor
    func testClearIsScoped() {
        let (s, d) = store("RallyChrome3")
        s.portalUrl = "example.to:8080/c"
        s.sportsOrder = ["NBA", "NFL"]
        _ = s.toggleFavoriteTeam(FavoriteTeam(id: "1", league: "NFL", name: "Falcons", abbreviation: "ATL"))
        s.liveGameAlertsEnabled = false
        s.clearCredentials()
        XCTAssertTrue(s.portalUrl.isEmpty)
        // Personalization survives.
        XCTAssertEqual(s.sportsOrder.first, "NBA")
        XCTAssertEqual(s.favoriteTeamProfiles.count, 1)
        XCTAssertFalse(s.liveGameAlertsEnabled)
        d.removePersistentDomain(forName: "RallyChrome3")
    }

    @MainActor
    func testBackupRoundTripExcludesSecrets() {
        let (s, d) = store("RallyChrome4")
        s.portalUrl = "example.to:8080/c"
        s.xtreamPassword = "secret"
        s.sportsOrder = ["NBA", "NFL"]
        _ = s.toggleFavoriteTeam(FavoriteTeam(id: "1", league: "NFL", name: "Falcons", abbreviation: "ATL"))
        guard let data = s.exportPersonalization() else { return XCTFail("no export") }
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("example.to"))
        let (s2, d2) = store("RallyChrome5")
        XCTAssertTrue(s2.importPersonalization(data))
        XCTAssertEqual(s2.sportsOrder.first, "NBA")
        XCTAssertEqual(s2.favoriteTeamProfiles.count, 1)
        XCTAssertTrue(s2.portalUrl.isEmpty)
        XCTAssertFalse(s2.importPersonalization(Data("garbage".utf8)))
        d.removePersistentDomain(forName: "RallyChrome4")
        d2.removePersistentDomain(forName: "RallyChrome5")
    }
}
