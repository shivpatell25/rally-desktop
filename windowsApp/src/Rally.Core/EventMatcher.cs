using System.Collections.Concurrent;
using System.Text.RegularExpressions;

// Tiered IPTV matcher. 1:1 port of MatchEventToStreamUseCase.getRelevantChannelsForEvent:
// station splitting + aliases, RSN detection, college handling, conflicting-sport
// veto, replay/test exclusion, league-package tier, 100/96/90/82/55/35/25/15/5
// scoring with badges. Broadcast stations come from the ESPN summary for the
// event; pass empty when unknown (official-broadcast tier stays dormant).
namespace Rally.Core;

public sealed record RelevantChannel(IptvChannel Channel, float LikelihoodScore, string? MatchBadge, bool IsOfficialBroadcast);

public static class EventMatcher
{
    private static readonly ConcurrentDictionary<string, Regex> WordRegex = new();
    private static readonly ConcurrentDictionary<string, Regex> StationRegex = new();

    public static List<RelevantChannel> GetRelevantChannels(
        SportEvent ev, List<IptvChannel> channels, IReadOnlyList<string>? tvStations = null)
    {
        var stations = (tvStations ?? [])
            .SelectMany(raw => raw.Split([',', '/', '&', '+', '|']))
            .Select(s => s.Trim()).Where(s => s.Length >= 2).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var homeName = ev.HomeTeam?.Name.ToLowerInvariant() ?? "";
        var awayName = ev.AwayTeam?.Name.ToLowerInvariant() ?? "";
        var homeAbbr = ev.HomeTeam?.Abbreviation.ToLowerInvariant() ?? "";
        var awayAbbr = ev.AwayTeam?.Abbreviation.ToLowerInvariant() ?? "";
        var homeParts = homeName.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var awayParts = awayName.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var homeCity = string.Join(" ", homeParts.SkipLast(1));
        var awayCity = string.Join(" ", awayParts.SkipLast(1));
        var homeNick = homeParts.LastOrDefault() ?? "";
        var awayNick = awayParts.LastOrDefault() ?? "";
        var leagueLower = ev.League.ToLowerInvariant();
        var sportLower = ev.Sport.ToLowerInvariant();
        var out_ = new List<RelevantChannel>();

        foreach (var channel in channels)
        {
            var nameLower = channel.Name.ToLowerInvariant();
            var catLower = channel.Category.ToLowerInvariant();
            if (nameLower.Contains("replay") || nameLower.Contains("classic") || nameLower.Contains("rewind") ||
                nameLower.Contains("vault") || nameLower.Contains("offline") || nameLower.Contains("test"))
                continue;
            var conflicting = IsConflictingSport(nameLower, catLower, leagueLower, sportLower);

            string? matchedStation = null;
            var official = false;
            foreach (var station in stations)
            {
                if (GetStationAliases(station).Any(a => MatchesBroadcastStation(nameLower, a.ToLowerInvariant())))
                { matchedStation = station; official = true; break; }
            }

            var isCollege = leagueLower.StartsWith("ncaa") || leagueLower.Contains("college");
            var hasLeagueOrSport = nameLower.Contains(leagueLower) || catLower.Contains(leagueLower) ||
                nameLower.Contains(sportLower) || catLower.Contains(sportLower) ||
                (isCollege && (nameLower.Contains("college") || catLower.Contains("college") ||
                    nameLower.Contains("sec") || nameLower.Contains("acc") ||
                    nameLower.Contains("big ten") || nameLower.Contains("btn") ||
                    nameLower.Contains("ncaa") || catLower.Contains("ncaa")));
            var hasVs = nameLower.Contains("vs") || nameLower.Contains("@");
            var homeAbbrMatch = homeAbbr.Length is >= 2 and <= 6 && MatchesWord(nameLower, homeAbbr) && (hasLeagueOrSport || hasVs);
            var awayAbbrMatch = awayAbbr.Length is >= 2 and <= 6 && MatchesWord(nameLower, awayAbbr) && (hasLeagueOrSport || hasVs);
            var homeFull = homeName.Length > 3 && nameLower.Contains(homeName);
            var awayFull = awayName.Length > 3 && nameLower.Contains(awayName);
            var homeCityMatch = homeCity.Length > 3 && MatchesWord(nameLower, homeCity);
            var awayCityMatch = awayCity.Length > 3 && MatchesWord(nameLower, awayCity);
            var homeNickMatch = homeNick.Length > 2 && MatchesWord(nameLower, homeNick);
            var awayNickMatch = awayNick.Length > 2 && MatchesWord(nameLower, awayNick);
            var bothNicks = homeNick.Length > 2 && awayNick.Length > 2 && homeNickMatch && awayNickMatch;
            var bothNames = (homeFull && awayFull) || (homeFull && awayNickMatch) || (awayFull && homeNickMatch);
            var homeRsn = IsTeamRsn(nameLower, homeCity, homeNick);
            var awayRsn = IsTeamRsn(nameLower, awayCity, awayNick);
            var hasHome = !conflicting && (homeFull || bothNicks || homeRsn ||
                (homeCityMatch && homeNickMatch) || (homeCityMatch && hasLeagueOrSport) ||
                (homeNickMatch && hasLeagueOrSport) || homeAbbrMatch);
            var hasAway = !conflicting && (awayFull || bothNicks || awayRsn ||
                (awayCityMatch && awayNickMatch) || (awayCityMatch && hasLeagueOrSport) ||
                (awayNickMatch && hasLeagueOrSport) || awayAbbrMatch);
            var bothTeams = !conflicting && (bothNicks || bothNames || (hasHome && hasAway));
            var package = leagueLower switch
            {
                "mlb" => nameLower.Contains("mlb extra") || nameLower.Contains("mlb ei") || (nameLower.Contains("mlb") && hasVs),
                "nba" => nameLower.Contains("nba league pass") || nameLower.Contains("nba lp") || (nameLower.Contains("nba") && hasVs),
                "nfl" => nameLower.Contains("sunday ticket") || nameLower.Contains("nfl st") || (nameLower.Contains("nfl") && hasVs),
                "nhl" => nameLower.Contains("center ice") || nameLower.Contains("nhl ci") || (nameLower.Contains("nhl") && hasVs),
                _ => false,
            } && (hasHome || hasAway);
            var single = (hasHome || hasAway) && (hasVs || hasLeagueOrSport || homeRsn || awayRsn);
            var direct = bothTeams || package || single;
            if (!(direct || official || IsSportsChannel(channel))) continue;

            float score;
            string? badge;
            if (bothTeams) { score = 100; badge = "Game Matchup"; }
            else if (package)
            {
                score = 96;
                var teamName = hasHome ? ev.HomeTeam?.Name : ev.AwayTeam?.Name;
                badge = teamName is not null ? $"{teamName} Live Feed" : "Live Game Feed";
            }
            else if (official && matchedStation is not null)
            {
                var niche = conflicting ||
                    (sportLower != "golf" && nameLower.Contains("golf")) ||
                    (sportLower != "tennis" && nameLower.Contains("tennis")) ||
                    (sportLower != "racing" && (nameLower.Contains("racing") || nameLower.Contains("f1") || nameLower.Contains("nascar")));
                if (niche) { score = 55; badge = $"Official Broadcast: {matchedStation}"; }
                else
                {
                    score = 90;
                    badge = $"Official Broadcast: {matchedStation}";
                    if (nameLower.Contains("sports") || nameLower.Contains("sport") || hasLeagueOrSport) score += 3;
                    if ((homeCity.Length > 3 && nameLower.Contains(homeCity)) ||
                        (awayCity.Length > 3 && nameLower.Contains(awayCity))) score += 2;
                }
            }
            else if (single)
            {
                score = 82;
                var teamName = hasHome ? ev.HomeTeam?.Name : ev.AwayTeam?.Name;
                badge = (homeRsn || awayRsn)
                    ? (teamName is not null ? $"{teamName} (RSN)" : "Regional Sports")
                    : (teamName is not null ? $"{teamName} Feed" : "Team Feed");
            }
            else
            {
                var dedicated = DedicatedLeagueChannel(nameLower, catLower, leagueLower);
                if (dedicated is not null) { score = 35; badge = dedicated; }
                else if (nameLower.Contains(leagueLower) || catLower.Contains(leagueLower)) { score = 25; badge = $"{ev.League} Channel"; }
                else if (IsMajorSportsNetwork(nameLower)) { score = 15; badge = "Sports Network"; }
                else { score = 5; badge = string.IsNullOrEmpty(channel.Category) ? "Sports" : channel.Category; }
            }

            var quality = Quality.Parse(channel.Name);
            if (quality.Is4K) score += 4;
            else if (quality.Resolution?.Contains("1080") == true) score += 1.5f;
            if (quality.Fps?.Contains("60") == true || quality.Fps?.Contains("50") == true) score += 2;
            if (nameLower.StartsWith("us") || nameLower.Contains("us |") || nameLower.Contains("us:") ||
                nameLower.StartsWith("ca") || nameLower.Contains("ca |") ||
                nameLower.StartsWith("uk") || nameLower.Contains("uk |")) score += 1;

            out_.Add(new RelevantChannel(channel, Math.Clamp(score, 0, 100), badge, official));
        }

        return out_.OrderByDescending(r => r.LikelihoodScore)
            .ThenBy(r => int.TryParse(r.Channel.Number, out var n) ? n : 99999)
            .ThenBy(r => r.Channel.Name).ToList();
    }

