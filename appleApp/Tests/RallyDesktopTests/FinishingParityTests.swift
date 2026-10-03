import XCTest
@testable import RallyCore

final class FinishingParityTests: XCTestCase {
    func testPlayerAggregationRetainsAllPlayersAndCategories() {
        let passer = PlayerStatRow(athleteId: "1", displayName: "Player A", stats: ["18/24", "284"])
        let rushing = PlayerStatRow(athleteId: "1", displayName: "Player A", stats: ["7", "32"])
        let tables = [PlayerStatTable(teamId: "a", teamName: "Away", teamAbbreviation: "AWY", category: "Passing", labels: ["C/ATT", "YDS"], rows: [passer]), PlayerStatTable(teamId: "a", teamName: "Away", teamAbbreviation: "AWY", category: "Rushing", labels: ["CAR", "YDS"], rows: [rushing] + (2...15).map { PlayerStatRow(athleteId: "\($0)", displayName: "Player \($0)", stats: ["1", "2"]) })]
        let teams = GamePlayers.teams(from: tables)
        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams[0].players.count, 15)
        XCTAssertEqual(teams[0].players[0].categories.map(\.name), ["Passing", "Rushing"])
        XCTAssertEqual(teams[0].players[0].categories[0].values.map(\.value), ["18/24", "284"])
    }
    func testFootballScoringFlagComesFromScoringFeed() {
        let data = Data(#"{"drives":{"previous":[{"plays":[{"id":"score","sequenceNumber":"99","text":"Touchdown","awayScore":7,"homeScore":0}]}]},"scoringPlays":[{"id":"score","text":"Touchdown","scoringPlay":true}]}"#.utf8)
        let parsed = GameContext.parse(data)
        XCTAssertEqual(parsed.plays.count, 1)
        XCTAssertTrue(parsed.plays[0].isScoringPlay)
        XCTAssertEqual(parsed.plays[0].awayScore, 7)
    }
    func testFrozenPlayingClockRecoversAndPauseDoesNot() {
        let now = Date(timeIntervalSince1970: 100)
        var monitor = PlaybackProgress(); monitor.reset(now: now)
        XCTAssertFalse(monitor.stalled(position: 2, paused: false, now: now))
        XCTAssertTrue(monitor.stalled(position: 2, paused: false, now: now.addingTimeInterval(16)))
        XCTAssertTrue(monitor.consumeReconnect()); XCTAssertTrue(monitor.consumeReconnect()); XCTAssertFalse(monitor.consumeReconnect())
        XCTAssertFalse(monitor.stalled(position: 2, paused: true, now: now.addingTimeInterval(100)))
        XCTAssertFalse(monitor.stalled(position: 3, paused: false, now: now.addingTimeInterval(101)))
    }
    func testImmersiveQuadHasNoGapsAndFitsEveryCell() {
        let frames = MultiViewGeometry.frames(count: 4, width: 1920, height: 1080, immersive: true)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0].maxX, frames[1].minX)
        XCTAssertEqual(frames[0].maxY, frames[2].minY)
        XCTAssertEqual(frames[3].maxX, 1920)
        XCTAssertEqual(frames[3].maxY, 1080)
        XCTAssertEqual(frames[0].width / frames[0].height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertTrue(MultiViewGeometry.frames(count: 0, width: 0, height: 0, immersive: true).isEmpty)
    }
    func testRedZoneStatsIncludeDaytimeSlateWithoutDuplicates() {
        let day = ISO8601DateFormatter().date(from: "2026-10-04T17:00:00Z")!
        func game(_ id: String, _ offset: Double, _ status: EventStatus = .live) -> SportEvent {
            SportEvent(id: id, name: id, startTime: day.addingTimeInterval(offset), status: status, sport: "football", league: "NFL")
        }
        let early = game("early", 0), late = game("late", 3 * 3600), night = game("night", 7 * 3600), cancelled = game("cancelled", 0, .canceled)
        let games = MultiViewGames.statsEvents(selected: [early, early], titles: ["NFL RedZone"], schedule: [early, late, night, cancelled], day: day)
        XCTAssertEqual(games.map(\.id), ["early", "late"])
        XCTAssertEqual(MultiViewGames.statsEvents(selected: [early, early], titles: ["Regular"], schedule: [late], day: day).map(\.id), ["early"])
    }
}
