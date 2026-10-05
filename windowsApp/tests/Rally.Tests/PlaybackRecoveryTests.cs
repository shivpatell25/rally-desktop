using System.Net;
using System.Text.Json;
using Rally.Core;

namespace Rally.Tests;

public sealed class PlaybackRecoveryTests
{
    private static SportEvent Game => new("1", "Chiefs vs Ravens", new("bal", "Ravens", "BAL"), new("kc", "Chiefs", "KC"), DateTimeOffset.Now, EventStatus.Live, 24, 20, "football", "NFL");
    private sealed class AddonHandler : HttpMessageHandler
    {
        public int Generation, Requests;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            string json;
            if (path.EndsWith("manifest.json")) json = """{"name":"Sports Streams","catalogs":[{"id":"nfl","type":"tv","name":"NFL"}]}""";
            else if (path.Contains("/catalog/")) json = """{"metas":[{"id":"kc-bal","type":"tv","name":"Chiefs vs Ravens"}]}""";
            else { Requests++; json = JsonSerializer.Serialize(new { streams = new[] { new { name = "Sports HD", url = $"https://cdn.example/{Generation}/live.m3u8", behaviorHints = new { proxyHeaders = new { request = new Dictionary<string, string> { ["Cookie"] = $"session={Generation}" } } } } } }); }
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json) });
        }
    }
    [Fact]
    public async Task RecoveryBypassesAddonCacheAndReplacesExpiredHeaders()
    {
        using var handler = new AddonHandler(); using var http = new HttpClient(handler);
        var client = new StremioClient(http);
        var original = Assert.Single(await client.FindStreamsAsync(Game, "https://addon.example/manifest.json"));
        handler.Generation = 2;
        Assert.Equal(original.StreamUrl, Assert.Single(await client.FindStreamsAsync(Game, "https://addon.example/manifest.json")).StreamUrl);
        var fresh = Assert.Single(await client.RefreshStreamsAsync(Game, "https://addon.example/manifest.json"));
        Assert.Equal("https://cdn.example/2/live.m3u8", fresh.StreamUrl);
        Assert.Equal("session=2", fresh.Headers!["Cookie"]);
        Assert.Equal(2, handler.Requests);
    }
    [Fact]
    public async Task RepositoryRenewsSelectedEventSourceRatherThanReusingItsUrl()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var settings = new SettingsStore(folder) { StremioAddonUrls = ["https://addon.example/manifest.json"] };
            using var handler = new AddonHandler(); using var http = new HttpClient(handler);
            var data = new RallyRepository(settings, http);
            var source = new PlayCandidate("old", "Sports HD", "https://cdn.example/0/live.m3u8", null, PlayKind.Stremio, true, 0, AddonName: "Sports Streams");
            handler.Generation = 3;
            var fresh = await data.RenewSourceAsync(source, Game);
            Assert.Equal("https://cdn.example/3/live.m3u8", fresh.Url);
            Assert.Equal("session=3", fresh.Headers!["Cookie"]);
            Assert.Same(source, await data.RenewSourceAsync(source, null));
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
    private sealed class PortalHandler : HttpMessageHandler
    {
        public int Active, MaxActive, Links, Handshakes;
        public bool Invalid;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            string json;
            if (request.RequestUri!.Query.Contains("action=handshake")) { Interlocked.Increment(ref Handshakes); json = """{"js":{"token":"new-token"}}"""; }
            else if (request.RequestUri.Query.Contains("action=get_profile")) json = """{"js":{"status":0}}""";
            else
            {
                Interlocked.Increment(ref Links); var current = Interlocked.Increment(ref Active); MaxActive = Math.Max(MaxActive, current);
                try { await Task.Delay(40, ct); json = Invalid ? """{"js":{"cmd":"ffmpeg http://localhost/ch/22_"}}""" : """{"js":{"cmd":"ffmpeg https://cdn.example/live.m3u8"}}"""; }
                finally { Interlocked.Decrement(ref Active); }
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json) };
        }
    }
    [Fact]
    public async Task FourPortalStreamsNegotiateOneAtATimeAndUseNewHeaders()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var settings = new SettingsStore(folder) { PortalUrl = "https://portal.example/c", MacAddress = "00:1A:79:00:00:01" };
            using var handler = new PortalHandler(); using var http = new HttpClient(handler); var portal = new StalkerClient(http, settings);
            var links = await Task.WhenAll(Enumerable.Range(1, 4).Select(i => portal.ResolveStreamUrlAsync(i.ToString())));
            Assert.All(links, link => Assert.Equal("https://cdn.example/live.m3u8", link));
            Assert.Equal(1, handler.MaxActive); Assert.Equal(4, handler.Links); Assert.Equal(1, handler.Handshakes);
            Assert.Equal("Bearer new-token", portal.PlaybackHeaders()["Authorization"]);
            Assert.Contains("mac=", portal.PlaybackHeaders()["Cookie"]);
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
    [Fact]
    public async Task InvalidPortalCommandIsNeverHandedToPlayerAndRecoveryIsBounded()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var settings = new SettingsStore(folder) { PortalUrl = "https://portal.example/c", AuthToken = "Bearer old" };
            using var handler = new PortalHandler { Invalid = true }; using var http = new HttpClient(handler); var portal = new StalkerClient(http, settings);
            await Assert.ThrowsAsync<HttpRequestException>(() => portal.ResolveStreamUrlAsync("22"));
            Assert.Equal(2, handler.Links); Assert.Equal(1, handler.Handshakes);
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
    [Fact]
    public async Task CancelledPortalWaiterDoesNotBlockOtherTiles()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var settings = new SettingsStore(folder) { PortalUrl = "https://portal.example/c", AuthToken = "Bearer old" };
            using var handler = new PortalHandler(); using var http = new HttpClient(handler); var portal = new StalkerClient(http, settings);
            var first = portal.ResolveStreamUrlAsync("1");
            using var cancel = new CancellationTokenSource(); var second = portal.ResolveStreamUrlAsync("2", cancel.Token); cancel.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => second);
            await first;
            Assert.Equal("https://cdn.example/live.m3u8", await portal.ResolveStreamUrlAsync("3"));
            Assert.Equal(2, handler.Links);
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
}
