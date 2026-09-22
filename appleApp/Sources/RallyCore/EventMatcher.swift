import Foundation

/// Tiered IPTV matcher. 1:1 port of `EventMatcher.cs` /
/// `MatchEventToStreamUseCase.getRelevantChannelsForEvent`: station splitting +
/// aliases, RSN detection, college handling, conflicting-sport veto, replay/test
/// exclusion, league-package tier, 100/96/90/82/55/35/25/15/5 scoring with
/// badges. Broadcast stations come from the ESPN summary/scoreboard for the
/// event; pass empty when unknown (official-broadcast tier stays dormant).
public struct RelevantChannel: Sendable, Equatable {
    public var channel: IptvChannel
    public var likelihoodScore: Float
    public var matchBadge: String?
    public var isOfficialBroadcast: Bool
    public init(channel: IptvChannel, likelihoodScore: Float, matchBadge: String? = nil, isOfficialBroadcast: Bool = false) {
        self.channel = channel; self.likelihoodScore = likelihoodScore
        self.matchBadge = matchBadge; self.isOfficialBroadcast = isOfficialBroadcast
    }
}

private final class RegexBox: @unchecked Sendable {
    var word: [String: NSRegularExpression] = [:]
    var station: [String: NSRegularExpression] = [:]
    let lock = NSLock()
}

public enum EventMatcher {
    private static let box = RegexBox()

