using System.Text.Json;
using Rally.Core;

namespace Rally.Tests;

public sealed class CacheTests
{
    private static string TempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), "RallyCache-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static SportEvent Ev(string id) => new(id, "Game", null, null,
        DateTimeOffset.UtcNow, EventStatus.NotStarted, null, null, "football", "NFL");

    private static IptvChannel Ch(string id) =>
        new(id, "1", "ESPN 1080p", "Sports", null, "https://x/1.m3u8");

    [Fact]
    public void DiskRoundTripAndExpiry()
    {
        var cache = new DiskCache(TempDir());
        cache.Save(new List<string> { "a", "b" }, "t.json");
        Assert.Equal(["a", "b"], cache.Load<List<string>>("t.json", TimeSpan.FromMinutes(1)));
        Assert.Null(cache.Load<List<string>>("t.json", TimeSpan.Zero));
        Assert.Null(cache.Load<List<string>>("missing.json", TimeSpan.FromMinutes(1)));
    }

    [Fact]
    public void DiskCorruptReadsNil()
    {
        var dir = TempDir();
        File.WriteAllText(Path.Combine(dir, "t.json"), "not json");
        Assert.Null(new DiskCache(dir).Load<List<string>>("t.json", TimeSpan.FromMinutes(1)));
    }

    [Fact]
    public void ScheduleSaveLoadFreshAndAny()
    {
        var store = new ScheduleStore(TempDir());
        Assert.Null(store.LoadFresh());
        Assert.Null(store.LoadAny());
        store.Save([Ev("e1")]);
        Assert.Single(store.LoadFresh()!);
        Assert.Single(store.LoadAny()!);
        store.Save([]);
        Assert.Single(store.LoadFresh()!);
    }

    [Fact]
    public void ChannelIdentityGating()
    {
        var store = new ChannelDiskStore(TempDir());
        store.Save([Ch("c1")], "portal|mac");
        Assert.Single(store.LoadFresh("portal|mac")!);
        Assert.Null(store.LoadFresh("other|mac"));
        Assert.Null(store.LoadAny("other|mac"));
    }

    [Fact]
    public void ChannelFileNameSanitized()
    {
        var name = ChannelDiskStore.FileName("https://host.tv:8080/c|00:1A:79:AA:BB:CC");
        Assert.DoesNotContain("/", name);
        Assert.DoesNotContain(":", name);
        Assert.StartsWith("channels-", name);
        Assert.EndsWith(".json", name);
    }

    [Fact]
    public void ParseTeamsCatalog()
    {
        using var doc = JsonDocument.Parse("""
            {"sports": [{"leagues": [{"teams": [
              {"team": {"id": "1", "displayName": "Dallas Cowboys", "abbreviation": "DAL",
                        "logos": [{"href": "https://x/dal.png"}]}},
              {"team": {"id": "2", "displayName": "Philadelphia Eagles", "abbreviation": "PHI"}}
            ]}]}]}
            """);
        var teams = EspnDetail.ParseTeams(doc.RootElement);
        Assert.Equal(2, teams.Count);
        Assert.Equal("Dallas Cowboys", teams[0].Name);
        Assert.Equal("https://x/dal.png", teams[0].LogoUrl);
        Assert.Null(teams[1].LogoUrl);
    }

    [Fact]
    public void ParseTeamsEmptyOnGarbage()
    {
        using var doc = JsonDocument.Parse("{}");
        Assert.Empty(EspnDetail.ParseTeams(doc.RootElement));
    }
}
