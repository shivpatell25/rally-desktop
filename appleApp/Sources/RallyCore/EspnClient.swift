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
    var date: String?
    var status: EspnStatus?
    var competitors: [EspnCompetitor]?
    var broadcasts: [EspnBroadcast]?
    var venue: EspnVenue?
    var notes: [EspnNote]?
}
private struct EspnNote: Decodable {
    var headline: String?
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
    var logos: [EspnImage]?
    var color: String?
    var alternateColor: String?
}
private struct EspnBroadcast: Decodable {
    var names: [String]?
}
private struct EspnVenue: Decodable {
    var images: [EspnImage]?
    var fullName: String?
}
private struct EspnImage: Decodable {
    var href: String?
}
private struct EspnGameInfo: Decodable {
    var venue: EspnDetailVenue?
    var weather: EspnWeather?
}
private struct EspnDetailVenue: Decodable {
    var fullName: String?
    var address: EspnAddress?
    var images: [EspnImage]?
}
private struct EspnAddress: Decodable {
    var city: String?
    var state: String?
    var country: String?
}
private struct EspnWeather: Decodable {
    var temperature: Double?
    var gust: Double?
    var precipitation: Double?
}
private struct EspnArticle: Decodable {
    var headline: String?
    var description: String?
}
private struct EspnSummaryResponse: Decodable {
    var leaders: [EspnLeaderGroup]?
    var videos: [EspnVideo]?
    var boxscore: EspnBoxscore?
    var predictor: EspnPredictor?
    var gameInfo: EspnGameInfo?
    var article: EspnArticle?
}
private struct EspnPredictor: Decodable {
    var homeWinPercentage: EspnPct?
    var awayWinPercentage: EspnPct?
    var homeWinProbability: EspnPct?
    var awayWinProbability: EspnPct?
    var homeTeam: EspnPredictorSide?
    var awayTeam: EspnPredictorSide?
    var home: EspnPredictorSide?
    var away: EspnPredictorSide?
}
private struct EspnPredictorSide: Decodable {
    var winPercent: EspnPct?
    var winPercentage: EspnPct?
    var chanceToWin: EspnPct?
    var winProbability: EspnPct?
}
private enum EspnPct: Decodable {
    case number(Double)
    case text(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .text((try? c.decode(String.self)) ?? "") }
    }
    /// Normalized 0-100, nil when unparseable. Fractions (<1) scale up.
    var value: Double? {
        let raw: Double
        switch self {
        case .number(let d): raw = d
        case .text(let s):
            let clean = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
            guard let d = Double(clean) else { return nil }
            raw = d
        }
        guard raw.isFinite else { return nil }
        let pct = (raw > 0 && raw < 1) ? raw * 100 : raw
        return (0...100).contains(pct) ? pct : nil
    }
}
private struct EspnLeaderGroup: Decodable {
    var team: EspnTeam?
    var leaders: [EspnLeaderCategory]?
}
private struct EspnLeaderCategory: Decodable {
    var name: String?
    var displayName: String?
    var leaders: [EspnLeaderItem]?
}
private struct EspnLeaderItem: Decodable {
    var displayValue: String?
    var athlete: EspnAthlete?
}
private struct EspnAthlete: Decodable {
    var fullName: String?
    var displayName: String?
    var shortName: String?
    var headshot: EspnHeadshot?
    var position: EspnPosition?
    var jersey: String?
}
private struct EspnHeadshot: Decodable {
    var href: String?
}
private struct EspnPosition: Decodable {
    var abbreviation: String?
}
private enum EspnStringValue: Decodable {
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .string(String(value))
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or integer"))
        }
    }

    var value: String {
        switch self { case .string(let value): value }
    }
}
private struct EspnVideo: Decodable {
    var id: EspnStringValue?
    var headline: String?
    var description: String?
    var duration: Int?
    var thumbnail: String?
    var links: EspnVideoLinks?
}
private struct EspnVideoLinks: Decodable {
    var web: EspnHref?
    var source: EspnVideoSources?
    var mobile: EspnVideoMobile?
}
private struct EspnVideoMobile: Decodable {
    var source: EspnHref?
}
private struct EspnVideoSources: Decodable {
    var href: String?
    var HD: EspnHref?
    var HLS: EspnHlsSource?
}
private struct EspnHlsSource: Decodable {
    var href: String?
    var HD: EspnHref?
}
private struct EspnHref: Decodable {
    var href: String?
}

