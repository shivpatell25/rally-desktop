import Foundation

public struct GamePlayerCategory: Equatable, Sendable {
    public var name: String
    public var values: [(label: String, value: String)]
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.values.map(\.label) == rhs.values.map(\.label) && lhs.values.map(\.value) == rhs.values.map(\.value)
    }
}
public struct GamePlayer: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var shortName: String?
    public var imageURL: String?
    public var position: String?
    public var jersey: String?
    public var categories: [GamePlayerCategory]
}
public struct GamePlayerTeam: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var abbreviation: String
    public var logoURL: String?
    public var players: [GamePlayer]
}
public enum GamePlayers {
    /// One athlete per team, retaining every published category and field.
    public static func teams(from tables: [PlayerStatTable]) -> [GamePlayerTeam] {
        var teams: [GamePlayerTeam] = []
        for table in tables where !table.rows.isEmpty {
            let key = table.teamId ?? table.teamAbbreviation
            if !teams.contains(where: { $0.id == key }) {
                teams.append(GamePlayerTeam(id: key, name: table.teamName, abbreviation: table.teamAbbreviation, logoURL: table.teamLogoUrl, players: []))
            }
            guard let ti = teams.firstIndex(where: { $0.id == key }) else { continue }
            for row in table.rows {
                let id = row.athleteId ?? row.displayName
                if !teams[ti].players.contains(where: { $0.id == id }) {
                    teams[ti].players.append(GamePlayer(id: id, name: row.displayName, shortName: row.shortName, imageURL: row.headshotUrl, position: row.position, jersey: row.jersey, categories: []))
                }
                guard let pi = teams[ti].players.firstIndex(where: { $0.id == id }) else { continue }
                let category = GamePlayerCategory(name: table.category ?? "Stats", values: table.labels.enumerated().map { ($0.element, row.stats.indices.contains($0.offset) ? row.stats[$0.offset] : "—") })
                if !teams[ti].players[pi].categories.contains(category) { teams[ti].players[pi].categories.append(category) }
            }
        }
        return teams
    }
}
public enum MultiViewGames {
    public static func statsEvents(selected: [SportEvent], titles: [String], schedule: [SportEvent], day: Date = Date()) -> [SportEvent] {
        let isRedZone = titles.contains { $0.range(of: #"red\s*zone"#, options: .regularExpression.union(.caseInsensitive)) != nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let redZone = isRedZone ? schedule.filter {
            $0.league == "NFL" && $0.status != .canceled && calendar.isDate($0.startTime, inSameDayAs: day) && (13...17).contains(calendar.component(.hour, from: $0.startTime))
        } : []
        var seen = Set<String>()
        return (selected + redZone).filter { seen.insert($0.id).inserted }.sorted { $0.startTime < $1.startTime }
    }
}
