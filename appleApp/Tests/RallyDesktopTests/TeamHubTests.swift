import XCTest
@testable import RallyCore

/// ESPN team-endpoint parsers (stubbed transport, no network).
final class TeamHubTests: XCTestCase {
    private func client() -> EspnClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return EspnClient(session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubURLProtocol.result = nil
        super.tearDown()
    }

    func testFetchTeamsCatalog() async {
        StubURLProtocol.result = { _ in (200, [:], """
            {"sports": [{"leagues": [{"teams": [
              {"team": {"id": "1", "displayName": "Dallas Cowboys", "abbreviation": "DAL",
                        "logos": [{"href": "https://x/dal.png"}]}},
              {"team": {"id": "2", "displayName": "Philadelphia Eagles", "abbreviation": "PHI"}}
            ]}]}]}
            """.data(using: .utf8)) }
        let teams = await client().fetchTeams(sport: "football", league: "nfl")
        XCTAssertEqual(teams.count, 2)
        XCTAssertEqual(teams[0].name, "Dallas Cowboys")
        XCTAssertEqual(teams[0].logoUrl, "https://x/dal.png")
        XCTAssertNil(teams[1].logoUrl)
    }

    func testFetchTeamsEmptyOnError() async {
        StubURLProtocol.result = { _ in (500, [:], nil) }
        let teams = await client().fetchTeams(sport: "football", league: "nfl")
        XCTAssertTrue(teams.isEmpty)
    }

    func testFetchTeamStanding() async {
        StubURLProtocol.result = { _ in (200, [:], """
            {"team": {"id": "1", "displayName": "Dallas Cowboys",
                      "record": {"summary": "10-7", "items": [{"summary": "10-7"}]}, "rank": 5}}
            """.data(using: .utf8)) }
        let standing = await client().fetchTeamStanding(sport: "football", league: "nfl", teamId: "1")
        XCTAssertEqual(standing.summary, "10-7")
        XCTAssertEqual(standing.rank, "5")
    }

    func testFetchRoster() async {
        StubURLProtocol.result = { _ in (200, [:], """
            {"athletes": [
              {"id": "a1", "displayName": "Dak Prescott", "shortName": "D. Prescott",
               "jersey": "4", "position": {"abbreviation": "QB"},
               "headshot": {"href": "https://x/dak.png"}},
              {"id": "a2", "displayName": "", "shortName": ""}
            ]}
            """.data(using: .utf8)) }
        let roster = await client().fetchRoster(sport: "football", league: "nfl", teamId: "1")
        XCTAssertEqual(roster.count, 1)
        XCTAssertEqual(roster[0].name, "Dak Prescott")
        XCTAssertEqual(roster[0].position, "QB")
        XCTAssertEqual(roster[0].headshotUrl, "https://x/dak.png")
    }

    func testFetchInjuries() async {
        StubURLProtocol.result = { _ in (200, [:], """
            {"injuries": [
              {"status": "Out", "details": "Knee",
               "athlete": {"displayName": "Trevon Diggs", "position": {"abbreviation": "CB"}}}
            ]}
            """.data(using: .utf8)) }
        let injuries = await client().fetchInjuries(sport: "football", league: "nfl", teamId: "1")
        XCTAssertEqual(injuries.count, 1)
        XCTAssertEqual(injuries[0].playerName, "Trevon Diggs")
        XCTAssertEqual(injuries[0].status, "Out")
        XCTAssertEqual(injuries[0].detail, "Knee")
    }

    func testInjuriesEmptyWhenMissing() async {
        StubURLProtocol.result = { _ in (200, [:], "{}".data(using: .utf8)) }
        let injuries = await client().fetchInjuries(sport: "football", league: "nfl", teamId: "1")
        XCTAssertTrue(injuries.isEmpty)
    }
}

/// Standings endpoint + playoff/RedZone helpers (Android getLeagueHub).
final class LeagueHubTests: XCTestCase {
    private func client() -> EspnClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return EspnClient(session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubURLProtocol.result = nil
        super.tearDown()
    }

    func testFetchStandings() async {
        StubURLProtocol.result = { _ in (200, [:], """
            {"children": [{"name": "AFC East", "standings": {"entries": [
              {"team": {"id": "2", "displayName": "Buffalo Bills", "abbreviation": "BUF"},
               "stats": [{"name": "wins", "value": 11}, {"name": "losses", "value": 6},
                         {"name": "winPercent", "displayValue": ".647"},
                         {"name": "gamesBehind", "displayValue": "-"}]},
              {"team": {"id": "1", "displayName": "Atlanta Falcons", "abbreviation": "ATL"},
               "stats": [{"name": "wins", "value": 0}, {"name": "losses", "value": 2}]}
            ]}}]}
            """.data(using: .utf8)) }
        let rows = await client().fetchStandings(sport: "football", league: "nfl")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].abbreviation, "BUF")
        XCTAssertEqual(rows[0].recordLine, "11-6 · .647")
        XCTAssertEqual(rows[1].recordLine, "0-2")
    }

    func testPostseasonFilter() {
        func event(_ name: String) -> SportEvent {
            SportEvent(id: name, name: name, startTime: Date(), status: .notStarted,
                       sport: "football", league: "NFL")
        }
        XCTAssertTrue(LeagueHub.isPostseasonEvent(event("AFC Wild Card: Bills at Chiefs")))
        XCTAssertTrue(LeagueHub.isPostseasonEvent(event("Super Bowl LX")))
        // Bare "Final" is a finished game, not the finals.
        XCTAssertFalse(LeagueHub.isPostseasonEvent(event("Bills 24, Chiefs 21 Final")))
        XCTAssertFalse(LeagueHub.isPostseasonEvent(event("Week 2: Bills at Dolphins")))
    }

    func testPlayoffCutoffs() {
        XCTAssertEqual(LeagueHub.playoffCutoff(league: "NFL"), 14)
        XCTAssertEqual(LeagueHub.playoffCutoff(league: "NBA"), 16)
        XCTAssertEqual(LeagueHub.playoffCutoff(league: "NHL"), 16)
        XCTAssertEqual(LeagueHub.playoffCutoff(league: "MLB"), 12)
        XCTAssertEqual(LeagueHub.playoffCutoff(league: "EPL"), 8)
    }

    func testRedZoneLookup() {
        let channels = [
            IptvChannel(id: "1", number: "1", name: "ESPN HD"),
            IptvChannel(id: "2", number: "2", name: "NFL RedZone 1080p"),
        ]
        XCTAssertEqual(LeagueHub.redZoneChannel(in: channels)?.id, "2")
        XCTAssertNil(LeagueHub.redZoneChannel(in: [channels[0]]))
    }
}
