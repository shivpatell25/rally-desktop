import Foundation

/// Asset mapping. 1:1 with getHeroColorBackdrop / getLeagueBackdrop /
/// getSportBackdrop / getLeagueLogoResource in HomeScreen.kt.
public enum Artwork {
    /// Bundled TV artwork (hero, cards, marks, wordmark).
    public static func artURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources")
    }
    public static func heroBackdrop(event: SportEvent?) -> String {
        guard let event else { return "hero_landscape_football_rally" }
        let sport = event.sport.lowercased(), league = event.league.uppercased()
        if sport.contains("basket") || league == "NBA" || league == "NCAAB" { return "hero_landscape_basketball_rally" }
        if sport.contains("hock") || league == "NHL" { return "hero_landscape_hockey_rally" }
        if sport.contains("socc") || ["EPL", "MLS"].contains(league) || league.contains("LIGA") || league.contains("CHAMPIONS") || league.contains("SERIE") { return "hero_landscape_soccer_rally" }
        if sport.contains("base") || league == "MLB" { return "hero_landscape_baseball_rally" }
        return "hero_landscape_football_rally"
    }

    public static func shelfBackdrop(event: SportEvent?) -> String {
        guard let event else { return "card_editorial_soccer_tv" }
        let sport = event.sport.lowercased(), league = event.league.uppercased()
        if sport.contains("basket") || league == "NBA" || league == "NCAAB" { return "card_editorial_basketball_tv" }
        if sport.contains("foot") || league == "NFL" || league == "NCAAF" { return "card_editorial_football_tv" }
        if sport.contains("hock") || league == "NHL" { return "card_editorial_hockey_tv" }
        if sport.contains("base") || league == "MLB" { return "card_editorial_baseball_tv" }
        return "card_editorial_soccer_tv"
    }

    public static func leagueBackdrop(league: String) -> String {
        let l = league.uppercased()
        if l == "NBA" || l == "NCAAB" || l.contains("BASKET") { return "card_editorial_basketball_tv" }
        if l == "NHL" || l.contains("HOCKEY") { return "card_editorial_hockey_tv" }
        if l == "MLB" || l.contains("BASEBALL") { return "card_editorial_baseball_tv" }
        if ["EPL", "MLS"].contains(l) || l.contains("LIGA") || l.contains("CHAMPIONS") || l.contains("SERIE") || l.contains("SOCCER") { return "card_editorial_soccer_tv" }
        return "card_editorial_football_tv"
    }

    public static func leagueMark(league: String) -> String? {
        switch league.uppercased() {
        case "NFL": "league_mark_nfl"
        case "NBA": "league_mark_nba"
        case "MLB": "league_mark_mlb"
        case "NHL": "league_mark_nhl"
        case "EPL", "PREMIER LEAGUE": "league_mark_epl"
        case "CHAMPIONS LEAGUE": "league_mark_ucl"
        case "LA LIGA": "league_mark_laliga"
        case "SERIE A": "league_mark_seriea"
        case "MLS": "league_mark_mls"
        default: nil
        }
    }

    public static func leagueShortMark(league: String) -> String {
        switch league.uppercased() {
        case "NCAAF": "CFB"
        case "NCAAB": "CBB"
        case "CHAMPIONS LEAGUE": "UCL"
        case "LA LIGA": "LIGA"
        case "SERIE A": "SERIE A"
        default: String(league.uppercased().prefix(5))
        }
    }

    public static func displayLeague(_ league: String?) -> String {
        guard let league, !league.trimmingCharacters(in: .whitespaces).isEmpty else { return "Sports" }
        return switch league.lowercased().trimmingCharacters(in: .whitespaces) {
        case "all": "All"
        case "live": "Live"
        case "epl", "premierleague", "premier league", "eng.1": "Premier League"
        case "laliga", "la liga", "esp.1": "La Liga"
        case "mls", "usa.1": "MLS"
        case "champions", "uefa.champions", "uefa champions league": "Champions League"
        case "ncaaf": "College Football"
        case "ncaab": "College Basketball"
        default: league
        }
    }
}
