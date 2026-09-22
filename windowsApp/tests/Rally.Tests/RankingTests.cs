using System.Net;
using System.Text;
using System.Text.Json;
using Rally.Core;

namespace Rally.Tests;

public sealed class RankingTests
{
    private static SportEvent Nfl() => new("e1", "DAL @ PHI",
        new Team("1", "Dallas Cowboys", "DAL"), new Team("2", "Philadelphia Eagles", "PHI"),
        DateTimeOffset.UtcNow, EventStatus.NotStarted, null, null, "football", "NFL");

    private static PlayCandidate Cand(string url, PlayKind kind = PlayKind.Stremio, bool exact = true,
        int rank = 500, bool? preflight = null, float conf = 0, string title = "") =>
        new(Guid.NewGuid().ToString(), title.Length > 0 ? title : url, url, null, kind, exact, rank,
            null, null, preflight, null, null, conf, null);

    [Fact]
    public void SortDemotesFailedPreflight()
    {
        var sorted = StreamResolver.Sort([
            Cand("https://cdn/failed.m3u8", preflight: false),
            Cand("https://cdn/unknown.m3u8", preflight: null),
            Cand("https://cdn/ok.m3u8", preflight: true)]);
        Assert.Equal(["https://cdn/ok.m3u8", "https://cdn/unknown.m3u8", "https://cdn/failed.m3u8"],
            sorted.Select(c => c.Url));
    }

    [Fact]
    public void SortBlendsHealthAndStremioFirst()
    {
        var sorted = StreamResolver.Sort([
            new PlayCandidate("1", "Flaky 1080p", "https://flaky/ch", null, PlayKind.Iptv, true, 500),
            new PlayCandidate("2", "Healthy 720p", "https://healthy/ch", null, PlayKind.Stremio, true, 300)],
            url => url == "https://flaky/ch" ? -240 : 0);
        Assert.Equal("Healthy 720p", sorted[0].Title);
        var tied = StreamResolver.Sort([
            new PlayCandidate("b", "B feed", "https://b", null, PlayKind.Stremio, true, 300),
            new PlayCandidate("a", "A feed", "https://a", null, PlayKind.Stremio, true, 300),
            new PlayCandidate("c", "C channel", "https://c", null, PlayKind.Iptv, true, 300)]);
        Assert.Equal(["A feed", "B feed", "C channel"], tied.Select(c => c.Title));
    }

    [Fact]
    public void PrimaryRequiresExactAndUnfailed()
    {
        var cands = StreamResolver.Sort([
            Cand("https://cdn/dead-exact.m3u8", preflight: false),
            Cand("https://cdn/live-exact.m3u8", preflight: null)]);
        Assert.Equal("https://cdn/live-exact.m3u8", StreamResolver.Primary(cands)?.Url);
        Assert.Null(StreamResolver.Primary([Cand("https://cdn/x", exact: false)]));
        Assert.Null(StreamResolver.Primary([Cand("https://cdn/y", preflight: false)]));
    }

