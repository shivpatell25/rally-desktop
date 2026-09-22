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
