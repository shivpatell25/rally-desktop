using System.Net;
using System.Net.Sockets;
using System.Text;
using Rally.Core;
namespace Rally.Tests;
public sealed class StreamRelayTests
{
    [Fact]
    public async Task DisposingRelayCancelsAndDrainsPendingUpstreamRequest()
    {
        using var cancel = new CancellationTokenSource();
        var upstream = new TcpListener(IPAddress.Loopback, 0); upstream.Start();
        var incoming = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var serving = Task.Run(async () =>
        {
            using var client = await upstream.AcceptTcpClientAsync(cancel.Token);
            using var reader = new StreamReader(client.GetStream());
            await reader.ReadLineAsync(cancel.Token); incoming.TrySetResult();
            try { await Task.Delay(Timeout.Infinite, cancel.Token); } catch (OperationCanceledException) { }
        });
        var port = ((IPEndPoint)upstream.LocalEndpoint).Port;
        var relay = new StreamRelay($"http://127.0.0.1:{port}/frozen.m3u8", new());
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            var request = http.GetAsync(relay.Url);
            await incoming.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Assert.Equal(1, relay.ActiveRequestCount);
            await relay.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(2));
            Assert.Equal(0, relay.ActiveRequestCount);
            await Assert.ThrowsAnyAsync<Exception>(() => request);
            await relay.DisposeAsync();
        }
        finally { cancel.Cancel(); upstream.Stop(); await serving; await relay.DisposeAsync(); }
    }
    [Fact]
    public async Task HlsChildrenKeepHeadersAndUnregisteredOriginsAreRejected()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0); probe.Start(); var port = ((IPEndPoint)probe.LocalEndpoint).Port; probe.Stop();
        using var upstream = new HttpListener(); upstream.Prefixes.Add($"http://127.0.0.1:{port}/"); upstream.Start();
        using var cancel = new CancellationTokenSource(); var cookies = new List<string>();
        var serving = Task.Run(async () =>
        {
            try
            {
                while (!cancel.IsCancellationRequested)
                {
                    var ctx = await upstream.GetContextAsync().WaitAsync(cancel.Token); cookies.Add(ctx.Request.Headers["Cookie"] ?? "");
                    var text = ctx.Request.Url!.AbsolutePath.EndsWith(".m3u8") ? "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST" : "media bytes";
                    ctx.Response.ContentType = ctx.Request.Url.AbsolutePath.EndsWith(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t";
                    var bytes = Encoding.UTF8.GetBytes(text); ctx.Response.ContentLength64 = bytes.Length; await ctx.Response.OutputStream.WriteAsync(bytes); ctx.Response.Close();
                }
            }
            catch (OperationCanceledException) { }
        });
        await using var relay = new StreamRelay($"http://127.0.0.1:{port}/live/master.m3u8", new() { ["Cookie"] = "auth=private", ["Authorization"] = "Bearer private" });
        using var http = new HttpClient(); var manifest = await http.GetStringAsync(relay.Url); var segment = manifest.Split('\n').First(l => l.StartsWith("http://"));
        Assert.Equal("media bytes", await http.GetStringAsync(segment)); Assert.All(cookies, cookie => Assert.Equal("auth=private", cookie));
        var uri = new Uri(relay.Url); var token = uri.AbsolutePath.Split('/')[1];
        Assert.Equal(HttpStatusCode.NotFound, (await http.GetAsync($"{uri.GetLeftPart(UriPartial.Authority)}/{token}/unregistered/secret")).StatusCode);
        cancel.Cancel(); upstream.Stop(); await serving;
    }
}