    internal static bool IsConflictingSport(string nameLower, string catLower, string leagueLower, string sportLower)
    {
        string[] nfl = ["mlb", "milb", "baseball", "nhl", "hockey", "nba", "wnba", "basketball", "cfl", "cricket", "golf", "tennis", "rugby", "afl", "motorsport", "f1", "nascar"];
        string[] nba = ["mlb", "milb", "baseball", "nhl", "hockey", "nfl", "football", "cfl", "cricket", "golf", "tennis", "rugby", "motorsport"];
        string[] mlb = ["nfl", "football", "nhl", "hockey", "nba", "wnba", "basketball", "cricket", "golf", "tennis", "rugby", "motorsport"];
        string[] nhl = ["nfl", "football", "mlb", "milb", "baseball", "nba", "wnba", "basketball", "cricket", "golf", "tennis", "rugby"];
        var conflicts = leagueLower switch
        {
            "nfl" => nfl, "nba" => nba, "mlb" => mlb, "nhl" => nhl,
            _ => sportLower switch
            {
                "football" => nfl, "basketball" => nba, "baseball" => mlb, "hockey" => nhl,
                _ => Array.Empty<string>(),
            },
        };
        return conflicts.Any(c => catLower.Contains(c) || MatchesWord(nameLower, c));
    }

