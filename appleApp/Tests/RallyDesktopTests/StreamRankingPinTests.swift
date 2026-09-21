import XCTest
@testable import RallyCore

/// Safety net for StreamSelector/StreamResolver behavior. Phase 1 aligned the
/// scale, sort, and Stremio-exact semantics to Android `SelectBestStreamUseCase`;
/// Phase 2 tightens the matcher. A pin going red must mean deliberate change.
final class StreamRankingPinTests: XCTestCase {
    private func nflEvent() -> SportEvent {
        let home = Team(id: "1", name: "Dallas Cowboys", abbreviation: "DAL")
        let away = Team(id: "2", name: "Philadelphia Eagles", abbreviation: "PHI")
        return SportEvent(id: "e1", name: "DAL @ PHI", homeTeam: home, awayTeam: away,
                          startTime: Date(), status: .notStarted, sport: "football", league: "NFL")
    }

    private func channel(_ name: String, id: String? = nil) -> IptvChannel {
        IptvChannel(id: id ?? name, number: "1", name: name, streamUrl: "https://example.com/\(id ?? name).m3u8")
    }

    private func stremio(_ title: String, url: String) -> StremioStreamOption {
        StremioStreamOption(title: title, streamUrl: url, addonName: "Test")
    }

    // MARK: qualityRank — 700-scale, 1:1 with Android (Phase 1)

