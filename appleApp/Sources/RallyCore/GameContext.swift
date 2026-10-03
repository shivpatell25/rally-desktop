import Foundation

public struct GamePlay: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sequence: Int
    public var text: String
    public var awayScore: Int?
    public var homeScore: Int?
    public var period: Int?
    public var clock: String?
    public var isScoringPlay: Bool
}

public enum GameContext {
    /// Summary APIs vary by sport. Read optional play/situation data without
    /// making the whole summary fail when a sport omits a field.
    public static func parse(_ data: Data) -> (plays: [GamePlay], context: [String: String]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], [:]) }
        var entries = root["plays"] as? [[String: Any]] ?? []
        if let drives = root["drives"] as? [String: Any] {
            for drive in drives["previous"] as? [[String: Any]] ?? [] { entries += drive["plays"] as? [[String: Any]] ?? [] }
            if let current = drives["current"] as? [String: Any] { entries += current["plays"] as? [[String: Any]] ?? [] }
        }
        entries += root["scoringPlays"] as? [[String: Any]] ?? []
        let scoringIds = Set((root["scoringPlays"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        var seen = Set<String>()
        let plays = entries.enumerated().compactMap { index, row -> GamePlay? in
            guard let text = row["text"] as? String, !text.isEmpty else { return nil }
            let id = (row["id"] as? String) ?? "\(index)-\(text)"
            guard seen.insert(id).inserted else { return nil }
            let sequence = (row["sequenceNumber"] as? Int) ?? (row["sequenceNumber"] as? String).flatMap(Int.init) ?? index
            return GamePlay(id: id, sequence: sequence, text: text, awayScore: row["awayScore"] as? Int,
                            homeScore: row["homeScore"] as? Int, period: (row["period"] as? [String: Any])?["number"] as? Int,
                            clock: (row["clock"] as? [String: Any])?["displayValue"] as? String,
                            isScoringPlay: (row["scoringPlay"] as? Bool ?? false) || scoringIds.contains(id))
        }.sorted { $0.sequence > $1.sequence }
        var context: [String: String] = [:]
        let header = root["header"] as? [String: Any]
        let competition = (header?["competitions"] as? [[String: Any]])?.first
        if let situation = competition?["situation"] as? [String: Any] {
            if let down = situation["shortDownDistanceText"] as? String ?? situation["downDistanceText"] as? String { context["Current Drive"] = down }
            if let yard = situation["yardLine"] as? Int { context["Yard Line"] = String(yard) }
            if let team = situation["possession"] as? String { context["Possession"] = team }
            if situation["isRedZone"] as? Bool == true { context["Red Zone"] = "In the red zone" }
        }
        if let current = (root["drives"] as? [String: Any])?["current"] as? [String: Any] {
            if let description = current["description"] as? String { context["Current Drive"] = description }
            if let yards = current["yards"] as? Int { context["Drive Yards"] = String(yards) }
            if let count = current["offensivePlays"] as? Int { context["Drive Plays"] = String(count) }
            if let time = (current["timeElapsed"] as? [String: Any])?["displayValue"] as? String { context["Drive Time"] = time }
        }
        return (plays, context)
    }
}
