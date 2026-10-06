using System.Net;
using System.Text.Json;
using Rally.Core;
using Xunit;

namespace Rally.Tests;
public sealed class RescueFoundationTests
{
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => respond(request, ct); }
    private static HttpResponseMessage Json(string value) => new(HttpStatusCode.OK) { Content = new StringContent(value) };
    [Fact]
    public async Task DetailRequestsCoalesceAndOneCanceledWaiterDoesNotCancelOthers()
    {
        var entered = new TaskCompletionSource(); var release = new TaskCompletionSource(); var calls = 0;
        var http = new HttpClient(new Handler(async (_, ct) => { Interlocked.Increment(ref calls); entered.SetResult(); await release.Task.WaitAsync(ct); return Json("{}"); }));
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var data = new RallyRepository(new SettingsStore(folder), http);
        var game = new SportEvent("123", "Game", null, null, DateTimeOffset.Now, EventStatus.Live, null, null, "football", "NFL");
        using var cancel = new CancellationTokenSource();
        var first = data.DetailAsync(game, ct: cancel.Token); await entered.Task;
        var second = data.DetailAsync(game); cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        release.SetResult(); await second; await data.DetailAsync(game);
        Assert.Equal(1, calls);
    }
    [Fact]
    public async Task FailedSummaryIsNotCachedAsAnEmptySuccessfulGame()
    {
        var calls = 0;
        var data = new RallyRepository(new SettingsStore(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString())), new HttpClient(new Handler((_, _) => Task.FromResult(++calls == 1 ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) : Json("{}")))));
        var game = new SportEvent("123", "Game", null, null, DateTimeOffset.Now, EventStatus.Live, null, null, "football", "NFL");
        await Assert.ThrowsAsync<HttpRequestException>(() => data.DetailAsync(game)); await data.DetailAsync(game); Assert.Equal(2, calls);
    }
    [Fact]
    public void GroupedFootballRosterIncludesEveryPositionAndDeduplicatesPlayers()
    {
        using var doc = JsonDocument.Parse("""{"athletes":[{"position":"offense","items":[{"id":"1","displayName":"Quarterback","position":{"abbreviation":"QB"}},{"id":"2","displayName":"Receiver"}]},{"position":"defense","items":[{"id":"3","displayName":"Safety"},{"id":"1","displayName":"Quarterback"}]}]}""");
        var players = EspnDetail.ParseRoster(doc.RootElement); Assert.Equal(3, players.Count); Assert.Equal("QB", players[0].Position);
    }
    [Fact]
    public void LineupsKeepReportedStarterStatusSeparateFromUnknownStatus()
    {
        using var doc = JsonDocument.Parse("""{"rosters":[{"team":{"id":"1","displayName":"Club"},"roster":[{"starter":true,"athlete":{"id":"a","displayName":"Starter"}},{"athlete":{"id":"b","displayName":"Reserve"}}]}]}""");
        var lineup = Assert.Single(EspnDetail.ParseLineups(doc.RootElement)); Assert.True(lineup.Players[0].Starter); Assert.Null(lineup.Players[1].Starter);
    }
    [Fact]
    public void ManifestPublishesRealQualitiesAndDistinguishesLiveFromVod()
    {
        var master = PlaybackManifest.Parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\nhigh.m3u8", new Uri("https://example.test/path/master.m3u8"));
        Assert.Equal(new[] { 720, 360 }, master.Qualities.Select(q => q.Height)); Assert.Equal(800000, master.Qualities.Last().Bandwidth); Assert.Null(master.IsLive); Assert.Equal("https://example.test/path/low.m3u8", master.MediaPlaylist!.AbsoluteUri);
        Assert.True(PlaybackManifest.Parse("#EXTM3U\n#EXTINF:6,\nseg.ts", new Uri("https://example.test/live.m3u8")).IsLive);
        Assert.False(PlaybackManifest.Parse("#EXTM3U\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST", new Uri("https://example.test/vod.m3u8")).IsLive);
    }
    [Fact]
    public void LiveSeekRequiresAReportedWindowAndClampsToPlayableEdge()
    {
        Assert.False(PlaybackTimeline.Create(true, true, 10_000, 0).CanSeek);
        var expired = PlaybackTimeline.Create(true, true, 103_000, 80_000);
        Assert.False(expired.CanSeek); Assert.False(expired.AtLiveEdge);
        var live = PlaybackTimeline.Create(true, true, 30_000, 90_000); Assert.False(live.AtLiveEdge); Assert.Equal(88_500, live.ClampSeek(100_000));
        Assert.True(PlaybackTimeline.Create(true, true, 89_000, 90_000).AtLiveEdge);
        Assert.Equal(90_000, PlaybackTimeline.Create(false, true, 30_000, 90_000).ClampSeek(100_000));
    }
    [Fact]
    public async Task ScheduleDistinguishesEmptyDayFromTotalFeedFailure()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var data = new RallyRepository(new SettingsStore(folder), new HttpClient(new Handler((_, _) => Task.FromResult(Json("{\"events\":[]}")))));
        Assert.Empty((await data.ScheduleAsync(DateTimeOffset.Now, league: "NFL")).Games);
        var failed = new RallyRepository(new SettingsStore(folder), new HttpClient(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)))));
        await Assert.ThrowsAsync<HttpRequestException>(() => failed.ScheduleAsync(DateTimeOffset.Now));
    }
    [Fact]
    public async Task UpdateCheckSeparatesNetworkFailureFromCurrentVersion()
    {
        var failure = new UpdateChecker(new HttpClient(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)))));
        Assert.Equal(UpdateCheckState.Failed, (await failure.CheckStatusAsync()).State);
        var current = new UpdateChecker(new HttpClient(new Handler((_, _) => Task.FromResult(Json("{\"tag_name\":\"v0.8.0\"}")))));
        Assert.Equal(UpdateCheckState.Current, (await current.CheckStatusAsync()).State);
    }
    [Fact]
    public void NestedStandingsAndDashRepresentationsAreParsed()
    {
        using var doc = JsonDocument.Parse("""{"children":[{"children":[{"standings":{"entries":[{"team":{"id":"1","displayName":"Team"},"stats":[{"name":"wins","value":5}]}]}}]}]}""");
        Assert.Equal(5, Assert.Single(EspnDetail.ParseStandings(doc.RootElement)).Wins);
        var dash = PlaybackManifest.Parse("""<MPD type="dynamic"><Period><AdaptationSet><Representation height="720" bandwidth="2500000"/><Representation height="1080" bandwidth="6000000"/></AdaptationSet></Period></MPD>""", new Uri("https://example.test/live.mpd"));
        Assert.True(dash.IsLive); Assert.Equal(new[] { 1080, 720 }, dash.Qualities.Select(q => q.Height));
    }
    [Fact]
    public void PublishedFootballSummaryIncludesFormAndObjectInjuryDetails()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "espn-nfl-summary-401872979.json")));
        var detail = EspnDetail.ParseSummary(doc.RootElement, "NO", "CAR");
        Assert.NotEmpty(detail.TeamForm); Assert.NotEmpty(detail.Injuries); Assert.All(detail.Injuries.Values.SelectMany(v => v), injury => Assert.False(string.IsNullOrWhiteSpace(injury.PlayerName)));
        Assert.NotNull(detail.Context?.Venue);
    }
    [Fact]
    public async Task AddonRequestsCoalesceAndCanceledSearchDoesNotPoisonSharedResults()
    {
        var entered = new TaskCompletionSource(); var release = new TaskCompletionSource(); var manifests = 0; var catalogs = 0;
        var client = new StremioClient(new HttpClient(new Handler(async (request, ct) =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("manifest.json")) { Interlocked.Increment(ref manifests); return Json("""{"name":"Addon","catalogs":[{"type":"sport","id":"live","extra":[]}]}"""); }
            Interlocked.Increment(ref catalogs); entered.TrySetResult(); await release.Task.WaitAsync(ct); return Json("""{"metas":[]}""");
        })));
        using var cancel = new CancellationTokenSource();
        var first = client.SearchAsync("Chiefs", "https://example.test/manifest.json", cancel.Token); await entered.Task;
        var second = client.SearchAsync("Chiefs", "https://example.test/manifest.json"); cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first); release.SetResult(); await second;
        await client.SearchAsync("Chiefs", "https://example.test/manifest.json"); Assert.Equal(1, manifests); Assert.Equal(1, catalogs);
    }
    [Fact]
    public async Task AllFailedAddonCatalogsAreAnErrorAndCanBeRetried()
    {
        var fail = true;
        var client = new StremioClient(new HttpClient(new Handler((request, _) => Task.FromResult(request.RequestUri!.AbsolutePath.EndsWith("manifest.json") ? Json("""{"name":"Addon","catalogs":[{"type":"sport","id":"live","extra":[]}]}""") : fail ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) : Json("""{"metas":[]}""")))));
        await Assert.ThrowsAsync<HttpRequestException>(() => client.SearchAsync("Chiefs", "https://example.test/manifest.json"));
        fail = false; Assert.Empty(await client.SearchAsync("Chiefs", "https://example.test/manifest.json"));
    }

    [Fact]
    public void PersistenceFailureIsReportedAndSuccessfulRetryClearsIt()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()); var settings = new SettingsStore(folder);
        Directory.CreateDirectory(Path.Combine(folder, "settings.json")); var reported = false;
        settings.Changed += key => { if (key == "persistence_error") reported = true; };
        settings.ReducedMotion = true; Assert.True(reported); Assert.NotNull(settings.PersistenceError);
        Directory.Delete(Path.Combine(folder, "settings.json")); settings.ReducedMotion = false;
        Assert.Null(settings.PersistenceError); Assert.True(File.Exists(Path.Combine(folder, "settings.json")));
    }

    [Fact]
    public void SuccessfulPreferenceWriteDoesNotHideASecretWriteFailure()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()); var settings = new SettingsStore(folder);
        Directory.CreateDirectory(Path.Combine(folder, "secrets.dat"));
        settings.StremioAddonUrls = ["https://example.test/manifest.json"];
        settings.ReducedMotion = true;
        Assert.NotNull(settings.PersistenceError);
        Directory.Delete(Path.Combine(folder, "secrets.dat"));
        settings.StremioAddonUrls = ["https://example.test/manifest.json"];
        Assert.Null(settings.PersistenceError);
    }

}
