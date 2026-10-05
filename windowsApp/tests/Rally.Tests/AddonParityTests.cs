using System.Net;
using Rally.Core;
namespace Rally.Tests;
public sealed class AddonParityTests
{
    private sealed class Handler : HttpMessageHandler
    {
        public List<string> Paths { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
        {
            var path = req.RequestUri!.AbsolutePath; Paths.Add(path);
            var json = path.EndsWith("manifest.json") ? """
{"name":"Sports Streams","catalogs":[{"id":"ncaa","name":"College Football","type":"tv","extra":[{"name":"date","isRequired":true}]}]}
""" : path.Contains("/catalog/") ? """
{"metas":[{"id":"correct","name":"NCAA: North Carolina @ Notre Dame","type":"tv"},{"id":"wrong","name":"NCAA: Georgia @ Texas","type":"tv"}]}
""" : """
{"streams":[{"name":"Sports HD","url":"https://cdn.example/game.m3u8","behaviorHints":{"proxyHeaders":{"request":{"Cookie":"auth=yes","Referer":"https://watch.example"}}}}]}
""";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json) });
        }
    }
    [Fact]
    public async Task CollegeMatchUsesSchoolsAndPreservesStreamHeaders()
    {
        var handler = new Handler(); var client = new StremioClient(new HttpClient(handler));
        var game = new SportEvent("1", "Notre Dame Fighting Irish vs North Carolina Tar Heels", new("2", "North Carolina Tar Heels", "UNC"), new("1", "Notre Dame Fighting Irish", "ND"), DateTimeOffset.Now, EventStatus.Live, 0, 0, "football", "NCAAF");
        var streams = await client.FindStreamsAsync(game, "https://addon.example/manifest.json");
        Assert.Single(streams); Assert.Equal("auth=yes", streams[0].Headers?["Cookie"]); Assert.Contains(handler.Paths, p => p.Contains("/stream/tv/correct")); Assert.DoesNotContain(handler.Paths, p => p.Contains("/stream/tv/wrong"));
    }
}
