import XCTest
@testable import RallyCore

final class RallyDesktopTests: XCTestCase {
    func testQualityParserEvidenceBased() {
        XCTAssertEqual(parseQualityFromChannelName("ESPN 4K HDR").resolution, "4K")
        XCTAssertTrue(parseQualityFromChannelName("ESPN 4K HDR").isHdr)
        XCTAssertEqual(parseQualityFromChannelName("Sky Sports 1080p 60fps").resolution, "1080p")
        XCTAssertTrue(parseQualityFromChannelName("Sky Sports 1080p 60fps").is60Fps)
        XCTAssertEqual(parseQualityFromChannelName("Bein 720p").resolution, "720p")
        // No token -> no claim. Never guesses 4K/HDR.
        let plain = parseQualityFromChannelName("Random Channel 12")
        XCTAssertNil(plain.resolution)
        XCTAssertFalse(plain.isHdr)
        XCTAssertFalse(plain.is4K)
    }

    func testQualityRankOrdering() {
        let k4k = StreamQualityInfo(resolution: "4K", is4K: true)
        let fhd = StreamQualityInfo(resolution: "1080p")
        let hd = StreamQualityInfo(resolution: "720p")
        XCTAssertGreaterThan(StreamSelector.qualityRank(k4k), StreamSelector.qualityRank(fhd))
        XCTAssertGreaterThan(StreamSelector.qualityRank(fhd), StreamSelector.qualityRank(hd))
        XCTAssertGreaterThan(StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p", isHdr: true)),
                              StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p")))
    }

    func testTextMatchesEvent() {
        let home = Team(id: "1", name: "Dallas Cowboys", abbreviation: "DAL")
        let away = Team(id: "2", name: "Philadelphia Eagles", abbreviation: "PHI")
        let event = SportEvent(id: "e1", name: "DAL @ PHI", homeTeam: home, awayTeam: away,
                               startTime: Date(), status: .notStarted, sport: "football", league: "NFL")
        XCTAssertTrue(StreamSelector.textMatchesEvent("Dallas Cowboys vs Philadelphia Eagles 1080p", event: event))
        XCTAssertTrue(StreamSelector.textMatchesEvent("DAL vs PHI", event: event))
        XCTAssertFalse(StreamSelector.textMatchesEvent("Lakers vs Celtics", event: event))
        XCTAssertFalse(StreamSelector.textMatchesEvent("", event: event))
    }

    func testCompareVersions() {
        let c = UpdateChecker()
        XCTAssertGreaterThan(c.compareVersions("v1.2.0", "1.1.0"), 0)
        XCTAssertEqual(c.compareVersions("1.0.0", "1.0.0"), 0)
        XCTAssertLessThan(c.compareVersions("1.0.0", "1.0.1"), 0)
    }

    func testVlcTileCap() {
        let engine = VlcEngine()
        XCTAssertTrue(engine.reserve(slotId: "a"))
        XCTAssertTrue(engine.reserve(slotId: "b"))
        XCTAssertTrue(engine.reserve(slotId: "c"))
        XCTAssertTrue(engine.reserve(slotId: "d"))
        XCTAssertFalse(engine.reserve(slotId: "e"))
        XCTAssertEqual(engine.tileCount, 4)
        engine.release(slotId: "a")
        XCTAssertTrue(engine.reserve(slotId: "e"))
    }

    func testVlcHeaderAllowlist() {
        let engine = VlcEngine()
        let opts = engine.vlcOptions(from: [
            "User-Agent": "Rally/macOS",
            "Referer": "https://example.com/",
            "Cookie": "secret=1",
            "Authorization": "Bearer x",
        ])
        XCTAssertEqual(opts, ["http-user-agent": "Rally/macOS", "http-referrer": "https://example.com/"])
        XCTAssertNil(engine.vlcOptions(from: nil)["http-user-agent"])
    }

    func testPortalNormalizer() {
        XCTAssertEqual(UrlNormalizer.normalizePortal("example.to:8080/c/server/load.php/"), "http://example.to:8080/c")
        XCTAssertEqual(UrlNormalizer.normalizePortal("https://host.tv/stalker_portal"), "https://host.tv/stalker_portal")
        XCTAssertEqual(UrlNormalizer.normalizePortal(""), "")
    }

    func testAddonNormalizer() {
        XCTAssertEqual(UrlNormalizer.normalizeAddon("sports.highfly.to"), "https://sports.highfly.to/manifest.json")
        XCTAssertEqual(UrlNormalizer.normalizeAddon("https://sports.highfly.to/manifest.json"), "https://sports.highfly.to/manifest.json")
        XCTAssertNil(UrlNormalizer.normalizeAddon("   "))
    }

    func testXtreamNormalizer() {
        XCTAssertEqual(UrlNormalizer.normalizeXtreamServer("line.tv:8080/player_api.php"), "http://line.tv:8080")
        XCTAssertEqual(UrlNormalizer.normalizeXtreamServer(""), "")
    }

    @MainActor
    func testStalkerChannelMapping() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "RallyTests")!)
        let client = StalkerClient(settings: store)
        let obj: [String: Any] = ["id": "7", "name": "ESPN 1080p", "number": "7",
            "logo": "http://x/logo.png", "tv_genre_id": "1", "cmd": "ffmpeg http://x/7",
            "tv_archive": "1", "tv_archive_duration": "12"]
        let ch = client.mapChannel(obj, genres: ["1": "Sports"])
        XCTAssertEqual(ch?.id, "7")
        XCTAssertEqual(ch?.category, "Sports")
        XCTAssertEqual(ch?.streamUrl, "ffmpeg http://x/7")
        XCTAssertTrue(ch?.supportsCatchUp == true)
        XCTAssertEqual(ch?.archiveDurationHours, 12)
        XCTAssertEqual(client.cleanStreamUrl("ffmpeg http://x/7"), "http://x/7")
        // Single pass like Android: "auto " strips, remaining "ffrt " stays.
        XCTAssertEqual(client.cleanStreamUrl("auto ffrt http://x/7"), "ffrt http://x/7")
    }

    @MainActor
    func testStalkerGuideParsing() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "RallyTests")!)
        let client = StalkerClient(settings: store)
        let now = Int64(Date().timeIntervalSince1970)
        let js: [String: Any] = ["data": [
            ["name": "Past Show", "start_timestamp": "\(now - 7200)", "stop_timestamp": "\(now - 3600)"],
            ["name": "Live Game", "start_timestamp": "\(now - 100)", "stop_timestamp": "\(now + 3500)"],
            ["name": "Up Next", "start_timestamp": "\(now + 3500)", "stop_timestamp": "\(now + 7000)"],
        ]]
        let guide = client.parseGuide(js)
        XCTAssertEqual(guide?.now?.title, "Live Game")
        XCTAssertEqual(guide?.next?.title, "Up Next")
    }

    @MainActor
    func testXtreamUrlBuilder() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "RallyTests")!)
        let client = XtreamClient(settings: store)
        let a = XtreamClient.Account(server: "http://line.tv:8080", username: "u", password: "p")
        XCTAssertEqual(client.playerApi(a)?.absoluteString, "http://line.tv:8080/player_api.php?username=u&password=p")
        XCTAssertEqual(client.playerApi(a, action: "get_live_streams")?.absoluteString,
            "http://line.tv:8080/player_api.php?username=u&password=p&action=get_live_streams")
        XCTAssertEqual(client.liveStream(a, streamId: "123")?.absoluteString, "http://line.tv:8080/live/u/p/123.m3u8")
    }

    @MainActor
    func testSettingsDefaultsAndFavorites() {
        let defaults = UserDefaults(suiteName: "RallyTests")!
        defaults.removePersistentDomain(forName: "RallyTests")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.stremioAddonUrls, [SettingsStore.defaultAddon])
        XCTAssertTrue(store.liveGameAlertsEnabled)
        XCTAssertFalse(store.setupComplete)
        XCTAssertFalse(store.hasCredentials == false && store.stremioAddonUrls.isEmpty)
        let team = FavoriteTeam(id: "1", league: "NFL", name: "Cowboys", abbreviation: "DAL")
        XCTAssertTrue(store.toggleFavoriteTeam(team))
        XCTAssertTrue(store.isFavoriteTeam(id: "1", league: "nfl"))
        XCTAssertFalse(store.toggleFavoriteTeam(team))
        XCTAssertTrue(store.macAddress.hasPrefix("00:1A:79:"))
    }

    @MainActor
    func testStreamHealthScore() {
        let defaults = UserDefaults(suiteName: "RallyTests")!
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(StreamHealth().score, 0)
        XCTAssertEqual(StreamHealth(successes: 1, averageStartupMs: 750).score, 23)
        XCTAssertEqual(StreamHealth(failures: 10).score, -240)
        store.recordStreamSuccess(target: "http://x/1", startupMs: 750)
        XCTAssertEqual(store.streamHealth(target: "http://x/1").successes, 1)
    }
}
