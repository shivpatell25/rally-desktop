import XCTest
@testable import RallyCore

/// Shared matcher vectors (Tests/RallyDesktopTests/Fixtures/matcher.json —
/// keep in sync with windowsApp/tests/Rally.Tests/Fixtures/matcher.json).
/// Same tiers/badges as the C# EventMatcher and Android reference.
final class MatcherFixtureTests: XCTestCase {
    struct Vector {
        var name: String
        var event: SportEvent
        var channel: IptvChannel
        var stations: [String]
        var minScore: Float
        var included: Bool
        var badge: String?
    }

    private func vectors() throws -> [Vector] {
        guard let url = Bundle.module.url(forResource: "matcher", withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("matcher.json fixture missing")
        }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = json?["vectors"] as? [[String: Any]] ?? []
        return try arr.map { v in
            func team(_ key: String) throws -> Team {
                guard let t = v[key] as? [String: Any],
                      let name = t["name"] as? String, let abbr = t["abbr"] as? String else {
                    throw XCTSkip("bad vector")
                }
                return Team(id: "id-\(key)", name: name, abbreviation: abbr)
            }
            guard let league = v["league"] as? String, let sport = v["sport"] as? String,
                  let ch = v["channel"] as? [String: Any],
                  let chName = ch["name"] as? String, let category = ch["category"] as? String,
                  let name = v["name"] as? String else {
                throw XCTSkip("bad vector")
            }
            let event = SportEvent(id: "e", name: "", homeTeam: try team("home"), awayTeam: try team("away"),
                                   startTime: Date(), status: .notStarted, sport: sport, league: league)
            let channel = IptvChannel(id: "c1", number: "1", name: chName, category: category,
                                      streamUrl: "https://x/stream.m3u8")
            let stations = (v["stations"] as? [String]) ?? []
            let minScore = Float((v["minScore"] as? NSNumber)?.floatValue ?? 0)
            return Vector(name: name, event: event, channel: channel, stations: stations,
                          minScore: minScore, included: (v["included"] as? Bool) ?? false,
                          badge: v["badge"] as? String)
        }
    }

    func testMatcherFixtures() throws {
        for v in try vectors() {
            let results = EventMatcher.relevantChannels(event: v.event, channels: [v.channel], tvStations: v.stations)
            if !v.included {
                XCTAssertTrue(results.isEmpty, "[\(v.name)] expected exclusion, got \(results.first?.likelihoodScore ?? -1)")
                continue
            }
            XCTAssertFalse(results.isEmpty, "[\(v.name)] expected inclusion")
            guard let first = results.first else { continue }
            XCTAssertGreaterThanOrEqual(first.likelihoodScore, v.minScore,
                                        "[\(v.name)] score \(first.likelihoodScore) < \(v.minScore)")
            if let badge = v.badge {
                XCTAssertEqual(first.matchBadge, badge, "[\(v.name)] badge mismatch")
            }
        }
    }
}
