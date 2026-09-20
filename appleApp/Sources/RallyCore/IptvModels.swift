import Foundation

/// IPTV + favorites models. Mirrors `domain/model/Models.kt`.
public struct IptvChannel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var number: String
    public var name: String
    public var category: String
    public var logoUrl: String?
    public var streamUrl: String?
    public var guide: ChannelGuide?
    public var supportsCatchUp: Bool
    public var archiveDurationHours: Int?
    public init(id: String, number: String, name: String, category: String = "Live TV",
                logoUrl: String? = nil, streamUrl: String? = nil, guide: ChannelGuide? = nil,
                supportsCatchUp: Bool = false, archiveDurationHours: Int? = nil) {
        self.id = id; self.number = number; self.name = name; self.category = category
        self.logoUrl = logoUrl; self.streamUrl = streamUrl; self.guide = guide
        self.supportsCatchUp = supportsCatchUp; self.archiveDurationHours = archiveDurationHours
    }
}

public struct EpgProgram: Codable, Sendable, Equatable {
    public var title: String
    public var description: String?
    public var startTime: Date?
    public var endTime: Date?
    public init(title: String, description: String? = nil, startTime: Date? = nil, endTime: Date? = nil) {
        self.title = title; self.description = description; self.startTime = startTime; self.endTime = endTime
    }
}

public struct ChannelGuide: Codable, Sendable, Equatable {
    public var now: EpgProgram?
    public var next: EpgProgram?
    public var fetchedAt: Date
    public init(now: EpgProgram? = nil, next: EpgProgram? = nil, fetchedAt: Date = Date()) {
        self.now = now; self.next = next; self.fetchedAt = fetchedAt
    }
}

public struct FavoriteTeam: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var league: String
    public var name: String
    public var abbreviation: String
    public var logoUrl: String?
    public var colors: [String]
    public init(id: String, league: String, name: String, abbreviation: String, logoUrl: String? = nil, colors: [String] = []) {
        self.id = id; self.league = league; self.name = name; self.abbreviation = abbreviation
        self.logoUrl = logoUrl; self.colors = colors
    }
    public var key: String { "\(league):\(id)" }
}