    internal static bool IsSportsChannel(IptvChannel channel)
    {
        var cat = channel.Category.ToLowerInvariant();
        var name = channel.Name.ToLowerInvariant();
        string[] blacklist = ["news", "kids", "children", "cartoon", "movie", "movies", "cinema",
            "series", "vod", "music", "radio", "religious", "islam", "christian",
            "xxx", "adult", "for adult", "docu", "documentary", "shopping"];
        if (blacklist.Any(cat.Contains) && !IsMajorSportsNetwork(name)) return false;
        string[] sportsCats = ["sport", "espn", "football", "soccer", "futbol", "nfl", "nba", "mlb",
            "nhl", "basketball", "baseball", "hockey", "tennis", "golf", "racing",
            "f1", "formula", "nascar", "motogp", "motorsport", "fight", "mma",
            "ufc", "boxing", "wwe", "cricket", "rugby", "afl", "athletics",
            "olympic", "ppv", "live event", "events", "stadium"];
        return sportsCats.Any(cat.Contains) || IsMajorSportsNetwork(name);
    }

    internal static List<string> GetStationAliases(string station)
    {
        var s = station.ToLowerInvariant().Trim();
        var aliases = new List<string> { s };
        if (s.Contains("sec network") || s == "secn" || s == "sec") aliases.AddRange(["sec network", "secn", "sec net", "sec", "sec+"]);
        else if (s.Contains("acc network") || s == "accn" || s == "acc") aliases.AddRange(["acc network", "accn", "acc net", "acc", "accnx"]);
        else if (s.Contains("big ten") || s.Contains("btn")) aliases.AddRange(["big ten network", "big ten", "btn"]);
        else if (s.Contains("cbs sports network") || s == "cbssn" || s == "cbs sports") aliases.AddRange(["cbs sports network", "cbssn", "cbs sports net", "cbs sports"]);
        else if (s == "fs1" || s.Contains("fox sports 1")) aliases.AddRange(["fox sports 1", "fs1", "fs 1"]);
        else if (s == "fs2" || s.Contains("fox sports 2")) aliases.AddRange(["fox sports 2", "fs2", "fs 2"]);
        else if (s.Contains("espnu")) aliases.AddRange(["espnu", "espn u"]);
        else if (s.Contains("espn2") || s.Contains("espn 2")) aliases.AddRange(["espn2", "espn 2"]);
        else if (s.Contains("espn+") || s.Contains("espn plus")) aliases.AddRange(["espn+", "espn plus", "espnplus"]);
        else if (s.Contains("tnt")) aliases.AddRange(["tnt", "tnt sports"]);
        else if (s.Contains("tbs")) aliases.Add("tbs");
        else if (s.Contains("nbcsn") || s.Contains("nbc sports")) aliases.AddRange(["nbc sports", "nbcsn", "nbc sports net"]);
        else if (s.Contains("fanduel") || s.Contains("bally")) aliases.AddRange(["fanduel sports", "fanduel", "bally sports", "bally"]);
        return aliases.Distinct().ToList();
    }

