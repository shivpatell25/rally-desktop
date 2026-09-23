import Foundation

/// League-hub helpers. Mirrors `getLeagueHub` in EspnRepositoryImpl:
/// postseason detection, seeded playoff picture with per-league cutoffs,
/// RedZone channel lookup.
public enum LeagueHub {
    private static let postseasonKeywords = ["playoff", "wild card", "divisional", "conference championship",
                                             "championship", "final", "postseason", "super bowl"]

    public static func isPostseasonEvent(_ event: SportEvent) -> Bool {
        let hay = ([event.name, event.gameStatusDetail ?? ""] + event.broadcasts).joined(separator: " ").lowercased()
        // "Final" means a finished game, not the finals — require a playoff cue nearby.
        if hay.contains("final") && !hay.contains("finals") && !hay.contains("playoff") &&
            !hay.contains("championship") && !hay.contains("postseason") {
            let finalsOnly = hay.replacingOccurrences(of: "final", with: "")
            return postseasonKeywords.contains { finalsOnly.contains($0) }
        }
        return postseasonKeywords.contains { hay.contains($0) }
    }

    /// Seeded playoff-picture cutoff (Android `getLeagueHub` cutoffs).
    public static func playoffCutoff(league: String) -> Int {
        switch league.lowercased() {
        case "nfl": return 14
        case "nba", "nhl": return 16
        case "mlb": return 12
        default: return 8
        }
    }

    /// Postseason shelf: real postseason events first, else the seeded picture.
    public static func postseasonEvents(from events: [SportEvent]) -> [SportEvent] {
        events.filter(isPostseasonEvent)
    }

    public static func playoffPicture(standings: [StandingEntry], league: String) -> [StandingEntry] {
        Array(standings.prefix(playoffCutoff(league: league)))
    }

    /// NFL RedZone channel lookup (Android LeagueHubViewModel name match).
    public static func redZoneChannel(in channels: [IptvChannel]) -> IptvChannel? {
        channels.first {
            let n = $0.name.lowercased()
            return n.contains("redzone") || (n.contains("red zone") && n.contains("nfl"))
        } ?? channels.first { $0.name.lowercased().contains("red zone") }
    }
}
