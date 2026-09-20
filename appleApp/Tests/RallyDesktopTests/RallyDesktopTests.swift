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
}
