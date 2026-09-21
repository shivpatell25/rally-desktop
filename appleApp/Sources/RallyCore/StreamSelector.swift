import Foundation

/// 1:1 port of matching + ranking helpers in `SelectBestStreamUseCase.kt`.
public enum StreamSelector {
    public static func normalizeMatchText(_ value: String) -> String {
        let lower = value.lowercased()
        let mapped: [Character] = lower.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    public static func teamMatchesText(normalizedText: String, teamName: String, abbreviation: String) -> Bool {
        let teamNorm = normalizeMatchText(teamName)
        if teamNorm.isEmpty { return false }
        if normalizedText.contains(teamNorm) { return true }
        let abbr = abbreviation.lowercased().trimmingCharacters(in: .whitespaces)
        if abbr.count >= 2 && containsWord(normalizedText, abbr) { return true }
        let words = teamNorm.split(separator: " ").map(String.init)
        let stop: Set<String> = ["fc", "cf", "sc", "ac", "cd", "ud", "rc", "bk", "if", "fk", "city", "united", "club", "real", "de", "la", "the", "athletic"]
        let sig = words.filter { $0.count > 2 && !stop.contains($0) }
        return sig.contains { containsWord(normalizedText, $0) }
    }

    public static func textMatchesEvent(_ text: String, event: SportEvent) -> Bool {
        let norm = normalizeMatchText(text)
        guard !norm.isEmpty else { return false }
        let homeOk = event.homeTeam.map { teamMatchesText(normalizedText: norm, teamName: $0.name, abbreviation: $0.abbreviation) } ?? false
        let awayOk = event.awayTeam.map { teamMatchesText(normalizedText: norm, teamName: $0.name, abbreviation: $0.abbreviation) } ?? false
        return homeOk && awayOk
    }

    /// 1:1 with `qualityRank` in SelectBestStreamUseCase.kt — higher wins:
    /// 4K(700) > 1080p(500) > 720p/HD(300) > unknown(100), HDR +60, 60fps +30.
    public static func qualityRank(_ q: StreamQualityInfo) -> Int {
        let base: Int
        if q.is4K { base = 700 } else {
            base = switch q.resolution { case "1080p": 500; case "720p", "HD": 300; default: 100 }
        }
        var rank = base
        if q.isHdr { rank += 60 }
        if q.is60Fps { rank += 30 }
        return rank
    }

    private static func containsWord(_ text: String, _ value: String) -> Bool {
        text.split(separator: " ").map(String.init).contains(value)
    }
}