private struct EspnBoxscore: Decodable {
    var teams: [EspnBoxscoreTeam]?
    var players: [EspnBoxscorePlayerGroup]?
}

private struct EspnBoxscoreTeam: Decodable {
    var team: EspnTeam?
    var statistics: [EspnStatistic]?
    var homeAway: String?
}

private struct EspnStatistic: Decodable {
    var name: String?
    var displayValue: String?
    var label: String?
}

private struct EspnBoxscorePlayerGroup: Decodable {
    var team: EspnTeam?
    var statistics: [EspnBoxscorePlayerCategory]?
}

private struct EspnBoxscorePlayerCategory: Decodable {
    var name: String?
    var labels: [String]?
    var athletes: [EspnBoxscoreAthleteItem]?
}

private struct EspnBoxscoreAthleteItem: Decodable {
    var athlete: EspnAthlete?
    var stats: [String]?
}
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

    public struct SportsFeed {
        public var events: [SportEvent]
        public var successfulLeagues: Set<String>
    }
    public func fetchAllLeagues(limit: Int = 200, enabled: Set<String> = []) async -> [SportEvent] {
        await fetchSportsFeed(limit: limit, enabled: enabled).events
    }
    public func fetchSportsFeed(limit: Int = 200, enabled: Set<String> = []) async -> SportsFeed {
        let entries = Self.leagues.filter { enabled.isEmpty || enabled.contains($0.league) }
        var all: [SportEvent] = [], successful = Set<String>()
        // Android bounds scoreboard concurrency to three and preserves failed leagues.
        for offset in stride(from: 0, to: entries.count, by: 3) {
            let batch = entries[offset..<min(entries.count, offset + 3)]
            await withTaskGroup(of: (String, [SportEvent]?).self) { group in
                for entry in batch {
                    group.addTask {
                        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd"
                        let dates = ["NFL", "NCAAF"].contains(entry.league) ? nil : formatter.string(from: Date())
                        guard var events = try? await self.fetchScoreboard(sport: entry.sport, league: entry.path, domainLeague: entry.league, limit: limit, dates: dates) else { return (entry.league, nil) }
                        if events.isEmpty && dates != nil {
                            formatter.dateFormat = "yyyyMM"
                            let months = Set([formatter.string(from: Date()), formatter.string(from: Date().addingTimeInterval(7 * 86400))])
                            for month in months {
                                events += (try? await self.fetchScoreboard(sport: entry.sport, league: entry.path, domainLeague: entry.league, limit: 1000, dates: month)) ?? []
                            }
                        }
                        return (entry.league, events)
                    }
                }
                for await (league, events) in group {
                    if let events { successful.insert(league); all += events }
                }
            }
        }
        var seen = Set<String>()
        return SportsFeed(events: all.filter { seen.insert($0.id).inserted }.sorted { $0.startTime < $1.startTime }, successfulLeagues: successful)
    }

    public func fetchScheduleWindow(now: Date = Date()) async -> [SportEvent] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyyMMdd"
        let start = calendar.date(byAdding: .day, value: -1, to: now)!
        let end = calendar.date(byAdding: .day, value: 7, to: now)!
        formatter.dateFormat = "yyyyMM"
        let months = Set([formatter.string(from: start), formatter.string(from: end)]).sorted()
        var all: [SportEvent] = []
        // ESPN rejects date-range queries on this endpoint. Match Android's monthly fallback,
        // then select the local desktop week without launching a request for every day.
        for offset in stride(from: 0, to: Self.leagues.count, by: 3) {
            let batch = Self.leagues[offset..<min(Self.leagues.count, offset + 3)]
            let result = await withTaskGroup(of: [SportEvent].self) { group in
                for entry in batch {
                    group.addTask {
                        var events: [SportEvent] = []
                        for month in months {
                            events += (try? await self.fetchScoreboard(sport: entry.sport, league: entry.path, domainLeague: entry.league, limit: 1000, dates: month)) ?? []
                        }
                        return events
                    }
                }
                var result: [SportEvent] = []
                for await events in group { result += events }
                return result
            }
            all += result
        }
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        var seen = Set<String>()
        return all.filter { $0.startTime >= firstDay && $0.startTime < lastDay && seen.insert($0.id).inserted }
            .sorted { $0.startTime < $1.startTime }
    }

    public func fetchScoreboard(sport: String, league: String, domainLeague: String, limit: Int = 100, dates: String? = nil) async throws -> [SportEvent] {
        var comps = URLComponents(string: "\(Self.baseURL)sports/\(sport)/\(league)/scoreboard")!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let dates { items.append(URLQueryItem(name: "dates", value: dates)) }
        comps.queryItems = items
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        let board = try decoder.decode(EspnScoreboard.self, from: data)
        return (board.events ?? []).map { mapEvent($0, domainLeague: domainLeague, sport: sport) }
    }

    private func mapEvent(_ e: EspnEvent, domainLeague: String, sport: String) -> SportEvent {
        let comp = e.competitions?.first
        let home = comp?.competitors?.first { $0.homeAway == "home" }
        let away = comp?.competitors?.first { $0.homeAway == "away" }
        func team(_ c: EspnCompetitor?) -> Team? {
            guard let t = c?.team else { return nil }
            let colors = [t.color, t.alternateColor].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value.hasPrefix("#") ? value : "#\(value)"
            }
            return Team(id: t.id ?? UUID().uuidString, name: t.displayName ?? t.name ?? "?",
                        abbreviation: t.abbreviation ?? "?", logoUrl: t.logo ?? t.logos?.first?.href,
                        colors: colors,
                        records: (c?.records ?? []).map { TeamRecord(name: $0.name, summary: $0.summary) })
        }
        let statusType = comp?.status?.type
        let state = statusType?.state?.lowercased() ?? ""
        let name = statusType?.name?.lowercased() ?? ""
        let description = [name, statusType?.detail?.lowercased() ?? ""].joined(separator: " ")
        let completed = statusType?.completed ?? false
        let status: EventStatus = if description.contains("cancel") {
            .canceled
        } else if description.contains("delay") || description.contains("postpone") {
            .delayed
        } else if name.contains("half") {
            .halftime
        } else if completed || state == "post" {
            .finished
        } else if state == "in" {
            .live
        } else {
            .notStarted
        }
        let dateText = comp?.date ?? e.date
        let start = dateText.flatMap(Self.parseDate) ?? Date()
        let note = comp?.notes?.compactMap(\.headline).first { !$0.isEmpty }
        let detail: String? = switch status {
        case .live, .halftime:
            statusType?.shortDetail ?? statusType?.detail
        case .delayed, .canceled:
            statusType?.detail ?? statusType?.shortDetail
        case .notStarted:
            note
        case .finished:
            statusType?.detail ?? statusType?.shortDetail
        }
        var seenBroadcasts = Set<String>()
        let broadcasts = (comp?.broadcasts ?? []).flatMap { $0.names ?? [] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenBroadcasts.insert($0.lowercased()).inserted }
        func score(_ value: String?) -> Int? {
            value.flatMap(Double.init).map { Int($0.rounded(.towardZero)) }
        }
        return SportEvent(id: e.id, name: e.name ?? e.shortName ?? "Game",
            homeTeam: team(home), awayTeam: team(away), startTime: start, status: status,
            scoreHome: score(home?.score), scoreAway: score(away?.score),
            sport: sport, league: domainLeague, venue: comp?.venue?.fullName, gameStatusDetail: detail,
            broadcasts: broadcasts, venueImageUrl: comp?.venue?.images?.first?.href)
    }

    private static let isoDateWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseDate(_ value: String) -> Date? {
        if let date = isoDateWithFractionalSeconds.date(from: value) ?? isoDate.date(from: value) {
            return date
        }
        // Scoreboards commonly omit seconds (`2026-09-29T00:15Z`), which
        // Foundation's internet-date option does not accept.
        guard value.count > 16 else { return nil }
        let secondsPosition = value.index(value.startIndex, offsetBy: 16)
        guard value[secondsPosition] == "Z" || value[secondsPosition] == "+" || value[secondsPosition] == "-" else {
            return nil
        }
        var normalized = value
        normalized.insert(contentsOf: ":00", at: secondsPosition)
        return isoDate.date(from: normalized)
    }
    public struct GameDetail: Sendable {
        public var event: SportEvent?
        public var plays: [GamePlay]
        public var liveContext: [String: String]
        public var isAvailable: Bool
        public var leaders: [PlayerLeader]
        public var clips: [HighlightClip]
        public var playerTables: [PlayerStatTable]
        public var teamStats: [TeamStatComparison]
        /// ESPN matchup predictor, when published (0-100). Rendered only if present.
        public var homeWinPct: Double?
        public var awayWinPct: Double?
        public var venueName: String?
        public var venueLocation: String?
        public var venueImageUrl: String?
        public var weatherSummary: String?
        public var headline: String?
        public var summary: String?

        public init(leaders: [PlayerLeader], clips: [HighlightClip], playerTables: [PlayerStatTable],
                    teamStats: [TeamStatComparison], homeWinPct: Double? = nil, awayWinPct: Double? = nil,
                    venueName: String? = nil, venueLocation: String? = nil, venueImageUrl: String? = nil,
                    weatherSummary: String? = nil, headline: String? = nil, summary: String? = nil, plays: [GamePlay] = [], liveContext: [String: String] = [:], isAvailable: Bool = true, event: SportEvent? = nil) {
            self.event = event
            self.plays = plays; self.liveContext = liveContext; self.isAvailable = isAvailable
            self.leaders = leaders
            self.clips = clips
            self.playerTables = playerTables
            self.teamStats = teamStats
            self.homeWinPct = homeWinPct
            self.awayWinPct = awayWinPct
            self.venueName = venueName
            self.venueLocation = venueLocation
            self.venueImageUrl = venueImageUrl
            self.weatherSummary = weatherSummary
            self.headline = headline
            self.summary = summary
        }
    }

    /// Per-game summary: leaders + highlight videos. Mirrors the
    /// getSummary enrichment in EspnRepositoryImpl.
    public func fetchSummary(sport: String, league: String, eventId: String, awayAbbr: String? = nil, homeAbbr: String? = nil) async -> GameDetail {
        var comps = URLComponents(string: "\(Self.baseURL)sports/\(sport)/\(league)/summary")!
        comps.queryItems = [URLQueryItem(name: "event", value: eventId)]
        guard let url = comps.url else { return GameDetail(leaders: [], clips: [], playerTables: [], teamStats: [], isAvailable: false) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let summary = try? decoder.decode(EspnSummaryResponse.self, from: data) else {
            return GameDetail(leaders: [], clips: [], playerTables: [], teamStats: [], isAvailable: false)
        }
        var leaders: [PlayerLeader] = []
        for group in summary.leaders ?? [] {
            for cat in group.leaders ?? [] {
                guard let top = cat.leaders?.first, let athlete = top.athlete else { continue }
                let short = athlete.shortName ?? athlete.displayName ?? athlete.fullName ?? ""
                if short.isEmpty { continue }
                leaders.append(PlayerLeader(
                    category: cat.displayName ?? cat.name ?? "Leader",
                    teamLogoUrl: group.team?.logo, teamAbbr: group.team?.abbreviation,
                    playerShortName: short, statDisplay: top.displayValue ?? "",
                    position: athlete.position?.abbreviation, headshotUrl: athlete.headshot?.href))
            }
        }
        var seen = Set<String>()
        let clips: [HighlightClip] = (summary.videos ?? []).compactMap { video in
            guard let title = video.headline?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let url = video.links?.source?.HLS?.HD?.href
                ?? video.links?.source?.HLS?.href
                ?? video.links?.source?.HD?.href
                ?? video.links?.source?.href
                ?? video.links?.mobile?.source?.href
            let id = video.id?.value ?? title
            guard seen.insert(id).inserted else { return nil }
            return HighlightClip(id: id, title: title,
                description: video.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                durationSeconds: video.duration, thumbnailUrl: video.thumbnail,
                streamUrl: url, webUrl: video.links?.web?.href)
        }
        var playerTables: [PlayerStatTable] = []
        for group in summary.boxscore?.players ?? [] {
            for category in group.statistics ?? [] {
                let rows = (category.athletes ?? []).compactMap { item -> PlayerStatRow? in
                    guard let a = item.athlete else { return nil }
                    let name = a.displayName ?? a.shortName ?? a.fullName ?? ""
                    if name.isEmpty { return nil }
                    return PlayerStatRow(displayName: name, shortName: a.shortName,
                        headshotUrl: a.headshot?.href, jersey: a.jersey,
                        position: a.position?.abbreviation, stats: item.stats ?? [])
                }
                if rows.isEmpty { continue }
                playerTables.append(PlayerStatTable(teamId: group.team?.id,
                    teamName: group.team?.displayName ?? group.team?.name ?? "",
                    teamAbbreviation: group.team?.abbreviation ?? "",
                    teamLogoUrl: group.team?.logo, category: category.name,
                    labels: category.labels ?? [], rows: rows))
            }
        }
        let teamStats: [TeamStatComparison] = {
            let teams = summary.boxscore?.teams ?? []
            guard teams.count >= 2 else { return [] }
            func stats(for abbr: String?) -> [EspnStatistic] {
                guard let abbr else { return [] }
                return teams.first(where: { $0.team?.abbreviation?.caseInsensitiveCompare(abbr) == .orderedSame })?.statistics ?? []
            }
            var awayStats = stats(for: awayAbbr)
            var homeStats = stats(for: homeAbbr)
            if awayStats.isEmpty {
                awayStats = teams.first(where: { $0.homeAway == "away" })?.statistics ?? []
            }
            if homeStats.isEmpty {
                homeStats = teams.first(where: { $0.homeAway == "home" })?.statistics ?? []
            }
            if awayStats.isEmpty || homeStats.isEmpty {
                awayStats = teams.first?.statistics ?? []
                homeStats = teams.dropFirst().first?.statistics ?? []
            }
            let byAbbr = ["A": awayStats, "H": homeStats]
            let keys = Array(byAbbr.values.flatMap { $0.compactMap { $0.label ?? $0.name } })
            var seen = Set<String>()
            var out: [TeamStatComparison] = []
            for key in keys where seen.insert(key).inserted {
                guard let a = byAbbr["A"]?.first(where: { ($0.label ?? $0.name) == key })?.displayValue,
                      let h = byAbbr["H"]?.first(where: { ($0.label ?? $0.name) == key })?.displayValue else { continue }
                out.append(TeamStatComparison(label: key, awayValue: a, homeValue: h))
            }
            return out
        }()
        let predictor = summary.predictor
        let homeWinPct = predictor?.homeWinPercentage?.value
            ?? predictor?.homeWinProbability?.value
            ?? predictor?.homeTeam?.winPercent?.value
            ?? predictor?.homeTeam?.winPercentage?.value
            ?? predictor?.homeTeam?.chanceToWin?.value
            ?? predictor?.homeTeam?.winProbability?.value
            ?? predictor?.home?.winPercent?.value
            ?? predictor?.home?.chanceToWin?.value
        let awayWinPct = predictor?.awayWinPercentage?.value
            ?? predictor?.awayWinProbability?.value
            ?? predictor?.awayTeam?.winPercent?.value
            ?? predictor?.awayTeam?.winPercentage?.value
            ?? predictor?.awayTeam?.chanceToWin?.value
            ?? predictor?.awayTeam?.winProbability?.value
            ?? predictor?.away?.winPercent?.value
            ?? predictor?.away?.chanceToWin?.value
        let venue = summary.gameInfo?.venue
        let address = venue?.address
        let venueLocation = [address?.city, address?.state ?? address?.country]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        let weatherSummary: String? = {
            guard let weather = summary.gameInfo?.weather else { return nil }
            var parts: [String] = []
            if let temperature = weather.temperature {
                parts.append("\(Int(temperature.rounded()))°F")
            }
            if let gust = weather.gust, gust > 0 {
                parts.append("gusts \(Int(gust.rounded())) mph")
            }
            if let precipitation = weather.precipitation, precipitation > 0 {
                parts.append("\(Int(precipitation.rounded()))% precip.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }()
        let context = GameContext.parse(data)
        // Summary headers keep saved games current after they leave the feed window.
        var event: SportEvent?
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let header = root["header"],
           let headerData = try? JSONSerialization.data(withJSONObject: header), let snapshot = try? decoder.decode(EspnEvent.self, from: headerData) {
            let domainLeague = Self.leagues.first { $0.path == league && $0.sport == sport }?.league ?? league
            event = mapEvent(snapshot, domainLeague: domainLeague, sport: sport)
            event?.venueImageUrl = venue?.images?.first?.href
            if let fullName = venue?.fullName { event?.venue = fullName }
        }
        return GameDetail(leaders: leaders, clips: clips, playerTables: playerTables, teamStats: teamStats,
                          homeWinPct: homeWinPct, awayWinPct: awayWinPct,
                          venueName: venue?.fullName, venueLocation: venueLocation.isEmpty ? nil : venueLocation,
                          venueImageUrl: venue?.images?.first?.href, weatherSummary: weatherSummary,
                          headline: summary.article?.headline, summary: summary.article?.description, plays: context.plays, liveContext: context.context, event: event)
    }
    public static func path(forLeague domainLeague: String) -> (sport: String, path: String)? {
        leagues.first(where: { $0.league == domainLeague }).map { ($0.sport, $0.path) }
    }

    // MARK: - Team hub sources (mirrors EspnRepositoryImpl.getTeamHub)

    public struct TeamStanding: Sendable, Equatable {
        public var summary: String?
        public var rank: String?
    }

    private func getJson(_ url: URL) async -> Any? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return obj
    }

    private static func str(_ obj: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = obj[k] as? String, !s.isEmpty { return s }
            if let n = obj[k] as? Int { return String(n) }
            if let n = obj[k] as? Double, n == n.rounded() { return String(Int(n)) }
        }
        return nil
    }

    /// League team catalog for the settings browser. Never throws — empty on error.
    public func fetchTeams(sport: String, league: String) async -> [Team] {
        guard let url = URL(string: "\(Self.baseURL)sports/\(sport)/\(league)/teams") else { return [] }
        guard let root = await getJson(url) as? [String: Any] else { return [] }
        var out: [Team] = []
        let sports = root["sports"] as? [[String: Any]] ?? (root["leagues"] != nil ? [root] : [])
        for s in sports {
            for l in (s["leagues"] as? [[String: Any]]) ?? [] {
                for entry in (l["teams"] as? [[String: Any]]) ?? [] {
                    guard let t = entry["team"] as? [String: Any] else { continue }
                    let logos = t["logos"] as? [[String: Any]]
                    out.append(Team(
                        id: Self.str(t, ["id"]) ?? UUID().uuidString,
                        name: Self.str(t, ["displayName", "name"]) ?? "?",
                        abbreviation: Self.str(t, ["abbreviation", "shortName"]) ?? "?",
                        logoUrl: logos?.first.flatMap { $0["href"] as? String } ?? (t["logo"] as? String)))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    /// Standing header (record summary + rank) for a team page.
    public func fetchTeamStanding(sport: String, league: String, teamId: String) async -> TeamStanding {
        guard let url = URL(string: "\(Self.baseURL)sports/\(sport)/\(league)/teams/\(teamId)") else { return TeamStanding() }
        guard let root = await getJson(url) as? [String: Any],
              let team = root["team"] as? [String: Any] else { return TeamStanding() }
        let record = team["record"] as? [String: Any]
        let items = team["recordItems"] as? [[String: Any]] ?? record?["items"] as? [[String: Any]] ?? []
        let summary = Self.str(team, ["summary"])
            ?? items.compactMap { $0["summary"] as? String }.first
            ?? record?["summary"] as? String
        return TeamStanding(summary: summary, rank: Self.str(team, ["rank", "curatedRank"]))
    }

    /// Roster athletes with headshots for player-follow cards.
    public func fetchRoster(sport: String, league: String, teamId: String) async -> [RosterPlayer] {
        guard let url = URL(string: "\(Self.baseURL)sports/\(sport)/\(league)/teams/\(teamId)/roster") else { return [] }
        guard let root = await getJson(url) as? [String: Any],
              let athletes = root["athletes"] as? [[String: Any]] else { return [] }
        return athletes.compactMap { a in
            guard let name = Self.str(a, ["displayName", "fullName"]), !name.isEmpty else { return nil }
            let pos = (a["position"] as? [String: Any])?["abbreviation"] as? String
            let headshot = (a["headshot"] as? [String: Any])?["href"] as? String
            return RosterPlayer(id: Self.str(a, ["id"]) ?? name,
                                name: name, shortName: a["shortName"] as? String,
                                position: pos, jersey: Self.str(a, ["jersey"]), headshotUrl: headshot)
        }
    }

    /// Injury list for the team page.
    public func fetchInjuries(sport: String, league: String, teamId: String) async -> [InjuryEntry] {
        guard let url = URL(string: "\(Self.baseURL)sports/\(sport)/\(league)/teams/\(teamId)/injuries") else { return [] }
        guard let root = await getJson(url) as? [String: Any] else { return [] }
        let items = (root["injuries"] as? [[String: Any]]) ?? (root["entries"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            let athlete = item["athlete"] as? [String: Any]
            guard let name = Self.str(athlete ?? item, ["displayName", "fullName", "name"]), !name.isEmpty else { return nil }
            let pos = (athlete?["position"] as? [String: Any])?["abbreviation"] as? String
            return InjuryEntry(playerName: name, position: pos,
                               status: Self.str(item, ["status", "type"]),
                               detail: Self.str(item, ["details", "shortComment", "comment", "description"]))
        }
    }

    /// Official league table (Android `getLeagueHub` standings source — works
    /// even when the game feed is empty, unlike the old in-feed records).
    public func fetchStandings(sport: String, league: String) async -> [StandingEntry] {
        guard let url = URL(string: "\(Self.baseURL)sports/\(sport)/\(league)/standings") else { return [] }
        guard let root = await getJson(url) as? [String: Any] else { return [] }
        var out: [StandingEntry] = []
        for child in (root["children"] as? [[String: Any]]) ?? [] {
            let groups: [[String: Any]]
            if let s = child["standings"] as? [String: Any] { groups = [s] } else { groups = [child] }
            for group in groups {
                for entry in (group["entries"] as? [[String: Any]]) ?? [] {
                    let team = entry["team"] as? [String: Any]
                    let stats = (entry["stats"] as? [[String: Any]]) ?? []
                    func stat(_ name: String) -> [String: Any]? {
                        stats.first { ($0["name"] as? String) == name }
                    }
                    func intStat(_ name: String) -> Int {
                        if let v = stat(name)?["value"] as? Int { return v }
                        if let s = stat(name)?["displayValue"] as? String, let v = Int(s) { return v }
                        return 0
                    }
                    let logos = team?["logos"] as? [[String: Any]]
                    out.append(StandingEntry(
                        teamId: Self.str(team ?? [:], ["id"]) ?? "",
                        name: Self.str(team ?? [:], ["displayName", "name"]) ?? "?",
                        abbreviation: Self.str(team ?? [:], ["abbreviation", "shortName"]) ?? "?",
                        logoUrl: logos?.first.flatMap { $0["href"] as? String } ?? (team?["logo"] as? String),
                        wins: intStat("wins"), losses: intStat("losses"),
                        ties: stat("ties").flatMap { ($0["value"] as? Int) ?? Int(($0["displayValue"] as? String) ?? "") },
                        pct: stat("winPercent")?["displayValue"] as? String ?? stat("pct")?["displayValue"] as? String,
                        gamesBehind: stat("gamesBehind")?["displayValue"] as? String ?? stat("gb")?["displayValue"] as? String))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }
}