    public static func relevantChannels(event: SportEvent, channels: [IptvChannel],
                                        tvStations: [String] = []) -> [RelevantChannel] {
        let stations = tvStations.flatMap { $0.split(whereSeparator: { ",/&+|".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { $0.count >= 2 }
            .reduce(into: [String]()) { out, s in
                if !out.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { out.append(s) }
            }
        let homeName = event.homeTeam?.name.lowercased() ?? ""
        let awayName = event.awayTeam?.name.lowercased() ?? ""
        let homeAbbr = event.homeTeam?.abbreviation.lowercased() ?? ""
        let awayAbbr = event.awayTeam?.abbreviation.lowercased() ?? ""
        let homeParts = homeName.split(separator: " ").map(String.init)
        let awayParts = awayName.split(separator: " ").map(String.init)
        let homeCity = homeParts.dropLast().joined(separator: " ")
        let awayCity = awayParts.dropLast().joined(separator: " ")
        let homeNick = homeParts.last ?? ""
        let awayNick = awayParts.last ?? ""
        let leagueLower = event.league.lowercased()
        let sportLower = event.sport.lowercased()
        var out: [RelevantChannel] = []

        for channel in channels {
            let nameLower = channel.name.lowercased()
            let catLower = channel.category.lowercased()
            if nameLower.contains("replay") || nameLower.contains("classic") || nameLower.contains("rewind") ||
                nameLower.contains("vault") || nameLower.contains("offline") || nameLower.contains("test") {
                continue
            }
            let conflicting = isConflictingSport(nameLower: nameLower, catLower: catLower, leagueLower: leagueLower, sportLower: sportLower)

            var matchedStation: String?
            for station in stations {
                if stationAliases(station).contains(where: { matchesBroadcastStation(channelNameLower: nameLower, stationLower: $0.lowercased()) }) {
                    matchedStation = station
                    break
                }
            }
            let official = matchedStation != nil

            let isCollege = leagueLower.hasPrefix("ncaa") || leagueLower.contains("college")
            let hasLeagueOrSport = nameLower.contains(leagueLower) || catLower.contains(leagueLower) ||
                nameLower.contains(sportLower) || catLower.contains(sportLower) ||
                (isCollege && (nameLower.contains("college") || catLower.contains("college") ||
                    nameLower.contains("sec") || nameLower.contains("acc") ||
                    nameLower.contains("big ten") || nameLower.contains("btn") ||
                    nameLower.contains("ncaa") || catLower.contains("ncaa")))
            let hasVs = nameLower.contains("vs") || nameLower.contains("@")
            let homeAbbrMatch = (2...6).contains(homeAbbr.count) && matchesWord(nameLower, homeAbbr) && (hasLeagueOrSport || hasVs)
            let awayAbbrMatch = (2...6).contains(awayAbbr.count) && matchesWord(nameLower, awayAbbr) && (hasLeagueOrSport || hasVs)
            let homeFull = homeName.count > 3 && nameLower.contains(homeName)
            let awayFull = awayName.count > 3 && nameLower.contains(awayName)
            let homeCityMatch = homeCity.count > 3 && matchesWord(nameLower, homeCity)
            let awayCityMatch = awayCity.count > 3 && matchesWord(nameLower, awayCity)
            let homeNickMatch = homeNick.count > 2 && matchesWord(nameLower, homeNick)
            let awayNickMatch = awayNick.count > 2 && matchesWord(nameLower, awayNick)
            let bothNicks = homeNick.count > 2 && awayNick.count > 2 && homeNickMatch && awayNickMatch
            let bothNames = (homeFull && awayFull) || (homeFull && awayNickMatch) || (awayFull && homeNickMatch)
            let homeRsn = isTeamRsn(nameLower, city: homeCity, nickname: homeNick)
            let awayRsn = isTeamRsn(nameLower, city: awayCity, nickname: awayNick)
            let hasHome = !conflicting && (homeFull || bothNicks || homeRsn ||
                (homeCityMatch && homeNickMatch) || (homeCityMatch && hasLeagueOrSport) ||
                (homeNickMatch && hasLeagueOrSport) || homeAbbrMatch)
            let hasAway = !conflicting && (awayFull || bothNicks || awayRsn ||
                (awayCityMatch && awayNickMatch) || (awayCityMatch && hasLeagueOrSport) ||
                (awayNickMatch && hasLeagueOrSport) || awayAbbrMatch)
            let bothTeams = !conflicting && (bothNicks || bothNames || (hasHome && hasAway))
            let package: Bool = {
                switch leagueLower {
                case "mlb": return nameLower.contains("mlb extra") || nameLower.contains("mlb ei") || (nameLower.contains("mlb") && hasVs)
                case "nba": return nameLower.contains("nba league pass") || nameLower.contains("nba lp") || (nameLower.contains("nba") && hasVs)
                case "nfl": return nameLower.contains("sunday ticket") || nameLower.contains("nfl st") || (nameLower.contains("nfl") && hasVs)
                case "nhl": return nameLower.contains("center ice") || nameLower.contains("nhl ci") || (nameLower.contains("nhl") && hasVs)
                default: return false
                }
            }() && (hasHome || hasAway)
            let single = (hasHome || hasAway) && (hasVs || hasLeagueOrSport || homeRsn || awayRsn)
            let direct = bothTeams || package || single
            if !(direct || official || isSportsChannel(channel)) { continue }

            var score: Float
            var badge: String?
            if bothTeams {
                score = 100; badge = "Game Matchup"
            } else if package {
                score = 96
                let teamName = hasHome ? event.homeTeam?.name : event.awayTeam?.name
                badge = teamName.map { "\($0) Live Feed" } ?? "Live Game Feed"
            } else if official, let station = matchedStation {
                let niche = conflicting ||
                    (sportLower != "golf" && nameLower.contains("golf")) ||
                    (sportLower != "tennis" && nameLower.contains("tennis")) ||
                    (sportLower != "racing" && (nameLower.contains("racing") || nameLower.contains("f1") || nameLower.contains("nascar")))
                if niche {
                    score = 55; badge = "Official Broadcast: \(station)"
                } else {
                    score = 90; badge = "Official Broadcast: \(station)"
                    if nameLower.contains("sports") || nameLower.contains("sport") || hasLeagueOrSport { score += 3 }
                    if (homeCity.count > 3 && nameLower.contains(homeCity)) ||
                        (awayCity.count > 3 && nameLower.contains(awayCity)) { score += 2 }
                }
            } else if single {
                score = 82
                let teamName = hasHome ? event.homeTeam?.name : event.awayTeam?.name
                badge = (homeRsn || awayRsn)
                    ? (teamName.map { "\($0) (RSN)" } ?? "Regional Sports")
                    : (teamName.map { "\($0) Feed" } ?? "Team Feed")
            } else {
                if let dedicated = dedicatedLeagueChannel(nameLower: nameLower, catLower: catLower, leagueLower: leagueLower) {
                    score = 35; badge = dedicated
                } else if nameLower.contains(leagueLower) || catLower.contains(leagueLower) {
                    score = 25; badge = "\(event.league) Channel"
                } else if isMajorSportsNetwork(nameLower) {
                    score = 15; badge = "Sports Network"
                } else {
                    score = 5; badge = channel.category.isEmpty ? "Sports" : channel.category
                }
            }

            let quality = parseQualityFromChannelName(channel.name)
            if quality.is4K { score += 4 }
            else if quality.resolution?.contains("1080") == true { score += 1.5 }
            if quality.fps?.contains("60") == true || quality.fps?.contains("50") == true { score += 2 }
            if nameLower.hasPrefix("us") || nameLower.contains("us |") || nameLower.contains("us:") ||
                nameLower.hasPrefix("ca") || nameLower.contains("ca |") ||
                nameLower.hasPrefix("uk") || nameLower.contains("uk |") { score += 1 }

            out.append(RelevantChannel(channel: channel, likelihoodScore: min(100, max(0, score)),
                                       matchBadge: badge, isOfficialBroadcast: official))
        }

        return out.sorted {
            if $0.likelihoodScore != $1.likelihoodScore { return $0.likelihoodScore > $1.likelihoodScore }
            let n0 = Int($0.channel.number) ?? 99999
            let n1 = Int($1.channel.number) ?? 99999
            if n0 != n1 { return n0 < n1 }
            return $0.channel.name < $1.channel.name
        }
    }

    static func isConflictingSport(nameLower: String, catLower: String, leagueLower: String, sportLower: String) -> Bool {
        let nfl = ["mlb", "milb", "baseball", "nhl", "hockey", "nba", "wnba", "basketball", "cfl", "cricket", "golf", "tennis", "rugby", "afl", "motorsport", "f1", "nascar"]
        let nba = ["mlb", "milb", "baseball", "nhl", "hockey", "nfl", "football", "cfl", "cricket", "golf", "tennis", "rugby", "motorsport"]
        let mlb = ["nfl", "football", "nhl", "hockey", "nba", "wnba", "basketball", "cricket", "golf", "tennis", "rugby", "motorsport"]
        let nhl = ["nfl", "football", "mlb", "milb", "baseball", "nba", "wnba", "basketball", "cricket", "golf", "tennis", "rugby"]
        let conflicts: [String]
        switch leagueLower {
        case "nfl": conflicts = nfl
        case "nba": conflicts = nba
        case "mlb": conflicts = mlb
        case "nhl": conflicts = nhl
        default:
            switch sportLower {
            case "football": conflicts = nfl
            case "basketball": conflicts = nba
            case "baseball": conflicts = mlb
            case "hockey": conflicts = nhl
            default: conflicts = []
            }
        }
        return conflicts.contains { catLower.contains($0) || matchesWord(nameLower, $0) }
    }

    static func isSportsChannel(_ channel: IptvChannel) -> Bool {
        let cat = channel.category.lowercased()
        let name = channel.name.lowercased()
        let blacklist = ["news", "kids", "children", "cartoon", "movie", "movies", "cinema",
            "series", "vod", "music", "radio", "religious", "islam", "christian",
            "xxx", "adult", "for adult", "docu", "documentary", "shopping"]
        if blacklist.contains(where: cat.contains) && !isMajorSportsNetwork(name) { return false }
        let sportsCats = ["sport", "espn", "football", "soccer", "futbol", "nfl", "nba", "mlb",
            "nhl", "basketball", "baseball", "hockey", "tennis", "golf", "racing",
            "f1", "formula", "nascar", "motogp", "motorsport", "fight", "mma",
            "ufc", "boxing", "wwe", "cricket", "rugby", "afl", "athletics",
            "olympic", "ppv", "live event", "events", "stadium"]
        if sportsCats.contains(where: cat.contains) { return true }
        return isMajorSportsNetwork(name)
    }

    static func stationAliases(_ station: String) -> [String] {
        let s = station.lowercased().trimmingCharacters(in: .whitespaces)
        var aliases = [s]
        if s.contains("sec network") || s == "secn" || s == "sec" {
            aliases += ["sec network", "secn", "sec net", "sec", "sec+"]
        } else if s.contains("acc network") || s == "accn" || s == "acc" {
            aliases += ["acc network", "accn", "acc net", "acc", "accnx"]
        } else if s.contains("big ten") || s.contains("btn") {
            aliases += ["big ten network", "big ten", "btn"]
        } else if s.contains("cbs sports network") || s == "cbssn" || s == "cbs sports" {
            aliases += ["cbs sports network", "cbssn", "cbs sports net", "cbs sports"]
        } else if s == "fs1" || s.contains("fox sports 1") {
            aliases += ["fox sports 1", "fs1", "fs 1"]
        } else if s == "fs2" || s.contains("fox sports 2") {
            aliases += ["fox sports 2", "fs2", "fs 2"]
        } else if s.contains("espnu") {
            aliases += ["espnu", "espn u"]
        } else if s.contains("espn2") || s.contains("espn 2") {
            aliases += ["espn2", "espn 2"]
        } else if s.contains("espn+") || s.contains("espn plus") {
            aliases += ["espn+", "espn plus", "espnplus"]
        } else if s.contains("tnt") {
            aliases += ["tnt", "tnt sports"]
        } else if s.contains("tbs") {
            aliases += ["tbs"]
        } else if s.contains("nbcsn") || s.contains("nbc sports") {
            aliases += ["nbc sports", "nbcsn", "nbc sports net"]
        } else if s.contains("fanduel") || s.contains("bally") {
            aliases += ["fanduel sports", "fanduel", "bally sports", "bally"]
        }
        return Array(Set(aliases))
    }

    static func isMajorSportsNetwork(_ nameLower: String) -> Bool {
        let keys = ["sports", "sport", "espn", "fox sports", "fs1", "fs2", "nbcsn", "nbc sports",
            "cbs sports", "cbssn", "tnt sports", "sky sports", "bally", "fanduel", "yes network",
            "nesn", "masn", "marquee", "altitude", "sportsnet", "tsn", "bein", "dazn",
            "super sport", "optus", "nfl network", "nfl redzone", "nba tv", "mlb network",
            "nhl network", "sec network", "secn", "acc network", "accn", "big ten", "btn", "pac-12",
            "golf channel", "tennis channel", "fight network", "ufc", "boxnation", "wwe",
            "willow", "star sports", "sony ten", "abc", "cbs", "nbc", "fox", "tnt", "tbs",
            "trutv", "usa network", "peacock"]
        return keys.contains(where: nameLower.contains)
    }

    static func dedicatedLeagueChannel(nameLower: String, catLower: String, leagueLower: String) -> String? {
        if leagueLower == "nfl" && (nameLower.contains("nfl network") || nameLower.contains("nfl redzone") || nameLower.contains("nfl sunday") || nameLower.contains("nfl game pass") || catLower.contains("nfl")) { return "NFL Network" }
        if leagueLower == "nba" && (nameLower.contains("nba tv") || nameLower.contains("nba league pass") || catLower.contains("nba")) { return "NBA TV" }
        if leagueLower == "mlb" && (nameLower.contains("mlb network") || nameLower.contains("mlb extra") || catLower.contains("mlb")) { return "MLB Network" }
        if leagueLower == "nhl" && (nameLower.contains("nhl network") || nameLower.contains("nhl center") || catLower.contains("nhl")) { return "NHL Network" }
        if (leagueLower == "epl" || leagueLower.contains("premier")) && (nameLower.contains("premier league") || nameLower.contains("sky sports pl") || nameLower.contains("tnt sports") || nameLower.contains("usa network")) { return "Premier League" }
        if (leagueLower == "ncaaf" || leagueLower == "ncaab") && (nameLower.contains("sec network") || nameLower.contains("acc network") || nameLower.contains("big ten") || nameLower.contains("btn")) { return "College Sports" }
        return nil
    }

    static func matchesBroadcastStation(channelNameLower: String, stationLower: String) -> Bool {
        if stationLower.isEmpty { return false }
        let clean = stationLower.replacingOccurrences(of: " network", with: "")
            .replacingOccurrences(of: " channel", with: "")
            .replacingOccurrences(of: " hd", with: "")
            .replacingOccurrences(of: " tv", with: "")
            .trimmingCharacters(in: .whitespaces)
        if clean.count < 2 { return false }
        let noDot = clean.replacingOccurrences(of: ".", with: "")
        if stationRegex("station_" + clean, clean).matches(channelNameLower) { return true }
        if noDot != clean,
           stationRegex("station_nodot_" + noDot, noDot).matches(channelNameLower) { return true }
        let tokens = channelNameLower.split(whereSeparator: { " |:-_/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        return tokens.contains { $0.caseInsensitiveCompare(clean) == .orderedSame ||
            (noDot != clean && $0.caseInsensitiveCompare(noDot) == .orderedSame) }
    }

    static func isTeamRsn(_ channelNameLower: String, city: String, nickname: String) -> Bool {
        if city.count < 3 && nickname.count < 3 { return false }
        if (city == "boston" || nickname.contains("sox") || nickname == "bruins") && channelNameLower.contains("nesn") { return true }
        if (city == "baltimore" || city == "washington" || nickname == "orioles" || nickname == "nationals") && channelNameLower.contains("masn") { return true }
        if (city == "new york" || nickname == "yankees" || nickname == "nets") && (channelNameLower.contains("yes network") || channelNameLower.contains("yes hd")) { return true }
        if (city == "new york" || nickname == "mets") && channelNameLower.contains("sny") { return true }
        if (city == "chicago" || nickname == "cubs") && channelNameLower.contains("marquee") { return true }
        if (city == "los angeles" || nickname == "dodgers" || nickname == "lakers") && (channelNameLower.contains("sportsnet la") || channelNameLower.contains("spectrum sports")) { return true }
        if (city == "philadelphia" || nickname == "phillies" || nickname == "flyers" || nickname == "sixers") && channelNameLower.contains("nbc") && channelNameLower.contains("phil") { return true }
        if (city == "detroit" || nickname == "tigers" || nickname == "pistons") && (channelNameLower.contains("bally") || channelNameLower.contains("fanduel")) && channelNameLower.contains("det") { return true }
        if (city == "denver" || city == "colorado" || nickname == "nuggets" || nickname == "avalanche") && channelNameLower.contains("altitude") { return true }
        return false
    }

    static func matchesWord(_ text: String, _ word: String) -> Bool {
        wordRegex(word).matches(text)
    }

    private static func wordRegex(_ word: String) -> NSRegularExpression {
        box.lock.withLock {
            if let rx = box.word[word] { return rx }
            let rx = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b",
                                              options: .caseInsensitive)
            box.word[word] = rx
            return rx
        }
    }

    private static func stationRegex(_ key: String, _ station: String) -> NSRegularExpression {
        box.lock.withLock {
            if let rx = box.station[key] { return rx }
            let rx = try! NSRegularExpression(pattern: "(?:^|[\\s|:_\\-\\[/])" + NSRegularExpression.escapedPattern(for: station) + "(?:$|[\\s|:_\\-\\]\\d/])",
                                              options: .caseInsensitive)
            box.station[key] = rx
            return rx
        }
    }
}

private extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
