using Rally.Core;

namespace Rally.Tests;

public sealed class QualityTests
{
    [Fact]
    public void EvidenceBasedLabels()
    {
        Assert.Equal("4K", Quality.Parse("ESPN 4K HDR").Resolution);
        Assert.True(Quality.Parse("ESPN 4K HDR").IsHdr);
        Assert.True(Quality.Parse("Sky 1080p 60fps").Is60Fps);
        var plain = Quality.Parse("Random Channel 12");
        Assert.Null(plain.Resolution);
        Assert.False(plain.IsHdr);
    }

    [Fact]
    public void RankOrdering()
    {
        Assert.True(StreamSelector.QualityRank(new StreamQualityInfo("4K", null, true, false, false)) >
                    StreamSelector.QualityRank(new StreamQualityInfo("1080p", null, false, false, false)));
        Assert.True(StreamSelector.QualityRank(new StreamQualityInfo("1080p", null, false, false, true)) >
                    StreamSelector.QualityRank(new StreamQualityInfo("1080p", null, false, false, false)));
    }
}

public sealed class MatcherTests
{
    private static readonly SportEvent Nfl = new("e1", "DAL @ PHI",
        new Team("1", "Dallas Cowboys", "DAL"), new Team("2", "Philadelphia Eagles", "PHI"),
        DateTimeOffset.UtcNow, EventStatus.NotStarted, null, null, "football", "NFL");

    [Fact]
    public void FullNameAndAbbrMatch()
    {
        Assert.True(StreamSelector.TextMatchesEvent("Dallas Cowboys vs Philadelphia Eagles 1080p", Nfl));
        Assert.True(StreamSelector.TextMatchesEvent("DAL vs PHI", Nfl));
        Assert.False(StreamSelector.TextMatchesEvent("Lakers vs Celtics", Nfl));
        Assert.False(StreamSelector.TextMatchesEvent("", Nfl));
    }
}

public sealed class NormalizerTests
{
    [Fact]
    public void Portal()
    {
        Assert.Equal("http://example.to:8080/c", UrlNormalizer.NormalizePortal("example.to:8080/c/server/load.php/"));
        Assert.Equal("https://host.tv/stalker_portal", UrlNormalizer.NormalizePortal("https://host.tv/stalker_portal"));
        Assert.Equal("", UrlNormalizer.NormalizePortal(""));
    }

    [Fact]
    public void Addon()
    {
        Assert.Equal("https://sports.highfly.to/manifest.json", UrlNormalizer.NormalizeAddon("sports.highfly.to"));
        Assert.Null(UrlNormalizer.NormalizeAddon("   "));
    }

    [Fact]
    public void Xtream()
    {
        Assert.Equal("http://line.tv:8080", UrlNormalizer.NormalizeXtreamServer("line.tv:8080/player_api.php"));
        Assert.Equal("", UrlNormalizer.NormalizeXtreamServer(""));
    }
}

public sealed class ProtocolTests
{
    [Fact]
    public void StalkerCleanUrlSinglePass()
    {
        Assert.Equal("http://x/7", StalkerClient.CleanStreamUrl("ffmpeg http://x/7"));
        Assert.Equal("ffrt http://x/7", StalkerClient.CleanStreamUrl("auto ffrt http://x/7"));
    }

    [Fact]
    public void StalkerGuideNowNext()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var doc = System.Text.Json.JsonDocument.Parse(
            $$"""{"data":[{"name":"Past","start_timestamp":"{{now - 7200}}","stop_timestamp":"{{now - 3600}}"},{"name":"Live Game","start_timestamp":"{{now - 100}}","stop_timestamp":"{{now + 3500}}"},{"name":"Up Next","start_timestamp":"{{now + 3500}}","stop_timestamp":"{{now + 7000}}"}]}""");
        var guide = StalkerClient.ParseGuide(doc.RootElement);
        Assert.Equal("Live Game", guide?.Now?.Title);
        Assert.Equal("Up Next", guide?.Next?.Title);
    }

    [Fact]
    public void XtreamUrls()
    {
        var a = new XtreamClient.Account("http://line.tv:8080", "u", "p");
        Assert.Equal("http://line.tv:8080/player_api.php?username=u&password=p", XtreamClient.PlayerApi(a));
        Assert.Equal("http://line.tv:8080/player_api.php?username=u&password=p&action=get_live_streams",
            XtreamClient.PlayerApi(a, "get_live_streams"));
        Assert.Equal("http://line.tv:8080/live/u/p/123.m3u8", XtreamClient.LiveStream(a, "123"));
    }

    [Fact]
    public void ResolverPrefersExact()
    {
        var home = new Team("1", "Dallas Cowboys", "DAL");
        var away = new Team("2", "Philadelphia Eagles", "PHI");
        var ev = new SportEvent("e1", "DAL @ PHI", home, away, DateTimeOffset.UtcNow, EventStatus.NotStarted, null, null, "football", "NFL");
        var opts = new List<StremioStreamOption>
        {
            new("Random 4K", null, "http://x/4k", "4K"),
            new("Dallas Cowboys vs Philadelphia Eagles 720p", null, "http://x/720", "720p"),
            new("Watch here", null, "http://x/page.html", null, null, null, false),
        };
        var cands = StreamResolver.Candidates(ev, [], opts);
        Assert.Equal(["http://x/720", "http://x/4k"], cands.Select(c => c.Url));
    }

    [Fact]
    public void HealthScore()
    {
        Assert.Equal(0, new StreamHealth().Score);
        Assert.Equal(23, new StreamHealth(Successes: 1, AverageStartupMs: 750).Score);
        Assert.Equal(-240, new StreamHealth(Failures: 10).Score);
    }

    [Fact]
    public void SettingsRoundTrip()
    {
        var dir = Path.Combine(Path.GetTempPath(), "RallyTests-" + Guid.NewGuid());
        var store = new SettingsStore(dir);
        Assert.Equal([SettingsStore.DefaultAddon], store.StremioAddonUrls);
        Assert.StartsWith("00:1A:79:", store.MacAddress);
        store.XtreamPassword = "secret";
        Assert.Equal("secret", new SettingsStore(dir).XtreamPassword);
        var team = new FavoriteTeam("1", "NFL", "Cowboys", "DAL");
        Assert.True(store.ToggleFavoriteTeam(team));
        Assert.True(new SettingsStore(dir).IsFavoriteTeam("1", "nfl"));
        Directory.Delete(dir, true);
    }
}