    func testPinQualityScale() {
        XCTAssertEqual(StreamSelector.qualityRank(StreamQualityInfo(resolution: "4K", is4K: true)), 700)
        XCTAssertEqual(StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p")), 500)
        XCTAssertEqual(StreamSelector.qualityRank(StreamQualityInfo(resolution: "720p")), 300)
        XCTAssertEqual(StreamSelector.qualityRank(StreamQualityInfo(resolution: "HD")), 300)
        XCTAssertEqual(StreamSelector.qualityRank(StreamQualityInfo()), 100)
        XCTAssertEqual(StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p", isHdr: true)),
                       StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p")) + 60)
        XCTAssertEqual(StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p", fps: "60 fps", is60Fps: true)),
                       StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p")) + 30)
    }

    // MARK: matcher — current loose single-word gate (Phase 2 tightens)

    func testPinSingleWordGate() {
        let event = nflEvent()
        // Full names and abbreviations match.
        XCTAssertTrue(StreamSelector.textMatchesEvent("Dallas Cowboys vs Philadelphia Eagles", event: event))
        XCTAssertTrue(StreamSelector.textMatchesEvent("DAL vs PHI", event: event))
        // LOOSE: one significant word from each side is currently enough.
        XCTAssertTrue(StreamSelector.textMatchesEvent("Cowboys Eagles 1080p", event: event))
        // Unrelated stays false.
        XCTAssertFalse(StreamSelector.textMatchesEvent("Lakers vs Celtics", event: event))
    }

    // MARK: resolver — ordering, gates, dedupe, cap

    func testPinResolverOrderingExactFirstThenRank() {
        let event = nflEvent()
        let cands = StreamResolver.candidates(
            event: event,
            channels: [channel("NFL Network 720p"), channel("Dallas Cowboys vs Philadelphia Eagles 720p")],
            stremioOptions: [])
        XCTAssertEqual(cands.count, 2)
        XCTAssertTrue(cands[0].exactMatch)
        XCTAssertEqual(cands[0].title, "Dallas Cowboys vs Philadelphia Eagles 720p")
        XCTAssertFalse(cands[1].exactMatch)
    }

    func testPinIptvLeagueSubstringGate() {
        let event = nflEvent()
        let cands = StreamResolver.candidates(
            event: event,
            channels: [channel("NFL Network"), channel("Random Movie Channel")],
            stremioOptions: [])
        // League substring keeps NFL Network (non-exact); unrelated is dropped.
        XCTAssertEqual(cands.map(\.title), ["NFL Network"])
        XCTAssertFalse(cands[0].exactMatch)
    }

    func testPinStremioExactAlwaysTrue() {
        let event = nflEvent()
        let cands = StreamResolver.candidates(
            event: event, channels: [],
            stremioOptions: [stremio("Dallas Cowboys vs Philadelphia Eagles 1080p", url: "https://cdn/a.m3u8"),
                             stremio("Unrelated Show S01E01", url: "https://cdn/b.m3u8")])
        XCTAssertEqual(cands.count, 2)
        // Addon results are event-scoped by findStreams(for:), so every
        // direct-playable option is exact (Android `toCandidate`).
        XCTAssertTrue(cands.allSatisfy(\.exactMatch))
        XCTAssertEqual(cands.first(where: { $0.url == "https://cdn/a.m3u8" })?.matchConfidence ?? 0, 0.98)
        XCTAssertEqual(cands.first(where: { $0.url == "https://cdn/a.m3u8" })?.matchEvidence, "Exact event match")
    }

    func testPinDedupeAndCap() {
        let event = nflEvent()
        var opts: [StremioStreamOption] = []
        for i in 0..<45 {
            opts.append(stremio("Dallas Cowboys vs Philadelphia Eagles feed \(i)",
                                url: "https://cdn/feed\(i).m3u8"))
        }
        opts.append(stremio("Dallas Cowboys vs Philadelphia Eagles duplicate",
                            url: "https://cdn/feed0.m3u8"))
        let cands = StreamResolver.candidates(event: event, channels: [], stremioOptions: opts)
        XCTAssertEqual(cands.count, 40)
        XCTAssertEqual(Set(cands.map(\.url)).count, 40)
    }

    // MARK: Phase 1 — preflight, health, headers

    func testSortDemotesFailedPreflight() {
        func cand(_ url: String, preflight: Bool?) -> PlayCandidate {
            PlayCandidate(title: url, url: url, kind: .stremio, exactMatch: true, rank: 500,
                          preflightPassed: preflight)
        }
        let sorted = StreamResolver.sort([cand("https://cdn/failed.m3u8", preflight: false),
                                          cand("https://cdn/unknown.m3u8", preflight: nil),
                                          cand("https://cdn/ok.m3u8", preflight: true)])
        XCTAssertEqual(sorted.map(\.url),
                       ["https://cdn/ok.m3u8", "https://cdn/unknown.m3u8", "https://cdn/failed.m3u8"])
    }

    func testSortBlendsHealthAndStremioFirst() {
        func cand(_ title: String, kind: PlayCandidate.Kind, rank: Int, url: String) -> PlayCandidate {
            PlayCandidate(title: title, url: url, kind: kind, exactMatch: true, rank: rank)
        }
        // Flaky 1080p IPTV (health -240) loses to healthy 720p Stremio.
        let sorted = StreamResolver.sort(
            [cand("Flaky 1080p", kind: .iptv, rank: 500, url: "https://flaky/ch"),
             cand("Healthy 720p", kind: .stremio, rank: 300, url: "https://healthy/ch")],
            health: { $0 == "https://flaky/ch" ? -240 : 0 })
        XCTAssertEqual(sorted[0].title, "Healthy 720p")
        // All else equal, Stremio wins; then title breaks the tie.
        let tied = StreamResolver.sort(
            [cand("B feed", kind: .stremio, rank: 300, url: "https://b"),
             cand("A feed", kind: .stremio, rank: 300, url: "https://a"),
             cand("C channel", kind: .iptv, rank: 300, url: "https://c")])
        XCTAssertEqual(tied.map(\.title), ["A feed", "B feed", "C channel"])
    }

    func testPrimaryRequiresExactAndUnfailed() {
        func cand(_ url: String, exact: Bool, preflight: Bool?) -> PlayCandidate {
            PlayCandidate(title: url, url: url, kind: .stremio, exactMatch: exact, rank: 500,
                          preflightPassed: preflight)
        }
        let cands = StreamResolver.sort([cand("https://cdn/dead-exact.m3u8", exact: true, preflight: false),
                                         cand("https://cdn/live-exact.m3u8", exact: true, preflight: nil)])
        XCTAssertEqual(StreamResolver.primary(from: cands)?.url, "https://cdn/live-exact.m3u8")
        XCTAssertNil(StreamResolver.primary(from: [cand("https://cdn/x", exact: false, preflight: nil)]))
        XCTAssertNil(StreamResolver.primary(from: [cand("https://cdn/y", exact: true, preflight: false)]))
    }

    func testSanitizedHeadersAllowlist() {
        let out = StreamRequestHeaders.sanitized([
            "User-Agent": "Rally/macOS",
            "Cookie": "mac=00:11:22:33:44:55",
            "Authorization": "Bearer abc",
            "X-Custom": "drop me",
            "Evil\nHeader": "x",
            "User-Agent\r": "injected name",
            "Referer": "ok\r\ninjected",
            "Origin": "lone\rcr",
        ])
        XCTAssertEqual(out, ["User-Agent": "Rally/macOS",
                             "Cookie": "mac=00:11:22:33:44:55",
                             "Authorization": "Bearer abc"])
        XCTAssertTrue(StreamRequestHeaders.sanitized(nil).isEmpty)
    }

    func testBearerNormalization() {
        XCTAssertEqual(StreamRequestHeaders.normalizedBearerToken("abc"), "Bearer abc")
        XCTAssertEqual(StreamRequestHeaders.normalizedBearerToken("Bearer abc"), "Bearer abc")
        XCTAssertEqual(StreamRequestHeaders.normalizedBearerToken("bearer abc"), "bearer abc")
    }
}

// MARK: Preflight probe (stubbed transport, no network)

final class StreamPreflightProbeTests: XCTestCase {
    private func probe() -> StreamPreflightProbe {
        StreamPreflightProbe(callTimeout: 3, protocolClasses: [StubURLProtocol.self])
    }

    override func tearDown() {
        StubURLProtocol.result = nil
        super.tearDown()
    }

    func testVideoHeadPasses() async {
        StubURLProtocol.result = { _ in (200, ["Content-Type": "application/vnd.apple.mpegurl"], nil) }
        let r = await probe().probe(url: "https://cdn/game.m3u8")
        XCTAssertTrue(r.passed)
        XCTAssertEqual(r.statusCode, 200)
        XCTAssertEqual(r.detail, "Verified before playback")
    }

    func testHtmlBodyRejected() async {
        StubURLProtocol.result = { _ in (200, ["Content-Type": "text/html; charset=utf-8"], nil) }
        let r = await probe().probe(url: "https://cdn/watch")
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.detail, "Received a web page instead of video")
    }

    func testHeadForbiddenFallsBackToRange() async {
        StubURLProtocol.result = { req in
            req.httpMethod == "HEAD" ? (403, [:], nil) : (206, ["Content-Type": "video/mp2t"], nil)
        }
        let r = await probe().probe(url: "https://cdn/game.ts")
        XCTAssertTrue(r.passed)
        XCTAssertEqual(r.statusCode, 206)
    }

    func testHeadNotFoundReturnedDirectly() async {
        StubURLProtocol.result = { _ in (404, [:], nil) }
        let r = await probe().probe(url: "https://cdn/missing.m3u8")
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.detail, "Server returned 404")
    }

    func testNonHttpUrlFailsWithoutNetwork() async {
        StubURLProtocol.result = { _ in
            XCTFail("stub must not be hit for non-HTTP URLs")
            return (500, [:], nil)
        }
        let r = await probe().probe(url: "plugin://unresolved")
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.detail, "Provider link must be resolved first")
    }
}
