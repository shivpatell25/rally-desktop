import Foundation

/// Port of `domain/model/Models.kt` — shared product models, no UI imports.
public enum EventStatus: String, Codable, Sendable {
    case notStarted = "NOT_STARTED"
    case live = "LIVE"
    case halftime = "HALFTIME"
    case finished = "FINISHED"
    case delayed = "DELAYED"
    case canceled = "CANCELED"
}

public enum IptvProvider: String, Codable, Sendable {
    case stalker = "STALKER"
    case xtream = "XTREAM"
}

public struct Team: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var abbreviation: String
    public var logoUrl: String?
    public var colors: [String]
    public var records: [TeamRecord]
    public init(id: String, name: String, abbreviation: String, logoUrl: String? = nil, colors: [String] = [], records: [TeamRecord] = []) {
        self.id = id; self.name = name; self.abbreviation = abbreviation
        self.logoUrl = logoUrl; self.colors = colors; self.records = records
    }
}

public struct TeamRecord: Codable, Sendable, Equatable {
    public var name: String?
    public var summary: String?
    public init(name: String? = nil, summary: String? = nil) { self.name = name; self.summary = summary }
}

public struct HighlightClip: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var description: String?
    public var durationSeconds: Int?
    public var thumbnailUrl: String?
    public var streamUrl: String?
    public var webUrl: String?
    public init(id: String, title: String, description: String? = nil, durationSeconds: Int? = nil,
                thumbnailUrl: String? = nil, streamUrl: String? = nil, webUrl: String? = nil) {
        self.id = id; self.title = title; self.description = description
        self.durationSeconds = durationSeconds; self.thumbnailUrl = thumbnailUrl
        self.streamUrl = streamUrl; self.webUrl = webUrl
    }
}

public struct PlayerStatTable: Codable, Sendable, Equatable {
    public var teamId: String?
    public var teamName: String
    public var teamAbbreviation: String
    public var teamLogoUrl: String?
    public var category: String?
    public var labels: [String]
    public var rows: [PlayerStatRow]
    public init(teamId: String? = nil, teamName: String, teamAbbreviation: String, teamLogoUrl: String? = nil,
                category: String? = nil, labels: [String] = [], rows: [PlayerStatRow] = []) {
        self.teamId = teamId; self.teamName = teamName; self.teamAbbreviation = teamAbbreviation
        self.teamLogoUrl = teamLogoUrl; self.category = category; self.labels = labels; self.rows = rows
    }
}

public struct TeamStatComparison: Codable, Sendable, Equatable {
    public var label: String
    public var awayValue: String
    public var homeValue: String
    public init(label: String, awayValue: String, homeValue: String) {
        self.label = label; self.awayValue = awayValue; self.homeValue = homeValue
    }
}

public struct PlayerStatRow: Codable, Sendable, Equatable {
    public var athleteId: String?
    public var displayName: String
    public var shortName: String?
    public var headshotUrl: String?
    public var jersey: String?
    public var position: String?
    public var stats: [String]
    public init(athleteId: String? = nil, displayName: String, shortName: String? = nil, headshotUrl: String? = nil,
                jersey: String? = nil, position: String? = nil, stats: [String] = []) {
        self.athleteId = athleteId; self.displayName = displayName; self.shortName = shortName
        self.headshotUrl = headshotUrl; self.jersey = jersey; self.position = position; self.stats = stats
    }
}

public struct PlayerLeader: Codable, Sendable, Equatable {
    public var category: String
    public var teamLogoUrl: String?
    public var teamAbbr: String?
    public var playerShortName: String
    public var statDisplay: String
    public var position: String?
    public var headshotUrl: String?
    public init(category: String, teamLogoUrl: String? = nil, teamAbbr: String? = nil,
                playerShortName: String, statDisplay: String, position: String? = nil, headshotUrl: String? = nil) {
        self.category = category; self.teamLogoUrl = teamLogoUrl; self.teamAbbr = teamAbbr
        self.playerShortName = playerShortName; self.statDisplay = statDisplay
        self.position = position; self.headshotUrl = headshotUrl
    }
}

public struct RosterPlayer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var shortName: String?
    public var position: String?
    public var jersey: String?
    public var headshotUrl: String?
    public init(id: String, name: String, shortName: String? = nil, position: String? = nil,
                jersey: String? = nil, headshotUrl: String? = nil) {
        self.id = id; self.name = name; self.shortName = shortName; self.position = position
        self.jersey = jersey; self.headshotUrl = headshotUrl
    }
}

