import XCTest
@testable import RallyCore

/// Alert transition matrix (Android GameAlertManager).
final class GameAlertTests: XCTestCase {
    private func event(_ id: String, status: EventStatus, home: Int? = nil, away: Int? = nil,
                       detail: String? = nil) -> SportEvent {
        SportEvent(id: id, name: "DAL @ PHI",
                   homeTeam: Team(id: "6", name: "Dallas Cowboys", abbreviation: "DAL"),
                   awayTeam: Team(id: "12", name: "Philadelphia Eagles", abbreviation: "PHI"),
                   startTime: Date(), status: status, scoreHome: home, scoreAway: away,
                   sport: "football", league: "NFL", gameStatusDetail: detail)
    }

    private let favs: Set<String> = ["NFL:6"]

    func testKickoff() {
        let alerts = GameAlerts.evaluate(previous: [event("e", status: .notStarted)],
                                         current: [event("e", status: .live, home: 0, away: 0)],
                                         favIds: favs, redZoneEnabled: false)
        XCTAssertTrue(alerts.contains { $0.kind == .kickoff })
    }

    func testScoreChange() {
        let alerts = GameAlerts.evaluate(
            previous: [event("e", status: .live, home: 7, away: 0)],
            current: [event("e", status: .live, home: 7, away: 3)],
            favIds: favs, redZoneEnabled: false)
        XCTAssertTrue(alerts.contains { $0.kind == .score })
        XCTAssertFalse(alerts.contains { $0.kind == .redZone })
    }

    func testRedZoneTouchdownHeuristic() {
        let alerts = GameAlerts.evaluate(
            previous: [event("e", status: .live, home: 7, away: 0)],
            current: [event("e", status: .live, home: 14, away: 0)],
            favIds: favs, redZoneEnabled: true)
        XCTAssertTrue(alerts.contains { $0.kind == .redZone })
        let off = GameAlerts.evaluate(
            previous: [event("e", status: .live, home: 7, away: 0)],
            current: [event("e", status: .live, home: 14, away: 0)],
            favIds: favs, redZoneEnabled: false)
        XCTAssertFalse(off.contains { $0.kind == .redZone })
    }

    func testFinal() {
        let alerts = GameAlerts.evaluate(
            previous: [event("e", status: .live, home: 24, away: 21)],
            current: [event("e", status: .finished, home: 24, away: 21)],
            favIds: favs, redZoneEnabled: false)
        XCTAssertTrue(alerts.contains { $0.kind == .final })
    }

    func testOvertime() {
        let alerts = GameAlerts.evaluate(
            previous: [event("e", status: .live, home: 21, away: 21, detail: "4th 0:00")],
            current: [event("e", status: .live, home: 21, away: 21, detail: "Overtime")],
            favIds: favs, redZoneEnabled: false)
        XCTAssertTrue(alerts.contains { $0.kind == .overtime })
    }

    func testCloseGame() {
        let alerts = GameAlerts.evaluate(
            previous: [event("e", status: .notStarted)],
            current: [event("e", status: .live, home: 21, away: 20)],
            favIds: favs, redZoneEnabled: false)
        // Kickoff + close game both fire on the transition into a tight game.
        XCTAssertTrue(alerts.contains { $0.kind == .closeGame })
        let blowout = GameAlerts.evaluate(
            previous: [event("e", status: .live, home: 35, away: 7)],
            current: [event("e", status: .live, home: 35, away: 7)],
            favIds: favs, redZoneEnabled: false)
        XCTAssertTrue(blowout.isEmpty)
    }

    func testIgnoresNonFavorites() {
        let alerts = GameAlerts.evaluate(
            previous: [event("e", status: .notStarted)],
            current: [event("e", status: .live, home: 0, away: 0)],
            favIds: ["NFL:99"], redZoneEnabled: true)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testBareFinalIsNotPostseason() {
        // Guard for the Finals/final distinction used by LeagueHub too.
        XCTAssertFalse(LeagueHub.isPostseasonEvent(event("x", status: .finished)))
    }
}

private func event(_ id: String, status: EventStatus) -> SportEvent {
    SportEvent(id: id, name: "Week 2", startTime: Date(), status: status,
               sport: "football", league: "NFL")
}