    [Fact]
    public void DedupeAndCap()
    {
        var ev = Nfl();
        var opts = Enumerable.Range(0, 45)
            .Select(i => new StremioStreamOption($"Dallas Cowboys vs Philadelphia Eagles feed {i}", null, $"https://cdn/feed{i}.m3u8", "1080p", "Test"))
            .ToList();
        opts.Add(new StremioStreamOption("Dallas Cowboys vs Philadelphia Eagles duplicate", null, "https://cdn/feed0.m3u8", "1080p", "Test"));
        var cands = StreamResolver.Candidates(ev, [], opts);
        Assert.Equal(40, cands.Count);
        Assert.Equal(40, cands.Select(c => c.Url).Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    [Fact]
    public void RedZoneNeverExact()
    {
        var ev = Nfl();
        var channels = new List<IptvChannel>
        {
            new("1", "1", "NFL RedZone Dallas Cowboys vs Philadelphia Eagles", "Sports", null, "https://x/rz.m3u8"),
        };
        var cands = StreamResolver.Candidates(ev, channels, []);
        Assert.All(cands, c => Assert.False(c.ExactMatch));
    }

    [Fact]
    public void SanitizerAllowlist()
    {
        var clean = StreamRequestHeaders.Sanitize(new Dictionary<string, string>
        {
            ["User-Agent"] = "Rally/Windows",
            ["Cookie"] = "mac=00:11:22:33:44:55",
            ["Authorization"] = "Bearer abc",
            ["X-Custom"] = "drop me",
            ["Evil\nHeader"] = "x",
            ["User-Agent\r"] = "injected name",
            ["Referer"] = "ok\r\ninjected",
            ["Origin"] = "lone\rcr",
        });
        Assert.Equal(3, clean.Count);
        Assert.Equal("Rally/Windows", clean["User-Agent"]);
        Assert.Equal("Bearer abc", clean["Authorization"]);
        Assert.Empty(StreamRequestHeaders.Sanitize(null));
    }

    [Fact]
    public void BearerNormalization()
    {
        Assert.Equal("Bearer abc", StreamRequestHeaders.NormalizedBearerToken("abc"));
        Assert.Equal("Bearer abc", StreamRequestHeaders.NormalizedBearerToken("Bearer abc"));
        Assert.Equal("bearer abc", StreamRequestHeaders.NormalizedBearerToken("bearer abc"));
    }

    [Fact]
    public void VersionCompareChannels()
    {
        Assert.True(UpdateChecker.CompareVersions("v1.2.0", "1.1.0") > 0);
        Assert.Equal(0, UpdateChecker.CompareVersions("1.0.0", "1.0.0"));
        Assert.True(UpdateChecker.CompareVersions("1.0.0", "1.0.0-beta1") > 0);
        Assert.True(UpdateChecker.CompareVersions("1.0.0-rc2", "1.0.0-beta10") > 0);
        Assert.True(UpdateChecker.CompareVersions("1.0.0", "1.0.1") < 0);
    }

    [Fact]
    public void MatcherFixtures()
    {
        var dir = AppContext.BaseDirectory;
        string? path = null;
        for (var d = new DirectoryInfo(dir); d is not null; d = d.Parent)
        {
            var candidate = Path.Combine(d.FullName, "Fixtures", "matcher.json");
            if (File.Exists(candidate)) { path = candidate; break; }
            var alt = Path.Combine(d.FullName, "tests", "Rally.Tests", "Fixtures", "matcher.json");
            if (File.Exists(alt)) { path = alt; break; }
        }
        Assert.True(path is not null, "matcher.json fixture not found");
        using var doc = JsonDocument.Parse(File.ReadAllText(path!));
        foreach (var v in doc.RootElement.GetProperty("vectors").EnumerateArray())
        {
            var name = v.GetProperty("name").GetString() ?? "?";
            var league = v.GetProperty("league").GetString()!;
            var sport = v.GetProperty("sport").GetString()!;
            Team T(string key) => new("id-" + key, v.GetProperty(key).GetProperty("name").GetString()!,
                v.GetProperty(key).GetProperty("abbr").GetString()!);
            var ev = new SportEvent("e", $"{T("home").Abbreviation} @ {T("away").Abbreviation}",
                T("home"), T("away"), DateTimeOffset.UtcNow, EventStatus.NotStarted, null, null, sport, league);
            var ch = v.GetProperty("channel");
            var channel = new IptvChannel("c1", "1", ch.GetProperty("name").GetString()!,
                ch.GetProperty("category").GetString()!, null, "https://x/stream.m3u8");
            var stations = v.TryGetProperty("stations", out var st)
                ? st.EnumerateArray().Select(x => x.GetString()!).ToList() : new List<string>();
            var minScore = v.GetProperty("minScore").GetSingle();
            var included = v.GetProperty("included").GetBoolean();
            var results = EventMatcher.GetRelevantChannels(ev, [channel], stations);
            if (!included)
            {
                Assert.True(results.Count == 0, $"[{name}] expected exclusion, got score {results.FirstOrDefault()?.LikelihoodScore}");
                continue;
            }
            Assert.True(results.Count > 0, $"[{name}] expected inclusion");
            Assert.True(results[0].LikelihoodScore >= minScore,
                $"[{name}] score {results[0].LikelihoodScore} < {minScore}");
            if (v.TryGetProperty("badge", out var badge))
                Assert.Equal(badge.GetString(), results[0].MatchBadge);
        }
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(respond(request));
    }

    private static StreamPreflightProbe Probe(Func<HttpRequestMessage, HttpResponseMessage> respond) =>
        new(new HttpClient(new StubHandler(respond)) { Timeout = TimeSpan.FromSeconds(5) });

    private static HttpResponseMessage Msg(HttpStatusCode code, string? contentType = null)
    {
        var m = new HttpResponseMessage(code) { Content = new ByteArrayContent([]) };
        if (contentType is not null) m.Content.Headers.ContentType =
            new System.Net.Http.Headers.MediaTypeHeaderValue(contentType.Split(';')[0].Trim());
        return m;
    }

    [Fact]
    public async Task ProbeVideoHeadPasses()
    {
        var probe = Probe(_ => Msg(HttpStatusCode.OK, "application/vnd.apple.mpegurl"));
        var r = await probe.ProbeAsync("https://cdn/game.m3u8");
        Assert.True(r.Passed);
        Assert.Equal(200, r.StatusCode);
        Assert.Equal("Verified before playback", r.Detail);
    }

    [Fact]
    public async Task ProbeHtmlRejected()
    {
        var probe = Probe(_ => Msg(HttpStatusCode.OK, "text/html; charset=utf-8"));
        var r = await probe.ProbeAsync("https://cdn/watch");
        Assert.False(r.Passed);
        Assert.Equal("Received a web page instead of video", r.Detail);
    }

    [Fact]
    public async Task ProbeForbiddenFallsBackToRange()
    {
        var probe = Probe(req => req.Method == HttpMethod.Head
            ? Msg(HttpStatusCode.Forbidden)
            : Msg(HttpStatusCode.PartialContent, "video/mp2t"));
        var r = await probe.ProbeAsync("https://cdn/game.ts");
        Assert.True(r.Passed);
        Assert.Equal(206, r.StatusCode);
    }

    [Fact]
    public async Task ProbeNotFoundReturnedDirectly()
    {
        var probe = Probe(_ => Msg(HttpStatusCode.NotFound));
        var r = await probe.ProbeAsync("https://cdn/missing.m3u8");
        Assert.False(r.Passed);
        Assert.Equal("Server returned 404", r.Detail);
    }

    [Fact]
    public async Task ProbeNonHttpFailsWithoutNetwork()
    {
        var hits = 0;
        var probe = Probe(_ => { hits++; return Msg(HttpStatusCode.InternalServerError); });
        var r = await probe.ProbeAsync("plugin://unresolved");
        Assert.False(r.Passed);
        Assert.Equal("Provider link must be resolved first", r.Detail);
        Assert.Equal(0, hits);
    }
}
