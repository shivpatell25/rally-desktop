// Lightweight availability check that never downloads a video body.
// 1:1 port of data/remote/network/StreamPreflightProbe.kt: HEAD first,
// Range bytes=0-1023 fallback, HTML bodies rejected.
namespace Rally.Core;

public sealed record PreflightResult(bool Passed, long LatencyMs, string? ContentType, int? StatusCode, string Detail);

public sealed class StreamPreflightProbe
{
    private static readonly HashSet<int> RetryStatuses = [403, 405, 501];
    private readonly HttpClient _http;

    public StreamPreflightProbe(HttpClient? http = null)
    {
        _http = http ?? new HttpClient() { Timeout = TimeSpan.FromSeconds(3) };
    }

    public async Task<PreflightResult> ProbeAsync(string url, Dictionary<string, string>? headers = null, CancellationToken ct = default)
    {
        if ((!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
             !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) ||
            !Uri.TryCreate(url, UriKind.Absolute, out var target))
            return new PreflightResult(false, 0, null, null, "Provider link must be resolved first");
        var started = DateTimeOffset.UtcNow;
        var sanitized = StreamRequestHeaders.Sanitize(headers);
        var head = await AttemptAsync(target, sanitized, head: true, started, ct).ConfigureAwait(false);
        if (head is not null && (head.Passed || head.StatusCode is null || !RetryStatuses.Contains(head.StatusCode.Value)))
            return head;
        var range = await AttemptAsync(target, sanitized, head: false, started, ct).ConfigureAwait(false);
        return range ?? new PreflightResult(false, ElapsedMs(started), null, null, "Connection failed");
    }

    private async Task<PreflightResult?> AttemptAsync(Uri target, Dictionary<string, string> headers, bool head, DateTimeOffset started, CancellationToken ct)
    {
        try
        {
            using var req = new HttpRequestMessage(head ? HttpMethod.Head : HttpMethod.Get, target);
            req.Headers.UserAgent.ParseAdd("Rally/1.0 Windows");
            req.Headers.Accept.ParseAdd("application/vnd.apple.mpegurl, application/x-mpegURL, video/*, */*");
            foreach (var (name, value) in headers)
            {
                if (name.Equals("User-Agent", StringComparison.OrdinalIgnoreCase)) continue;
                req.Headers.TryAddWithoutValidation(name, value);
            }
            if (!head) req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, 1023);
            using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
            var type = res.Content.Headers.ContentType?.MediaType;
            var html = type?.Contains("text/html", StringComparison.OrdinalIgnoreCase) == true;
            var passed = res.IsSuccessStatusCode && !html;
            return new PreflightResult(passed, ElapsedMs(started), type, (int)res.StatusCode,
                html ? "Received a web page instead of video"
                    : passed ? "Verified before playback"
                    : $"Server returned {(int)res.StatusCode}");
        }
        catch { return null; }
    }

    private static long ElapsedMs(DateTimeOffset started) =>
        (long)(DateTimeOffset.UtcNow - started).TotalMilliseconds;
}
