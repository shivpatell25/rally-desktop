import Foundation

private struct EspnScoreboard: Decodable {
    var events: [EspnEvent]?
}
private struct EspnEvent: Decodable {
    var id: String
    var date: String?
    var name: String?
    var shortName: String?
    var competitions: [EspnCompetition]?
}
private struct EspnCompetition: Decodable {
    var status: EspnStatus?
    var competitors: [EspnCompetitor]?
    var broadcasts: [EspnBroadcast]?
    var venue: EspnVenue?
}
private struct EspnStatus: Decodable {
    var type: EspnStatusType?
}
private struct EspnStatusType: Decodable {
    var name: String?
    var state: String?
    var completed: Bool?
    var detail: String?
    var shortDetail: String?
}
private struct EspnCompetitor: Decodable {
    var homeAway: String?
    var team: EspnTeam?
    var score: String?
    var records: [EspnRecord]?
}
private struct EspnRecord: Decodable {
    var name: String?
    var summary: String?
}
private struct EspnTeam: Decodable {
    var id: String?
    var name: String?
    var displayName: String?
    var abbreviation: String?
    var logo: String?
}
private struct EspnBroadcast: Decodable {
    var names: [String]?
}
private struct EspnVenue: Decodable {
    var fullName: String?
}

/// ESPN scoreboard client. Base + league map mirror Android `DataModule`/`EspnRepositoryImpl`.
public final class EspnClient: Sendable {
    public static let baseURL = "https://site.api.espn.com/apis/site/v2/"
    /// Domain league -> (sport, league) path. 1:1 with `espnLeagues` in EspnRepositoryImpl.kt.
    public static let leagues: [(league: String, sport: String, path: String)] = [
        ("NFL", "football", "nfl"),
        ("NCAAF", "football", "college-football"),
        ("NBA", "basketball", "nba"),
        ("NCAAB", "basketball", "mens-college-basketball"),
        ("MLB", "baseball", "mlb"),
        ("NHL", "hockey", "nhl"),
        ("EPL", "soccer", "eng.1"),
        ("La Liga", "soccer", "esp.1"),
        ("Champions League", "soccer", "uefa.champions"),
        ("Serie A", "soccer", "ita.1"),
        ("MLS", "soccer", "usa.1"),
    ]

    private let session: URLSession
    private let decoder: JSONDecoder
    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    public func fetchAllLeagues(limit: Int = 100) async -> [SportEvent] {
        await withTaskGroup(of: [SportEvent].self) { group in
            for entry in Self.leagues {
                group.addTask { (try? await self.fetchScoreboard(sport: entry.sport, league: entry.path, domainLeague: entry.league, limit: limit)) ?? [] }
            }
            var out: [SportEvent] = []
            for await events in group { out.append(contentsOf: events) }
            return out.sorted { $0.startTime < $1.startTime }
        }
    }

    public func fetchScoreboard(sport: String, league: String, domainLeague: String, limit: Int = 100, dates: String? = nil) async throws -> [SportEvent] {
        var comps = URLComponents(string: "\(Self.baseURL)sports/\(sport)/\(league)/scoreboard")!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let dates { items.append(URLQueryItem(name: "dates", value: dates)) }
        comps.queryItems = items
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        let board = try decoder.decode(EspnScoreboard.self, from: data)
        return (board.events ?? []).map { mapEvent($0, domainLeague: domainLeague, sport: sport) }
    }

    private func mapEvent(_ e: EspnEvent, domainLeague: String, sport: String) -> SportEvent {
        let comp = e.competitions?.first
        let home = comp?.competitors?.first { $0.homeAway == "home" }
        let away = comp?.competitors?.first { $0.homeAway == "away" }
        func team(_ c: EspnCompetitor?) -> Team? {
            guard let t = c?.team else { return nil }
            return Team(id: t.id ?? UUID().uuidString, name: t.displayName ?? t.name ?? "?",
                        abbreviation: t.abbreviation ?? "?", logoUrl: t.logo,
                        records: (c?.records ?? []).map { TeamRecord(name: $0.name, summary: $0.summary) })
        }
        let state = comp?.status?.type?.state?.lowercased() ?? ""
        let name = comp?.status?.type?.name?.lowercased() ?? ""
        let completed = comp?.status?.type?.completed ?? false
        let status: EventStatus = if completed || state == "post" { .finished }
            else if name.contains("half") { .halftime }
            else if state == "in" { .live }
            else if state == "pre" { .notStarted }
            else { .notStarted }
        let start = e.date.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let detail = comp?.status?.type?.shortDetail ?? comp?.status?.type?.detail
        return SportEvent(id: e.id, name: e.name ?? e.shortName ?? "Game",
            homeTeam: team(home), awayTeam: team(away), startTime: start, status: status,
            scoreHome: home?.score.flatMap(Int.init), scoreAway: away?.score.flatMap(Int.init),
            sport: sport, league: domainLeague, venue: comp?.venue?.fullName, gameStatusDetail: detail)
    }
}
