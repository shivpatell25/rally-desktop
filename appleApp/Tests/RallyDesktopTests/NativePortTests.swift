import XCTest
@testable import RallyCore

final class NativePortTests: XCTestCase {
    func testM3uHeadersRelativeUrlsAndDeduplication() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-name="Sports, HD" tvg-chno="7" group-title="Sports" tvg-logo="/logo.png",Sports HD
        #EXTVLCOPT:http-user-agent=Rally Test
        live/game.m3u8|Referer=https%3A%2F%2Fprovider.example
        #EXTINF:-1,Duplicate
        live/game.m3u8|User-Agent=Rally%20Test&Referer=https%3A%2F%2Fprovider.example
        """
        let channels = try M3uClient.parse(input, source: "https://provider.example/lineup.m3u")
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].number, "7")
        XCTAssertEqual(channels[0].streamUrl, "https://provider.example/live/game.m3u8")
        XCTAssertEqual(channels[0].streamHeaders?["User-Agent"], "Rally Test")
        XCTAssertEqual(channels[0].streamHeaders?["Referer"], "https://provider.example")
        XCTAssertEqual(channels[0].logoUrl, "https://provider.example/logo.png")
    }
    func testHlsManifestRemainsOneStream() throws {
        let channels = try M3uClient.parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720\n720.m3u8", source: "https://cdn.example/master.m3u8", name: "Game")
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].streamUrl, "https://cdn.example/master.m3u8")
        XCTAssertEqual(channels[0].name, "Game")
        XCTAssertThrowsError(try M3uClient.parse("<html>bad</html>", source: "https://provider.example"))
    }
    func testPublishedQualityEvidence() {
        let qualities = PlaybackController.parseQualities("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080\nfhd.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720\nhd.m3u8")
        XCTAssertEqual(qualities.map(\.height), [1080, 720])
        XCTAssertEqual(qualities[0].bitrate, 3_000_000)
        XCTAssertTrue(PlaybackController.parseQualities("#EXTM3U\n#EXTINF:5\nsegment.ts").isEmpty)
        XCTAssertFalse(PlaybackRoute.usesAVPlayer(headers: [:], url: URL(string: "https://cdn.example/game.mpd")!))
        XCTAssertTrue(PlaybackRoute.usesAVPlayer(headers: [:], url: URL(string: "https://cdn.example/clip.mp4")!))
    }
    func testPlayByPlayMergesScoringAndDriveCoverage() throws {
        let data = Data(#"{"plays":[{"id":"a","text":"Touchdown","sequenceNumber":"12","scoringPlay":true,"awayScore":7,"homeScore":0,"period":{"number":1},"clock":{"displayValue":"8:32"}}],"scoringPlays":[{"id":"a","text":"Touchdown"}],"drives":{"current":{"yards":72,"offensivePlays":7,"description":"1st & 10","plays":[{"id":"b","text":"Pass complete","sequenceNumber":"13"}]}}}"#.utf8)
        let result = GameContext.parse(data)
        XCTAssertEqual(result.plays.map(\.id), ["b", "a"])
        XCTAssertTrue(result.plays[1].isScoringPlay)
        XCTAssertEqual(result.context["Drive Yards"], "72")
        XCTAssertEqual(result.context["Current Drive"], "1st & 10")
    }
    func testSavedEventReceivesAlertsWithoutFavoriteTeam() {
        let before = SportEvent(id: "saved", name: "Game", startTime: Date(), status: .notStarted, sport: "football", league: "NFL")
        var after = before; after.status = .live
        let alerts = GameAlerts.evaluate(previous: [before], current: [after], favIds: [], redZoneEnabled: true, savedEventIds: ["saved"])
        XCTAssertTrue(alerts.contains { $0.kind == .kickoff })
        XCTAssertTrue(GameAlerts.evaluate(previous: [before], current: [after], favIds: [], redZoneEnabled: true).isEmpty)
    }
    func testAddonDiscoverySelectsRelevantCatalogAndKeepsWebOnlyState() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        defer { StubURLProtocol.result = nil }
        StubURLProtocol.result = { request in
            let path = request.url!.path
            let json: String
            if path.hasSuffix("manifest.json") {
                json = #"{"name":"Test Sports","catalogs":[{"type":"sport","id":"movies1"},{"type":"sport","id":"movies2"},{"type":"sport","id":"movies3"},{"type":"sport","id":"movies4"},{"type":"sport","id":"movies5"},{"type":"sport","id":"movies6"},{"type":"sport","id":"nfl_live"}]}"#
            } else if path.contains("catalog/sport/nfl_live") {
                json = #"{"metas":[{"id":"game:1","type":"sport","name":"Thursday Football","description":"Dallas Cowboys against Philadelphia Eagles"}]}"#
            } else if path.contains("stream/sport/game:1") {
                json = #"{"streams":[{"title":"Main 1080p HDR","url":"https://media.example/live.m3u8","behaviorHints":{"proxyHeaders":{"request":{"Authorization":"Bearer test","Cookie":"session=test","Unsafe":"drop"}}}},{"title":"Web coverage","externalUrl":"https://media.example/watch"},{"title":"Upgrade to Premium 🔒","url":"https://media.example/locked.m3u8"}]}"#
            } else { json = #"{"metas":[]}"# }
            return (200, ["Content-Type": "application/json"], Data(json.utf8))
        }
        let client = StremioClient(session: URLSession(configuration: config))
        let event = SportEvent(id: "game", name: "Cowboys at Eagles", homeTeam: Team(id: "1", name: "Dallas Cowboys", abbreviation: "DAL"), awayTeam: Team(id: "2", name: "Philadelphia Eagles", abbreviation: "PHI"), startTime: Date(), status: .live, sport: "football", league: "NFL")
        let options = await client.findStreams(for: event, addonBase: "https://addon.example/manifest.json")
        XCTAssertEqual(options.count, 2)
        let playable = try XCTUnwrap(options.first { $0.isDirectPlayable })
        XCTAssertEqual(playable.title, "Main 1080p HDR")
        XCTAssertEqual(playable.quality, "1080p HDR")
        XCTAssertEqual(playable.headers?["Authorization"], "Bearer test")
        XCTAssertNil(playable.headers?["Unsafe"])
        XCTAssertEqual(options.first { !$0.isDirectPlayable }?.streamUrl, "https://media.example/watch")
        StubURLProtocol.result = { _ in (500, [:], nil) }
        let cached = await client.findStreams(for: event, addonBase: "https://addon.example/manifest.json")
        XCTAssertEqual(cached, options)
    }
    func testDashQualityEvidenceAndRelativeBaseUrls() throws {
        let manifest = #"<MPD><Period><BaseURL>https://cdn.example/video/</BaseURL><AdaptationSet><BaseURL>nested/</BaseURL><Representation bandwidth='800000' height='360'><SegmentTemplate initialization='init.mp4' media='segment-$Number$.m4s'/></Representation><Representation height="720" bandwidth="2000000"/></AdaptationSet></Period></MPD>"#
        XCTAssertEqual(PlaybackController.parseQualities(manifest).map(\.height), [720, 360])
        let proxy = HTTPStreamProxy(url: URL(string: "https://provider.example/master.mpd")!, headers: [:])
        let rewritten = try proxy.rewrite(manifest, base: URL(string: "https://provider.example/master.mpd")!)
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:"))
        XCTAssertTrue(rewritten.contains("<BaseURL>nested/</BaseURL>"))
        XCTAssertTrue(rewritten.contains("media='segment-$Number$.m4s'"))
    }
    func testLoopbackRelayPreservesAuthenticationAndRanges() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let upstream = URLSession(configuration: config)
        defer { StubURLProtocol.result = nil; upstream.invalidateAndCancel() }
        StubURLProtocol.result = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=test")
            if request.url!.path.hasSuffix("master.m3u8") {
                return (200, ["Content-Type": "application/vnd.apple.mpegurl"], Data("#EXTM3U\n#EXTINF:4\nhttps://cdn.example/segment.ts\n".utf8))
            }
            XCTAssertEqual(request.url!.host, "cdn.example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-3")
            return (206, ["Content-Type": "video/mp2t", "Content-Range": "bytes 0-3/100"], Data([1, 2, 3, 4]))
        }
        let proxy = HTTPStreamProxy(url: URL(string: "https://provider.example/master.m3u8")!, headers: ["Authorization": "Bearer test", "Cookie": "session=test"], session: upstream)
        let local = try await proxy.start(); defer { proxy.stop() }
        XCTAssertEqual(local.host, "127.0.0.1")
        var manifestRequest = URLRequest(url: local); manifestRequest.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let (manifest, _) = try await URLSession.shared.data(for: manifestRequest)
        let segment = try XCTUnwrap(String(data: manifest, encoding: .utf8)?.components(separatedBy: .newlines).first { $0.hasPrefix("http") }).trimmingCharacters(in: .whitespaces)
        var request = URLRequest(url: try XCTUnwrap(URL(string: segment))); request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        var invalid = URLComponents(url: local, resolvingAgainstBaseURL: false)!; invalid.path = "/invalid/segment.ts"
        let (_, rejected) = try await URLSession.shared.data(from: invalid.url!)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 403)
    }
    func testSummaryKeepsSavedGameStatusAndScoresCurrent() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        defer { StubURLProtocol.result = nil }
        StubURLProtocol.result = { _ in
            (200, [:], Data(#"{"header":{"id":"saved","date":"2026-10-01T00:15Z","name":"Away at Home","competitions":[{"status":{"type":{"state":"post","completed":true,"name":"STATUS_FINAL","detail":"Final"}},"competitors":[{"homeAway":"home","score":"27","team":{"id":"1","displayName":"Home","abbreviation":"HOM"}},{"homeAway":"away","score":"24","team":{"id":"2","displayName":"Away","abbreviation":"AWY"}}]}]}}"#.utf8))
        }
        let detail = await EspnClient(session: URLSession(configuration: config)).fetchSummary(sport: "football", league: "nfl", eventId: "saved")
        XCTAssertTrue(detail.isAvailable)
        XCTAssertEqual(detail.event?.id, "saved")
        XCTAssertEqual(detail.event?.league, "NFL")
        XCTAssertEqual(detail.event?.status, .finished)
        XCTAssertEqual(detail.event?.scoreHome, 27)
        XCTAssertEqual(detail.event?.scoreAway, 24)
    }
    func testFeedDistinguishesSuccessfulEmptyLeaguesFromFailures() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        defer { StubURLProtocol.result = nil }
        StubURLProtocol.result = { request in
            request.url!.path.contains("/nfl/") ? (200, [:], Data(#"{"events":[]}"#.utf8)) : (503, [:], Data())
        }
        let client = EspnClient(session: URLSession(configuration: config))
        let feed = await client.fetchSportsFeed(enabled: ["NFL", "NBA"])
        XCTAssertEqual(feed.successfulLeagues, ["NFL"])
        XCTAssertTrue(feed.events.isEmpty)
    }
    @MainActor func testWatchlistPersistsAndExportsWithoutProviderSecrets() throws {
        let name = "RallyNativePortTests-\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let event = SportEvent(id: "game", name: "Away at Home", startTime: Date(), status: .notStarted, sport: "football", league: "NFL")
        XCTAssertTrue(settings.toggleSavedEvent(event))
        let restored = SettingsStore(defaults: defaults)
        XCTAssertTrue(restored.savedEventIds.contains("game"))
        XCTAssertEqual(restored.savedEvents.first?.id, "game")
        let backup = try XCTUnwrap(settings.exportPersonalization())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        XCTAssertEqual(json["savedEventIds"] as? [String], ["game"])
        XCTAssertNil(json["m3uPlaylistUrl"])
        XCTAssertNil(json["xtreamPassword"])
        XCTAssertFalse(restored.toggleSavedEvent(event))
    }
}
