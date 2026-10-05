using System.Text.Json;
using Rally.Core;
namespace Rally.Tests;

public sealed class WindowsParityTests
{
    [Fact]
    public void M3uHandlesQuotedNamesRelativeUrlsAndDuplicates()
    {
        var rows = M3uClient.Parse("""
#EXTM3U
#EXTINF:-1 tvg-id="nfl" tvg-name="Sports, US" group-title="Football" tvg-id="updated",NFL RedZone
live/redzone.m3u8
#EXTINF:-1,Duplicate
live/redzone.m3u8
#EXTINF:-1,Other
https://cdn.example/other.ts
""", new Uri("https://iptv.example/list/channels.m3u"));
        Assert.Equal(2, rows.Count); Assert.Equal("updated", rows[0].GuideId); Assert.Equal("Football", rows[0].Category); Assert.Equal("https://iptv.example/list/live/redzone.m3u8", rows[0].StreamUrl);
    }
    [Fact]
    public void HlsIsOneStreamRatherThanAListOfSegments()
    {
        var rows = M3uClient.Parse("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg.ts", new Uri("https://cdn.example/live.m3u8"));
        Assert.Single(rows); Assert.Equal("https://cdn.example/live.m3u8", rows[0].StreamUrl);
    }
    [Fact]
    public void XmltvUsesTimezoneAndSelectsNowAndNext()
    {
        var guide = M3uClient.ParseGuide("""
<tv><programme channel="x" start="20261003120000 -0400" stop="20261003130000 -0400"><title>Current</title></programme><programme channel="x" start="20261003130000 -0400" stop="20261003140000 -0400"><title>Next</title></programme></tv>
""", DateTimeOffset.Parse("2026-10-03T16:30:00Z"));
        Assert.Equal("Current", guide["x"].Now?.Title); Assert.Equal("Next", guide["x"].Next?.Title);
        Assert.ThrowsAny<Exception>(() => M3uClient.ParseGuide("<!DOCTYPE tv [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><tv>&x;</tv>", DateTimeOffset.Now));
    }
    [Fact]
    public void SettingsShareStateAndKeepCredentialsOutOfBackup()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var first = new SettingsStore(path); var second = new SettingsStore(path);
        first.M3uUrl = "https://example/secret?token=private"; second.ReducedMotion = true; first.StremioAddonUrls = [];
        Assert.True(first.ReducedMotion); Assert.Equal(first.M3uUrl, second.M3uUrl); Assert.Empty(second.StremioAddonUrls);
        Assert.DoesNotContain("private", first.ExportPreferences());
        Directory.Delete(path, true);
    }
    [Fact]
    public void FootballPlaysCombineDrivesAndScoringWithoutDuplicates()
    {
        using var doc = JsonDocument.Parse("""
{"plays":[{"id":"1","text":"Run","sequenceNumber":"10"}],"drives":{"current":{"plays":[{"id":"2","text":"Touchdown","sequenceNumber":"11"}]}},"scoringPlays":[{"id":"2","text":"Touchdown","sequenceNumber":"11"}]}
""");
        var plays = GameData.ParsePlays(doc.RootElement); Assert.Equal(2, plays.Count); Assert.Equal("2", plays[0].Id); Assert.True(plays[0].Scoring);
    }
    [Fact]
    public void PlayersMergeAcrossCategoriesButNotAcrossTeams()
    {
        var rows = new List<PlayerStatTable> {
            new("a", "Away", "A", null, "passing", ["YDS"], [new("Player", Stats: ["200"], Id: "1")]),
            new("a", "Away", "A", null, "rushing", ["YDS"], [new("Player", Stats: ["40"], Id: "1")]),
            new("b", "Home", "B", null, "passing", ["YDS"], [new("Player", Stats: ["250"], Id: "2")]) };
        var players = GamePlayers.Merge(rows); Assert.Equal(2, players.Count); Assert.Equal(2, players.First(p => p.TeamId == "a").Stats.Count);
    }
    [Fact]
    public void RedZoneAddsTodaysNflGamesAndDeduplicatesSelectedGames()
    {
        var now = DateTimeOffset.Now;
        var game = new SportEvent("1", "NFL", null, null, now, EventStatus.Live, 0, 0, "football", "NFL");
        var other = game with { Id = "2" }; var yesterday = game with { Id = "3", StartTime = now.AddDays(-1) };
        var games = GamePlayers.MultiViewGames([game, game], [game, other, yesterday], true, now);
        Assert.Equal(2, games.Count); Assert.DoesNotContain(games, e => e.Id == "3");
    }
    [Fact]
    public void StremioSchemeNormalizesWithoutLosingConfigurationQuery()
    {
        Assert.Equal("https://addon.example/config/manifest.json?token=a", UrlNormalizer.NormalizeAddon("stremio://addon.example/config?token=a#test"));
    }
}
