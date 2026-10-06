#if DEBUG
using System.Net;
using System.Text.Json;
namespace Rally.App.Testing;

/// <summary>Opt-in, isolated screenshot data. Never used by a release build.</summary>
internal sealed class FixtureHandler : HttpMessageHandler
{
    public static bool NoLive;
    public static readonly string VideoUrl = Environment.GetCommandLineArgs().FirstOrDefault(arg => arg.StartsWith("--qa-stream="))?["--qa-stream=".Length..] ?? "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8";
    private readonly HttpClient _real = new() { Timeout = TimeSpan.FromSeconds(18) };
    private static object Team(string id, string name, string abbreviation, string color, string sport = "nfl") => new { id, displayName = name, abbreviation, color, logo = $"https://a.espncdn.com/i/teamlogos/{sport}/500/{(sport == "ncaa" ? id : abbreviation.ToLowerInvariant())}.png" };
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var path = request.RequestUri!.AbsolutePath;
        object result;
        if (request.RequestUri.Host == "fixture.rally.test")
        {
            if (path.EndsWith("manifest.json")) result = new { id = "rally.qa", version = "1.0.0", name = "Rally QA", resources = new[] { "catalog", "stream" }, types = new[] { "tv" }, catalogs = new[] { new { id = "sports", type = "tv" } } };
            else if (path.Contains("/catalog/")) result = new { metas = new[] {
                new { id = "chiefs-ravens", name = "Kansas City Chiefs vs Baltimore Ravens", type = "tv" },
                new { id = "lakers-celtics", name = "Lakers vs Celtics", type = "tv" },
                new { id = "yankees-redsox", name = "Yankees vs Red Sox", type = "tv" },
                new { id = "thunder-timberwolves", name = "Thunder vs Timberwolves", type = "tv" },
                new { id = "avalanche-stars", name = "Avalanche vs Stars", type = "tv" },
                new { id = "georgia-texas", name = "Georgia vs Texas", type = "tv" },
                new { id = "dodgers-padres", name = "Dodgers vs Padres", type = "tv" } } };
            else result = new { streams = new[] { new { name = "Public HLS test", url = VideoUrl } } };
        }
        else if (path.Contains("/scoreboard"))
        {
            var nfl = path.Contains("/nfl/"); var nba = path.Contains("/nba/"); var mlb = path.Contains("/mlb/"); var nhl = path.Contains("/nhl/"); var college = path.Contains("/college-football/");
            var events = new List<object>();
            object Game(string id, string name, object away, object home, int a, int h, string detail, bool live, int minutes) => new { id, name, date = DateTimeOffset.Now.AddMinutes(minutes).ToString("O"), competitions = new[] { new { status = new { type = new { state = live ? (NoLive ? "post" : "in") : "pre", name = live ? (NoLive ? "STATUS_FINAL" : "STATUS_IN_PROGRESS") : "STATUS_SCHEDULED", completed = live && NoLive, shortDetail = detail } }, competitors = new[] { new { team = away, homeAway = "away", score = a.ToString() }, new { team = home, homeAway = "home", score = h.ToString() } }, venue = new { fullName = "M&T Bank Stadium" } } } };
            if (nfl) events.Add(Game("qa-nfl", "Kansas City Chiefs vs Baltimore Ravens", Team("12", "Chiefs", "KC", "E31837"), Team("33", "Ravens", "BAL", "241773"), 24, 20, "4th · 3:42", true, -120));
            if (nba) { events.Add(Game("qa-nba", "Lakers vs Celtics", Team("13", "Lakers", "LAL", "FDB927", "nba"), Team("2", "Celtics", "BOS", "007A33", "nba"), 98, 95, "4th · 2:14", true, -90)); events.Add(Game("qa-soon-nba", "Thunder vs Timberwolves", Team("25", "Thunder", "OKC", "007AC1", "nba"), Team("16", "Timberwolves", "MIN", "0C2340", "nba"), 0, 0, "7:00 PM", false, 60)); }
            if (mlb) { events.Add(Game("qa-mlb", "Yankees vs Red Sox", Team("10", "Yankees", "NYY", "003087", "mlb"), Team("2", "Red Sox", "BOS", "BD3039", "mlb"), 3, 2, "Top 6th", true, -60)); events.Add(Game("qa-soon-mlb", "Dodgers vs Padres", Team("19", "Dodgers", "LAD", "005A9C", "mlb"), Team("25", "Padres", "SD", "2F241D", "mlb"), 0, 0, "9:00 PM", false, 180)); }
            if (nhl) events.Add(Game("qa-soon-nhl", "Avalanche vs Stars", Team("17", "Avalanche", "COL", "6F263D", "nhl"), Team("9", "Stars", "DAL", "006847", "nhl"), 0, 0, "7:30 PM", false, 90));
            if (college) events.Add(Game("qa-soon-college", "Georgia vs Texas", Team("61", "Georgia", "UGA", "BA0C2F", "ncaa"), Team("251", "Texas", "TEX", "BF5700", "ncaa"), 0, 0, "8:15 PM", false, 135));
            result = new { events };
        }
        else if (path.EndsWith("summary"))
        {
            var kc = Team("12", "Chiefs", "KC", "E31837"); var bal = Team("33", "Ravens", "BAL", "241773");
            object Athlete(string id, string name, string pos, string jersey) => new { id, displayName = name, shortName = name, position = new { abbreviation = pos }, jersey, headshot = new { href = $"https://a.espncdn.com/i/headshots/nfl/players/full/{id}.png" } };
            var mahomes = Athlete("3139477", "P. Mahomes", "QB", "15"); var jackson = Athlete("3916387", "L. Jackson", "QB", "8");
            object Stats(object team, object player, string yards) => new { team, statistics = new[] { new { name = "passing", labels = new[] { "C/ATT", "YDS", "TD", "INT" }, athletes = new[] { new { athlete = player, stats = new[] { "24/31", yards, "2", "0" } } } } } };
            object Leaders(object team, object athlete, string value) => new { team, leaders = new[] { new { displayName = "Pass Yds", leaders = new[] { new { athlete, displayValue = value } } } } };
            object TeamStats(object team, string yards) => new { team, statistics = new[] { new { label = "Total Yards", displayValue = yards }, new { label = "First Downs", displayValue = "24" }, new { label = "3rd Down", displayValue = "6 / 10" }, new { label = "Turnovers", displayValue = "1" } } };
            result = new { leaders = new[] { Leaders(kc, mahomes, "284"), Leaders(bal, jackson, "246") }, boxscore = new { players = new[] { Stats(kc, mahomes, "284"), Stats(bal, jackson, "246") }, teams = new[] { TeamStats(kc, "382"), TeamStats(bal, "355") } },
                plays = new[] { new { id = "p2", text = "Mahomes rolls right and passes to Rice for 24 yards.", sequenceNumber = "2", scoringPlay = false, period = new { number = 4 }, clock = new { displayValue = "3:42" } }, new { id = "p1", text = "Kelce catches a touchdown pass.", sequenceNumber = "1", scoringPlay = true, period = new { number = 4 }, clock = new { displayValue = "11:03" } } },
                gameInfo = new { venue = new { fullName = "M&T Bank Stadium", address = new { city = "Baltimore", state = "MD" }, images = new[] { new { href = "https://a.espncdn.com/i/venues/nfl/day/interior/3814.jpg" } } } }, predictor = new { homeTeam = new { winPercent = "46" } },
                videos = new[] { new { id = "clip-" + request.RequestUri.Query, headline = "Mahomes 24-yard pass to Rice", duration = 42, thumbnail = "https://a.espncdn.com/i/teamlogos/nfl/500/kc.png", links = new { source = new { href = VideoUrl } } } } };
        }
        else if (path.Contains("/teams")) result = new { sports = new[] { new { leagues = new[] { new { teams = new[] { new { team = Team("12", "Chiefs", "KC", "E31837") }, new { team = Team("33", "Ravens", "BAL", "241773") } } } } } } };
        else if (path.Contains("/standings")) result = new { children = Array.Empty<object>() };
        else
        {
            using var forwarded = new HttpRequestMessage(request.Method, request.RequestUri);
            foreach (var header in request.Headers) forwarded.Headers.TryAddWithoutValidation(header.Key, header.Value);
            return await _real.SendAsync(forwarded, cancellationToken);
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(result), System.Text.Encoding.UTF8, "application/json") };
    }
}
#endif