public struct InjuryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String { playerName + (status ?? "") }
    public var playerName: String
    public var position: String?
    public var status: String?
    public var detail: String?
    public init(playerName: String, position: String? = nil, status: String? = nil, detail: String? = nil) {
        self.playerName = playerName; self.position = position; self.status = status; self.detail = detail
    }
    private enum CodingKeys: String, CodingKey { case playerName, position, status, detail }
}
public struct SportEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var homeTeam: Team?
    public var awayTeam: Team?
    public var startTime: Date
    public var status: EventStatus
    public var scoreHome: Int?
    public var scoreAway: Int?
    public var sport: String
    public var league: String
    public var bannerUrl: String?
    public var venue: String?
    public var gameStatusDetail: String?
    public var broadcasts: [String]
    public init(id: String, name: String, homeTeam: Team? = nil, awayTeam: Team? = nil,
                startTime: Date, status: EventStatus, scoreHome: Int? = nil, scoreAway: Int? = nil,
                sport: String, league: String, bannerUrl: String? = nil, venue: String? = nil,
                gameStatusDetail: String? = nil, broadcasts: [String] = []) {
        self.id = id; self.name = name; self.homeTeam = homeTeam; self.awayTeam = awayTeam
        self.startTime = startTime; self.status = status; self.scoreHome = scoreHome; self.scoreAway = scoreAway
        self.sport = sport; self.league = league; self.bannerUrl = bannerUrl; self.venue = venue
        self.gameStatusDetail = gameStatusDetail; self.broadcasts = broadcasts
    }
}

public struct StreamQualityInfo: Codable, Sendable, Equatable {
    public var resolution: String?
    public var fps: String?
    public var is4K: Bool
    public var is60Fps: Bool
    public var isHdr: Bool
    public init(resolution: String? = nil, fps: String? = nil, is4K: Bool = false, is60Fps: Bool = false, isHdr: Bool = false) {
        self.resolution = resolution; self.fps = fps; self.is4K = is4K; self.is60Fps = is60Fps; self.isHdr = isHdr
    }
}

/// 1:1 port of `parseQualityFromChannelName` in Models.kt.
/// Evidence-based labels only — never guesses 4K/HDR without a token.
public func parseQualityFromChannelName(_ name: String) -> StreamQualityInfo {
    let upper = name.uppercased()
    let res: String? = if upper.contains("4K") || upper.contains("UHD") || upper.contains("2160P") { "4K" }
        else if upper.contains("1080P") || upper.contains("1080I") || upper.contains("FHD") { "1080p" }
        else if upper.contains("720P") { "720p" }
        else if upper.contains(" HD") || upper.hasSuffix("HD") || upper.contains("| HD") || upper.contains(": HD") { "HD" }
        else { nil }
    let fps: String? = if upper.contains("60FPS") || upper.contains("60 FPS") || upper.contains(" 60P") || upper.contains(" 60 ") || upper.hasSuffix(" 60") { "60 fps" }
        else if upper.contains("50FPS") || upper.contains("50 FPS") || upper.contains(" 50P") || upper.contains(" 50 ") || upper.hasSuffix(" 50") { "50 fps" }
        else if upper.contains("30FPS") || upper.contains("30 FPS") { "30 fps" }
        else if upper.contains("25FPS") || upper.contains("25 FPS") { "25 fps" }
        else { nil }
    let isHdr = upper.contains("HDR") || upper.contains("HLG") || upper.contains("DOLBY VISION") || upper == "DV" || upper.contains(" DV")
    return StreamQualityInfo(resolution: res, fps: fps, is4K: res == "4K", is60Fps: fps == "60 fps", isHdr: isHdr)
}

public enum MultiViewLayoutMode: String, Codable, Sendable {
    case single, dual, triple, quad
    public var tileCount: Int {
        switch self { case .single: 1; case .dual: 2; case .triple: 3; case .quad: 4 }
    }
}

public struct MultiViewSlot: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var event: SportEvent?
    public var streamUrl: String
    public var streamHeaders: [String: String]?
    public var title: String
    public var subtitle: String?
    public var isLoading: Bool
    public var error: String?
    public init(id: String = UUID().uuidString, event: SportEvent? = nil, streamUrl: String = "",
                streamHeaders: [String: String]? = nil, title: String = "", subtitle: String? = nil,
                isLoading: Bool = false, error: String? = nil) {
        self.id = id; self.event = event; self.streamUrl = streamUrl; self.streamHeaders = streamHeaders
        self.title = title; self.subtitle = subtitle; self.isLoading = isLoading; self.error = error
    }
}
