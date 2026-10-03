import XCTest
@testable import RallyCore

final class DesktopContractFixtureTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "desktop-contract", withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("desktop-contract.json fixture missing")
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testSharedDesktopContract() throws {
        let root = try fixture()

        for row in try XCTUnwrap(root["statuses"] as? [[String: Any]]) {
            let status = try XCTUnwrap(EventStatus(rawValue: try XCTUnwrap(row["raw"] as? String)))
            let active = status == .live || status == .halftime
            XCTAssertEqual(active, row["active"] as? Bool)
        }

        for row in try XCTUnwrap(root["qualities"] as? [[String: Any]]) {
            let parsed = parseQualityFromChannelName(try XCTUnwrap(row["title"] as? String))
            XCTAssertEqual(parsed.resolution, row["resolution"] as? String)
            XCTAssertEqual(parsed.isHdr, row["hdr"] as? Bool)
            XCTAssertEqual(StreamSelector.qualityRank(parsed), (row["rank"] as? NSNumber)?.intValue)
        }

        let headerFixture = try XCTUnwrap(root["headers"] as? [String: Any])
        let sanitized = StreamRequestHeaders.sanitized(try XCTUnwrap(headerFixture["input"] as? [String: String]))
        XCTAssertEqual(Set(sanitized.keys), Set(try XCTUnwrap(headerFixture["allowed"] as? [String])))

        for row in try XCTUnwrap(root["settings"] as? [[String: Any]]) {
            let provider = try XCTUnwrap(IptvProvider(rawValue: try XCTUnwrap(row["provider"] as? String)))
            let error = SettingsValidator.validate(
                provider: provider,
                portal: row["portal"] as? String ?? "",
                mac: row["mac"] as? String ?? "",
                server: row["server"] as? String ?? "",
                user: row["user"] as? String ?? "",
                pass: row["pass"] as? String ?? "",
                addons: [])
            XCTAssertEqual(error == nil, row["valid"] as? Bool)
        }

        let detail = try XCTUnwrap(root["details"] as? [String: Any])
        let labels = try XCTUnwrap(detail["labels"] as? [String])
        let rows = try XCTUnwrap(detail["rows"] as? [[String: Any]]).map { row in
            PlayerStatRow(displayName: try XCTUnwrap(row["displayName"] as? String),
                          stats: try XCTUnwrap(row["stats"] as? [String]))
        }
        let table = PlayerStatTable(teamName: try XCTUnwrap(detail["teamName"] as? String),
                                    teamAbbreviation: try XCTUnwrap(detail["teamAbbreviation"] as? String),
                                    category: detail["category"] as? String,
                                    labels: labels,
                                    rows: rows)
        XCTAssertTrue(table.rows.allSatisfy { $0.stats.count == table.labels.count })

        for row in try XCTUnwrap(root["health"] as? [[String: Any]]) {
            let health = StreamHealth(successes: (row["successes"] as? NSNumber)?.intValue ?? 0,
                                      failures: (row["failures"] as? NSNumber)?.intValue ?? 0,
                                      averageStartupMs: (row["startupMs"] as? NSNumber)?.int64Value ?? 0)
            XCTAssertEqual(health.score, (row["score"] as? NSNumber)?.intValue)
        }
    }
}
