using System.Text.Json;

// Per-game summary, standings, roster, and injury endpoints. Mirrors the
// getSummary enrichment + getTeamHub/getLeagueHub sources in EspnRepositoryImpl
// (see appleApp EspnClient.fetchSummary for the summary shape).
namespace Rally.Core;

public sealed class EspnDetail(HttpClient http)
{
    public async Task<GameDetail> FetchSummaryAsync(string sport, string league, string eventId,
        string? awayAbbr = null, string? homeAbbr = null, CancellationToken ct = default)
    {
        JsonDocument doc;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"{EspnClient.BaseUrl}sports/{sport}/{league}/summary?event={Uri.EscapeDataString(eventId)}");
            req.Headers.UserAgent.ParseAdd("Rally/Windows");
            using var res = await http.SendAsync(req, ct).ConfigureAwait(false);
            res.EnsureSuccessStatusCode();
            doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
        }
        catch { return GameDetail.Empty; }
        using (doc) return ParseSummary(doc.RootElement, awayAbbr, homeAbbr);
    }

    internal static GameDetail ParseSummary(JsonElement root, string? awayAbbr, string? homeAbbr)
    {
        var leaders = new List<PlayerLeader>();
        if (root.GetPropertyOrNull("leaders") is JsonElement leaderGroups && leaderGroups.ValueKind == JsonValueKind.Array)
        {
            foreach (var group in leaderGroups.EnumerateArray())
            {
                var team = group.GetPropertyOrNull("team");
                foreach (var cat in group.GetPropertyOrNull("leaders")?.EnumerateArray() ?? [])
                {
                    var top = cat.GetPropertyOrNull("leaders")?.EnumerateArray().FirstOrDefault();
                    var athlete = top?.GetPropertyOrNull("athlete");
                    var shortName = athlete?.GetPropertyOrNull("shortName")?.GetString()
                        ?? athlete?.GetPropertyOrNull("displayName")?.GetString();
                    if (string.IsNullOrWhiteSpace(shortName)) continue;
                    leaders.Add(new PlayerLeader(
                        cat.GetPropertyOrNull("displayName")?.GetString() ?? cat.GetPropertyOrNull("name")?.GetString() ?? "Leader",
                        team?.GetPropertyOrNull("abbreviation")?.GetString(),
                        team?.GetPropertyOrNull("logo")?.GetString(),
                        shortName, top?.GetPropertyOrNull("displayValue")?.GetString() ?? "",
                        athlete?.GetPropertyOrNull("position")?.GetPropertyOrNull("abbreviation")?.GetString(),
                        athlete?.GetPropertyOrNull("headshot")?.GetPropertyOrNull("href")?.GetString()));
                }
            }
        }
        var clips = new List<HighlightClip>();
        var seen = new HashSet<string>();
        if (root.GetPropertyOrNull("videos") is JsonElement videos && videos.ValueKind == JsonValueKind.Array)
        {
            foreach (var v in videos.EnumerateArray())
            {
                var title = v.GetPropertyOrNull("headline")?.GetString()?.Trim();
                if (string.IsNullOrEmpty(title)) continue;
                var links = v.GetPropertyOrNull("links");
                var src = links?.GetPropertyOrNull("source");
                var url = src?.GetPropertyOrNull("HLS")?.GetPropertyOrNull("HD")?.GetPropertyOrNull("href")?.GetString()
                    ?? src?.GetPropertyOrNull("HLS")?.GetPropertyOrNull("href")?.GetString()
                    ?? src?.GetPropertyOrNull("HD")?.GetPropertyOrNull("href")?.GetString()
                    ?? src?.GetPropertyOrNull("href")?.GetString()
                    ?? links?.GetPropertyOrNull("mobile")?.GetPropertyOrNull("source")?.GetPropertyOrNull("href")?.GetString();
                var id = v.GetPropertyOrNull("id")?.GetRawText() ?? title;
                if (!seen.Add(id)) continue;
                int? dur = v.GetPropertyOrNull("duration")?.TryGetInt32(out var d) == true ? d : null;
                clips.Add(new HighlightClip(id, title, v.GetPropertyOrNull("description")?.GetString()?.Trim(),
                    dur, v.GetPropertyOrNull("thumbnail")?.GetString(), url,
                    links?.GetPropertyOrNull("web")?.GetPropertyOrNull("href")?.GetString()));
            }
        }
        var tables = new List<PlayerStatTable>();
        foreach (var group in root.GetPropertyOrNull("boxscore")?.GetPropertyOrNull("players")?.EnumerateArray() ?? [])
        {
            foreach (var cat in group.GetPropertyOrNull("statistics")?.EnumerateArray() ?? [])
            {
                var rows = new List<PlayerStatRow>();
                foreach (var item in cat.GetPropertyOrNull("athletes")?.EnumerateArray() ?? [])
                {
                    var a = item.GetPropertyOrNull("athlete");
                    var name = a?.GetPropertyOrNull("displayName")?.GetString()
                        ?? a?.GetPropertyOrNull("shortName")?.GetString();
                    if (string.IsNullOrWhiteSpace(name)) continue;
                    rows.Add(new PlayerStatRow(name,
                        a?.GetPropertyOrNull("shortName")?.GetString(),
                        a?.GetPropertyOrNull("headshot")?.GetPropertyOrNull("href")?.GetString(),
                        a?.GetPropertyOrNull("jersey")?.GetString(),
                        a?.GetPropertyOrNull("position")?.GetPropertyOrNull("abbreviation")?.GetString(),
                        item.GetPropertyOrNull("stats")?.EnumerateArray().Select(x => x.GetString() ?? x.GetRawText()).ToList()));
                }
                if (rows.Count == 0) continue;
                var team = group.GetPropertyOrNull("team");
                tables.Add(new PlayerStatTable(team?.GetPropertyOrNull("id")?.GetString(),
                    team?.GetPropertyOrNull("displayName")?.GetString() ?? team?.GetPropertyOrNull("name")?.GetString() ?? "",
                    team?.GetPropertyOrNull("abbreviation")?.GetString() ?? "",
                    team?.GetPropertyOrNull("logo")?.GetString(), cat.GetPropertyOrNull("name")?.GetString(),
                    cat.GetPropertyOrNull("labels")?.EnumerateArray().Select(x => x.GetString() ?? "").ToList(), rows));
            }
        }
        var comparisons = new List<TeamStatComparison>();
        {
            var teams = root.GetPropertyOrNull("boxscore")?.GetPropertyOrNull("teams")?.EnumerateArray().ToList() ?? [];
            if (teams.Count >= 2)
            {
                static List<JsonElement> StatsFor(List<JsonElement> ts, string? abbr)
                {
                    var t = !string.IsNullOrEmpty(abbr)
                        ? ts.FirstOrDefault(x => x.GetPropertyOrNull("team")?.GetPropertyOrNull("abbreviation")?.GetString()
                            ?.Equals(abbr, StringComparison.OrdinalIgnoreCase) == true)
                        : default;
                    var stats = (t.ValueKind == JsonValueKind.Object ? t : ts.FirstOrDefault())
                        .GetPropertyOrNull("statistics")?.EnumerateArray().ToList();
                    return stats ?? [];
                }
                var awayStats = StatsFor(teams, awayAbbr);
                var homeStats = StatsFor(teams, homeAbbr);
                if (awayStats.Count == 0 || homeStats.Count == 0)
                {
                    awayStats = teams[0].GetPropertyOrNull("statistics")?.EnumerateArray().ToList() ?? [];
                    homeStats = teams[1].GetPropertyOrNull("statistics")?.EnumerateArray().ToList() ?? [];
                }
                string Key(JsonElement s) => s.GetPropertyOrNull("label")?.GetString() ?? s.GetPropertyOrNull("name")?.GetString() ?? "";
                var keys = awayStats.Concat(homeStats).Select(Key).Where(k => k.Length > 0).Distinct().ToList();
                foreach (var key in keys)
                {
                    var a = awayStats.FirstOrDefault(s => Key(s) == key).GetPropertyOrNull("displayValue")?.GetString();
                    var h = homeStats.FirstOrDefault(s => Key(s) == key).GetPropertyOrNull("displayValue")?.GetString();
                    if (a is not null && h is not null) comparisons.Add(new TeamStatComparison(key, a, h));
                }
            }
        }
        var broadcasts = new List<string>();
        foreach (var b in root.GetPropertyOrNull("broadcasts")?.EnumerateArray() ?? [])
        {
            foreach (var n in b.GetPropertyOrNull("names")?.EnumerateArray() ?? [])
                if (n.GetString() is string s && s.Length > 0) broadcasts.Add(s);
            var media = b.GetPropertyOrNull("media")?.GetPropertyOrNull("shortName")?.GetString();
            if (!string.IsNullOrEmpty(media)) broadcasts.Add(media);
        }
        return new GameDetail(leaders, clips, tables, comparisons, broadcasts.Distinct().ToList());
    }

    public async Task<List<StandingRow>> FetchStandingsAsync(string sport, string league, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"https://site.api.espn.com/apis/v2/sports/{sport}/{league}/standings");
            req.Headers.UserAgent.ParseAdd("Rally/Windows");
            using var res = await http.SendAsync(req, ct).ConfigureAwait(false);
            res.EnsureSuccessStatusCode();
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            return ParseStandings(doc.RootElement);
        }
        catch { return []; }
    }

    internal static List<StandingRow> ParseStandings(JsonElement root)
    {
        var out_ = new List<StandingRow>();
        foreach (var child in root.GetPropertyOrNull("children")?.EnumerateArray() ?? [])
        {
            var groups = child.ValueKind == JsonValueKind.Object && child.TryGetProperty("standings", out var s)
                ? new[] { s } : [child];
            foreach (var g in groups)
            {
                foreach (var e in g.GetPropertyOrNull("entries")?.EnumerateArray() ?? [])
                {
                    var team = e.GetPropertyOrNull("team");
                    int? Stat(string name) => e.GetPropertyOrNull("stats")?.EnumerateArray()
                        .FirstOrDefault(x => x.GetPropertyOrNull("name")?.GetString() == name)
                        .GetPropertyOrNull("value")?.TryGetInt32(out var v) == true ? v : null;
                    string? StrStat(string name) => e.GetPropertyOrNull("stats")?.EnumerateArray()
                        .FirstOrDefault(x => x.GetPropertyOrNull("name")?.GetString() == name)
                        .GetPropertyOrNull("displayValue")?.GetString();
                    out_.Add(new StandingRow(
                        team?.GetPropertyOrNull("id")?.GetString() ?? "",
                        team?.GetPropertyOrNull("displayName")?.GetString() ?? "?",
                        team?.GetPropertyOrNull("abbreviation")?.GetString() ?? "?",
                        team?.GetPropertyOrNull("logo")?.GetString(),
                        Stat("wins") ?? 0, Stat("losses") ?? 0, Stat("ties"),
                        StrStat("winPercent") ?? StrStat("pct"), StrStat("gamesBehind") ?? StrStat("gb")));
                }
            }
        }
        return out_.DistinctBy(r => r.TeamId).ToList();
    }

    public async Task<List<RosterPlayer>> FetchTeamRosterAsync(string sport, string league, string teamId, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/teams/{Uri.EscapeDataString(teamId)}/roster");
            req.Headers.UserAgent.ParseAdd("Rally/Windows");
            using var res = await http.SendAsync(req, ct).ConfigureAwait(false);
            res.EnsureSuccessStatusCode();
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            var out_ = new List<RosterPlayer>();
            foreach (var a in doc.RootElement.GetPropertyOrNull("athletes")?.EnumerateArray() ?? [])
            {
                var name = a.GetPropertyOrNull("displayName")?.GetString();
                if (string.IsNullOrWhiteSpace(name)) continue;
                out_.Add(new RosterPlayer(a.GetPropertyOrNull("id")?.GetString() ?? name, name,
                    a.GetPropertyOrNull("shortName")?.GetString(),
                    a.GetPropertyOrNull("position")?.GetPropertyOrNull("abbreviation")?.GetString(),
                    a.GetPropertyOrNull("jersey")?.GetString(),
                    a.GetPropertyOrNull("headshot")?.GetPropertyOrNull("href")?.GetString()));
            }
            return out_;
        }
        catch { return []; }
    }

    public async Task<List<InjuryEntry>> FetchTeamInjuriesAsync(string sport, string league, string teamId, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/teams/{Uri.EscapeDataString(teamId)}/injuries");
            req.Headers.UserAgent.ParseAdd("Rally/Windows");
            using var res = await http.SendAsync(req, ct).ConfigureAwait(false);
            res.EnsureSuccessStatusCode();
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            var out_ = new List<InjuryEntry>();
            foreach (var i in doc.RootElement.GetPropertyOrNull("injuries")?.EnumerateArray() ?? [])
            {
                var athlete = i.GetPropertyOrNull("athlete");
                var name = athlete?.GetPropertyOrNull("displayName")?.GetString();
                if (string.IsNullOrWhiteSpace(name)) continue;
                out_.Add(new InjuryEntry(name,
                    athlete?.GetPropertyOrNull("position")?.GetPropertyOrNull("abbreviation")?.GetString(),
                    i.GetPropertyOrNull("status")?.GetString(),
                    i.GetPropertyOrNull("details")?.GetString() ?? i.GetPropertyOrNull("shortComment")?.GetString()));
            }
            return out_;
        }
        catch { return []; }
    }
}

internal static class EspnDetailExt
{
    internal static int? TryGetInt32(this JsonElement? el, out int value)
    {
        value = 0;
        if (el is null) return null;
        var e = el.Value;
        if (e.ValueKind == JsonValueKind.Number && e.TryGetInt32(out value)) return value;
        if (e.ValueKind == JsonValueKind.String && int.TryParse(e.GetString(), out value)) return value;
        return null;
    }
}
