using System.Net.Http.Headers;
using System.Text.Json;

// ESPN scoreboard client. Base + league map mirror DataModule/EspnRepositoryImpl.
namespace Rally.Core;

public sealed class EspnClient(HttpClient http)
{
    public const string BaseUrl = "https://site.api.espn.com/apis/site/v2/";

    public static readonly (string League, string Sport, string Path)[] Leagues =
    [
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
    ];

    public async Task<List<SportEvent>> FetchAllAsync(int limit = 100, CancellationToken ct = default)
    {
        var tasks = Leagues.Select(l => FetchScoreboardAsync(l.Sport, l.Path, l.League, limit, ct));
        var results = await Task.WhenAll(tasks);
        return results.SelectMany(x => x).OrderBy(e => e.StartTime).ToList();
    }

    public async Task<List<SportEvent>> FetchScoreboardAsync(string sport, string league, string domainLeague, int limit = 100, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{BaseUrl}sports/{sport}/{league}/scoreboard?limit={limit}");
        req.Headers.UserAgent.ParseAdd("Rally/Windows");
        using var res = await http.SendAsync(req, ct);
        res.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        var events = new List<SportEvent>();
        if (!doc.RootElement.TryGetProperty("events", out var arr)) return events;
        foreach (var e in arr.EnumerateArray())
            events.Add(MapEvent(e, domainLeague, sport));
        return events;
    }

    private static SportEvent MapEvent(JsonElement e, string domainLeague, string sport)
    {
        var comp = e.GetPropertyOrNull("competitions")?.EnumerateArray().FirstOrDefault();
        Team? TeamOf(string homeAway)
        {
            var c = comp?.GetPropertyOrNull("competitors")?.EnumerateArray()
                .FirstOrDefault(x => x.GetPropertyOrNull("homeAway")?.GetString() == homeAway);
            var t = c?.GetPropertyOrNull("team");
            if (t is null) return null;
            return new Team(
                t.Value.GetPropertyOrNull("id")?.GetString() ?? Guid.NewGuid().ToString(),
                t.Value.GetPropertyOrNull("displayName")?.GetString() ?? t.Value.GetPropertyOrNull("name")?.GetString() ?? "?",
                t.Value.GetPropertyOrNull("abbreviation")?.GetString() ?? "?",
                t.Value.GetPropertyOrNull("logo")?.GetString());
        }
        int? ScoreOf(string homeAway)
        {
            var c = comp?.GetPropertyOrNull("competitors")?.EnumerateArray()
                .FirstOrDefault(x => x.GetPropertyOrNull("homeAway")?.GetString() == homeAway);
            var s = c?.GetPropertyOrNull("score")?.GetString();
            return int.TryParse(s, out var n) ? n : null;
        }
        var type = comp?.GetPropertyOrNull("status")?.GetPropertyOrNull("type");
        var state = type?.GetPropertyOrNull("state")?.GetString()?.ToLowerInvariant() ?? "";
        var name = type?.GetPropertyOrNull("name")?.GetString()?.ToLowerInvariant() ?? "";
        var completed = type?.GetPropertyOrNull("completed")?.GetBoolean() ?? false;
        var status = completed || state == "post" ? EventStatus.Finished
            : name.Contains("half") ? EventStatus.Halftime
            : state == "in" ? EventStatus.Live : EventStatus.NotStarted;
        var start = e.GetPropertyOrNull("date")?.GetString() is string d && DateTimeOffset.TryParse(d, out var dt)
            ? dt : DateTimeOffset.UtcNow;
        return new SportEvent(
            e.GetPropertyOrNull("id")?.GetString() ?? Guid.NewGuid().ToString(),
            e.GetPropertyOrNull("name")?.GetString() ?? e.GetPropertyOrNull("shortName")?.GetString() ?? "Game",
            TeamOf("home"), TeamOf("away"), start, status,
            ScoreOf("home"), ScoreOf("away"), sport, domainLeague,
            comp?.GetPropertyOrNull("venue")?.GetPropertyOrNull("fullName")?.GetString(),
            type?.GetPropertyOrNull("shortDetail")?.GetString() ?? type?.GetPropertyOrNull("detail")?.GetString());
    }
}

internal static class JsonExt
{
    public static JsonElement? GetPropertyOrNull(this JsonElement el, string name) =>
        el.ValueKind == JsonValueKind.Object && el.TryGetProperty(name, out var v) ? v : null;
}