    internal static bool IsMajorSportsNetwork(string nameLower)
    {
        string[] keys = ["sports", "sport", "espn", "fox sports", "fs1", "fs2", "nbcsn", "nbc sports",
            "cbs sports", "cbssn", "tnt sports", "sky sports", "bally", "fanduel", "yes network",
            "nesn", "masn", "marquee", "altitude", "sportsnet", "tsn", "bein", "dazn",
            "super sport", "optus", "nfl network", "nfl redzone", "nba tv", "mlb network",
            "nhl network", "sec network", "secn", "acc network", "accn", "big ten", "btn", "pac-12",
            "golf channel", "tennis channel", "fight network", "ufc", "boxnation", "wwe",
            "willow", "star sports", "sony ten", "abc", "cbs", "nbc", "fox", "tnt", "tbs",
            "trutv", "usa network", "peacock"];
        return keys.Any(nameLower.Contains);
    }

    internal static string? DedicatedLeagueChannel(string nameLower, string catLower, string leagueLower)
    {
        if (leagueLower == "nfl" && (nameLower.Contains("nfl network") || nameLower.Contains("nfl redzone") || nameLower.Contains("nfl sunday") || nameLower.Contains("nfl game pass") || catLower.Contains("nfl"))) return "NFL Network";
        if (leagueLower == "nba" && (nameLower.Contains("nba tv") || nameLower.Contains("nba league pass") || catLower.Contains("nba"))) return "NBA TV";
        if (leagueLower == "mlb" && (nameLower.Contains("mlb network") || nameLower.Contains("mlb extra") || catLower.Contains("mlb"))) return "MLB Network";
        if (leagueLower == "nhl" && (nameLower.Contains("nhl network") || nameLower.Contains("nhl center") || catLower.Contains("nhl"))) return "NHL Network";
        if ((leagueLower == "epl" || leagueLower.Contains("premier")) && (nameLower.Contains("premier league") || nameLower.Contains("sky sports pl") || nameLower.Contains("tnt sports") || nameLower.Contains("usa network"))) return "Premier League";
        if ((leagueLower == "ncaaf" || leagueLower == "ncaab") && (nameLower.Contains("sec network") || nameLower.Contains("acc network") || nameLower.Contains("big ten") || nameLower.Contains("btn"))) return "College Sports";
        return null;
    }

