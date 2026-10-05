using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace Rally.Core;

/// <summary>Loopback transport for headers LibVLC cannot attach to each HLS/DASH
/// child request. Only origins discovered in the configured manifest are served.</summary>
public sealed partial class StreamRelay : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly System.Collections.Concurrent.ConcurrentDictionary<TcpClient, byte> _clients = new();
    private readonly System.Collections.Concurrent.ConcurrentDictionary<int, Task> _requests = new();
    private int _nextRequest, _disposed;
    internal int ActiveRequestCount => _requests.Count;
    private readonly HttpClient _http = new(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All }) { Timeout = TimeSpan.FromSeconds(30) };
    private readonly CancellationTokenSource _cancel = new();
    private readonly Dictionary<string, string> _headers;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, byte> _origins = new();
    private readonly string _token = Guid.NewGuid().ToString("N");
    private readonly string _root;
    public string Url { get; }
    private readonly Task _accept;
    public StreamRelay(string url, Dictionary<string, string> headers)
    {
        _listener.Start(); var port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _root = $"http://127.0.0.1:{port}/{_token}/"; _headers = StreamRequestHeaders.Sanitize(headers);
        Url = Map(new Uri(url)); _accept = Accept();
    }
    private string Map(Uri url)
    {
        if (url.Scheme is not ("http" or "https")) throw new ArgumentException("Only HTTP streams can use request headers.");
        var origin = url.GetLeftPart(UriPartial.Authority);
        var key = Convert.ToBase64String(Encoding.UTF8.GetBytes(origin)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        _origins.TryAdd(key, 0); return _root + key + url.PathAndQuery;
    }
    private async Task Accept()
    {
        try
        {
            while (!_cancel.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(_cancel.Token); _clients.TryAdd(client, 0);
                var id = Interlocked.Increment(ref _nextRequest); var task = Serve(client); _requests[id] = task;
                _ = task.ContinueWith(_ => _requests.TryRemove(id, out var ignored), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            }
        }
        catch (Exception) when (_cancel.IsCancellationRequested) { }
    }
    private static async Task Headers(NetworkStream output, int status, string type, long? length, string? range, CancellationToken ct)
    {
        var text = $"HTTP/1.1 {status} Response\r\nConnection: close\r\nContent-Type: {type}\r\n";
        if (length is long count) text += $"Content-Length: {count}\r\n";
        if (range is not null) text += $"Content-Range: {range}\r\n";
        await output.WriteAsync(Encoding.ASCII.GetBytes(text + "\r\n"), ct);
    }
    private async Task Serve(TcpClient client)
    {
        var wroteHeaders = false;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_cancel.Token); timeout.CancelAfter(TimeSpan.FromSeconds(15));
            var output = client.GetStream(); using var reader = new StreamReader(output, Encoding.ASCII, false, 1024, leaveOpen: true);
            var line = await reader.ReadLineAsync(timeout.Token) ?? ""; var first = line.Split(' ');
            if (first.Length != 3 || first[0] is not ("GET" or "HEAD") || !first[2].StartsWith("HTTP/1.")) { await Headers(output, 400, "text/plain", 0, null, _cancel.Token); return; }
            var method = first[0]; var raw = first[1]; var parts = raw.Split('/', 4); string? requestedRange = null; var total = line.Length;
            while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync(timeout.Token))) { total += line.Length; if (total > 16384) throw new InvalidDataException("Request too large"); if (line.StartsWith("Range:", StringComparison.OrdinalIgnoreCase)) requestedRange = line[6..].Trim(); }
            if (parts.Length != 4 || parts[1] != _token || !_origins.ContainsKey(parts[2])) { await Headers(output, 404, "text/plain", 0, null, _cancel.Token); return; }
            var encoded = parts[2].Replace('-', '+').Replace('_', '/'); encoded = encoded.PadRight((encoded.Length + 3) / 4 * 4, '=');
            var origin = Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
            using var request = new HttpRequestMessage(method == "HEAD" ? HttpMethod.Head : HttpMethod.Get, origin + "/" + parts[3]);
            foreach (var h in _headers) request.Headers.TryAddWithoutValidation(h.Key, h.Value);
            if (requestedRange is string range) request.Headers.TryAddWithoutValidation("Range", range);
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, _cancel.Token);
            var type = response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream";
            var contentRange = response.Content.Headers.ContentRange?.ToString();
            var final = response.RequestMessage?.RequestUri ?? request.RequestUri!;
            var manifest = type.Contains("mpegurl", StringComparison.OrdinalIgnoreCase) || type.Contains("dash+xml", StringComparison.OrdinalIgnoreCase) || final.AbsolutePath.EndsWith(".m3u8") || final.AbsolutePath.EndsWith(".mpd");
            if (manifest && response.IsSuccessStatusCode)
            {
                if (response.Content.Headers.ContentLength > 4_000_000) throw new InvalidDataException("Manifest too large");
                var text = await response.Content.ReadAsStringAsync(_cancel.Token);
                if (text.Length > 4_000_000) throw new InvalidDataException("Manifest too large");
                if (text.TrimStart().StartsWith("#EXTM3U"))
                {
                    text = string.Join('\n', text.Split('\n').Select(line =>
                    {
                        if (!line.TrimStart().StartsWith('#') && line.Trim().Length > 0) return Map(new Uri(final, line.Trim()));
                        return HlsUri().Replace(line, m => "URI=\"" + Map(new Uri(final, m.Groups[1].Value)) + "\"");
                    }));
                }
                else
                {
                    text = AbsoluteUrl().Replace(text, m => WebUtility.HtmlEncode(Map(new Uri(WebUtility.HtmlDecode(m.Value)))));
                    // Explicit BaseURL ensures relative segment/template paths are
                    // resolved against redirects rather than the original request.
                    if (!text.Contains("<BaseURL", StringComparison.Ordinal))
                        text = Regex.Replace(text, "(<MPD\\b[^>]*>)", "$1<BaseURL>" + WebUtility.HtmlEncode(Map(new Uri(final, "."))) + "</BaseURL>");
                }
                var bytes = Encoding.UTF8.GetBytes(text); await Headers(output, (int)response.StatusCode, type, bytes.Length, contentRange, _cancel.Token); wroteHeaders = true;
                if (method != "HEAD") await output.WriteAsync(bytes, _cancel.Token);
            }
            else
            {
                await Headers(output, (int)response.StatusCode, type, response.Content.Headers.ContentLength, contentRange, _cancel.Token); wroteHeaders = true;
                if (method != "HEAD") await response.Content.CopyToAsync(output, _cancel.Token);
            }
        }
        catch (Exception) { if (!wroteHeaders) try { await Headers(client.GetStream(), 502, "text/plain", 0, null, CancellationToken.None); } catch { } }
        finally { _clients.TryRemove(client, out _); client.Dispose(); }
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _cancel.Cancel(); _listener.Stop(); foreach (var client in _clients.Keys) client.Dispose();
        try { await _accept; await Task.WhenAll(_requests.Values); } catch { }
        _http.Dispose(); _cancel.Dispose();
    }
    [GeneratedRegex("URI=\"([^\"]+)\"")]
    private static partial Regex HlsUri();
    [GeneratedRegex("https?://[^\\s<>\"']+")]
    private static partial Regex AbsoluteUrl();
}
