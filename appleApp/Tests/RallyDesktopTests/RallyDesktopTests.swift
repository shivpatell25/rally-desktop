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

    func testResolverRanksExactBeforeQuality() {
        let home = Team(id: "1", name: "Dallas Cowboys", abbreviation: "DAL")
        let away = Team(id: "2", name: "Philadelphia Eagles", abbreviation: "PHI")
        let event = SportEvent(id: "e1", name: "DAL @ PHI", homeTeam: home, awayTeam: away,
            startTime: Date(), status: .notStarted, sport: "football", league: "NFL")
        let opts = [
            StremioStreamOption(title: "Random 4K", streamUrl: "http://x/4k", quality: "4K"),
            StremioStreamOption(title: "Dallas Cowboys vs Philadelphia Eagles 720p", streamUrl: "http://x/720", quality: "720p"),
            StremioStreamOption(title: "Watch here", streamUrl: "http://x/page.html", isDirectPlayable: false),
        ]
        let cands = StreamResolver.candidates(event: event, channels: [], stremioOptions: opts)
        // HTML watch page filtered; addon results are event-scoped so both
        // options are exact and quality decides (Android `toCandidate`).
        XCTAssertEqual(cands.map { $0.url }, ["http://x/4k", "http://x/720"])
        XCTAssertTrue(cands.allSatisfy(\.exactMatch))
    }

    func testResolverIptvGuideMatch() {
        let home = Team(id: "1", name: "Arsenal", abbreviation: "ARS")
        let away = Team(id: "2", name: "Chelsea", abbreviation: "CHE")
        let event = SportEvent(id: "e2", name: "ARS vs CHE", homeTeam: home, awayTeam: away,
            startTime: Date(), status: .live, sport: "soccer", league: "EPL")
        let guide = ChannelGuide(now: EpgProgram(title: "Arsenal vs Chelsea"))
        let channels = [
            IptvChannel(id: "1", number: "1", name: "Sky Sports 1080p", guide: guide),
            IptvChannel(id: "2", number: "2", name: "Cooking 24/7"),
        ]
        let cands = StreamResolver.candidates(event: event, channels: channels, stremioOptions: [])
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].channel?.id, "1")
    }

    func testArtworkMapping() {
        let mlb = SportEvent(id: "1", name: "x", startTime: Date(), status: .live,
            sport: "baseball", league: "MLB")
        XCTAssertEqual(Artwork.heroBackdrop(event: mlb), "hero_landscape_baseball_rally")
        XCTAssertEqual(Artwork.shelfBackdrop(event: mlb), "card_editorial_baseball_tv")
        XCTAssertEqual(Artwork.leagueMark(league: "NFL"), "league_mark_nfl")
        XCTAssertNil(Artwork.leagueMark(league: "NCAAF"))
        XCTAssertEqual(Artwork.leagueShortMark(league: "NCAAB"), "CBB")
        XCTAssertEqual(Artwork.displayLeague("eng.1"), "Premier League")
        XCTAssertEqual(Artwork.displayLeague("ncaaf"), "College Football")
        XCTAssertNotNil(Artwork.artURL("rally_wordmark"))
        XCTAssertNotNil(Artwork.artURL("hero_landscape_football_rally"))
    }

    func testSummaryMapping() async {
        let json = """
        {"leaders": [{"team": {"abbreviation": "KC", "logo": "http://x/kc.png"},
          "leaders": [{"displayName": "Passing", "leaders": [
            {"displayValue": "280 YDS", "athlete": {"displayName": "P. Mahomes", "shortName": "P. Mahomes",
              "headshot": {"href": "http://x/m.png"}, "position": {"abbreviation": "QB"}}}]}]}],
         "videos": [{"id": 7, "headline": "Mahomes 40-yard TD", "description": "Deep strike",
          "duration": 42, "thumbnail": "http://x/t.jpg",
          "links": {"source": {"HLS": {"HD": {"href": "http://x/h.m3u8"}}}}},
          {"id": 8, "headline": "", "links": {}}]}
        """
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.result = nil
        StubURLProtocol.body = json.data(using: .utf8)
        let client = EspnClient(session: URLSession(configuration: config))
        let detail = await client.fetchSummary(sport: "football", league: "nfl", eventId: "e1")
        XCTAssertEqual(detail.leaders.count, 1)
        XCTAssertEqual(detail.leaders[0].playerShortName, "P. Mahomes")
        XCTAssertEqual(detail.leaders[0].statDisplay, "280 YDS")
        XCTAssertEqual(detail.leaders[0].teamAbbr, "KC")
        XCTAssertEqual(detail.clips.count, 1)
        XCTAssertEqual(detail.clips[0].streamUrl, "http://x/h.m3u8")
        XCTAssertEqual(detail.clips[0].durationSeconds, 42)
    }
}

final class StubURLProtocol: URLProtocol {
    static var body: Data?
    static var result: ((URLRequest) -> (status: Int, headers: [String: String], body: Data?))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let result = Self.result?(request) {
            let res = HTTPURLResponse(url: request.url!, statusCode: result.status,
                                      httpVersion: "HTTP/1.1", headerFields: result.headers)!
            client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            if let body = result.body { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let res = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        if let body = Self.body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