    internal static bool MatchesBroadcastStation(string channelNameLower, string stationLower)
    {
        if (stationLower.Length == 0) return false;
        var clean = stationLower.Replace(" network", "").Replace(" channel", "").Replace(" hd", "").Replace(" tv", "").Trim();
        if (clean.Length < 2) return false;
        var noDot = clean.Replace(".", "");
        var rx = StationRegex.GetOrAdd("station_" + clean, _ =>
            new Regex(@"(?:^|[\s|:_\-\[/])" + Regex.Escape(clean) + @"(?:$|[\s|:_\-\]\d/])", RegexOptions.IgnoreCase | RegexOptions.Compiled));
        if (rx.IsMatch(channelNameLower)) return true;
        if (noDot != clean)
        {
            var rx2 = StationRegex.GetOrAdd("station_nodot_" + noDot, _ =>
                new Regex(@"(?:^|[\s|:_\-\[/])" + Regex.Escape(noDot) + @"(?:$|[\s|:_\-\]\d/])", RegexOptions.IgnoreCase | RegexOptions.Compiled));
            if (rx2.IsMatch(channelNameLower)) return true;
        }
        return channelNameLower.Split(' ', '|', ':', '-', '_', '/')
            .Any(t => t.Trim().Equals(clean, StringComparison.OrdinalIgnoreCase) ||
                (noDot != clean && t.Trim().Equals(noDot, StringComparison.OrdinalIgnoreCase)));
    }

    internal static bool IsTeamRsn(string channelNameLower, string city, string nickname)
    {
        if (city.Length < 3 && nickname.Length < 3) return false;
        if ((city == "boston" || nickname.Contains("sox") || nickname == "bruins") && channelNameLower.Contains("nesn")) return true;
        if ((city == "baltimore" || city == "washington" || nickname == "orioles" || nickname == "nationals") && channelNameLower.Contains("masn")) return true;
        if ((city == "new york" || nickname == "yankees" || nickname == "nets") && (channelNameLower.Contains("yes network") || channelNameLower.Contains("yes hd"))) return true;
        if ((city == "new york" || nickname == "mets") && channelNameLower.Contains("sny")) return true;
        if ((city == "chicago" || nickname == "cubs") && channelNameLower.Contains("marquee")) return true;
        if ((city == "los angeles" || nickname == "dodgers" || nickname == "lakers") && (channelNameLower.Contains("sportsnet la") || channelNameLower.Contains("spectrum sports"))) return true;
        if ((city == "philadelphia" || nickname == "phillies" || nickname == "flyers" || nickname == "sixers") && channelNameLower.Contains("nbc") && channelNameLower.Contains("phil")) return true;
        if ((city == "detroit" || nickname == "tigers" || nickname == "pistons") && (channelNameLower.Contains("bally") || channelNameLower.Contains("fanduel")) && channelNameLower.Contains("det")) return true;
        if ((city == "denver" || city == "colorado" || nickname == "nuggets" || nickname == "avalanche") && channelNameLower.Contains("altitude")) return true;
        return false;
    }

    internal static bool MatchesWord(string text, string word)
    {
        var rx = WordRegex.GetOrAdd(word, _ =>
            new Regex(@"\b" + Regex.Escape(word) + @"\b", RegexOptions.IgnoreCase | RegexOptions.Compiled));
        return rx.IsMatch(text);
    }
}
