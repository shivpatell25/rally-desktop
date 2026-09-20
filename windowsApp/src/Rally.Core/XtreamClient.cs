using System.Text.Json;

// Xtream Codes client. 1:1 port of XtreamClient.swift: player_api auth,
// live catalog, short EPG, URL builder. TTLs + identity keying match.
namespace Rally.Core;

public sealed class XtreamClient(HttpClient http, SettingsStore settings)
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private List<IptvChannel> _channels = [];
    private DateTimeOffset _channelsAt = DateTimeOffset.MinValue;
    private DateTimeOffset _authedUntil = DateTimeOffset.MinValue;
    private string _identity = "";
    private readonly Dictionary<string, (ChannelGuide Guide, DateTimeOffset At)> _guides = new();

    private static readonly TimeSpan ChannelTtl = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan GuideTtl = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan AuthTtl = TimeSpan.FromMinutes(5);

    public sealed record Account(string Server, string Username, string Password)
    {
        public string Identity => $"{Server}|{Username}|{Password}";
    }

    public Account? CurrentAccount()
    {
        if (string.IsNullOrEmpty(settings.XtreamServerUrl) ||
            string.IsNullOrEmpty(settings.XtreamUsername) ||
            string.IsNullOrEmpty(settings.XtreamPassword)) return null;
        return new Account(settings.XtreamServerUrl, settings.XtreamUsername, settings.XtreamPassword);
    }

    public static string? PlayerApi(Account a, string? action = null)
    {
        if (!Uri.TryCreate(a.Server, UriKind.Absolute, out _)) return null;
        var url = $"{a.Server.TrimEnd('/')}/player_api.php?username={Uri.EscapeDataString(a.Username)}&password={Uri.EscapeDataString(a.Password)}";
        if (!string.IsNullOrEmpty(action)) url += $"&action={action}";
        return url;
    }

    public static string? LiveStream(Account a, string streamId, string ext = "m3u8")
    {
        if (!Uri.TryCreate(a.Server, UriKind.Absolute, out _)) return null;
        return $"{a.Server.TrimEnd('/')}/live/{a.Username}/{a.Password}/{streamId.Trim()}.{ext}";
    }

    public async Task<bool> AuthenticateAsync(CancellationToken ct = default)
    {
        var a = CurrentAccount();
        if (a is null) return false;
        if (_identity == a.Identity && DateTimeOffset.UtcNow < _authedUntil) return true;
        await _gate.WaitAsync(ct);
        try
        {
            if (_identity == a.Identity && DateTimeOffset.UtcNow < _authedUntil) return true;
            var root = await RequestJsonAsync(PlayerApi(a), ct) as JsonElement?;
            var info = root?.ValueKind == JsonValueKind.Object && root.Value.TryGetProperty("user_info", out var u) ? u : (JsonElement?)null;
            var auth = info is JsonElement i ? StalkerClient.Str(i, "auth") : null;
            var status = info is JsonElement i2 ? StalkerClient.Str(i2, "status") : null;
            var accepted = auth is null || auth == "1" || auth.Equals("true", StringComparison.OrdinalIgnoreCase);
            var active = string.IsNullOrEmpty(status) || status.Equals("active", StringComparison.OrdinalIgnoreCase) || status == "1";
            if (!accepted || !active) { _authedUntil = DateTimeOffset.MinValue; return false; }
            _identity = a.Identity;
            _authedUntil = DateTimeOffset.UtcNow + AuthTtl;
            return true;
        }
        finally { _gate.Release(); }
    }

    public async Task<List<IptvChannel>> GetChannelsAsync(CancellationToken ct = default)
    {
        var a = CurrentAccount();
        if (a is null) return [];
        if (_identity == a.Identity && _channels.Count > 0 && DateTimeOffset.UtcNow - _channelsAt < ChannelTtl)
            return _channels;
        if (!await AuthenticateAsync(ct)) return _identity == a.Identity ? _channels : [];
        return await FetchChannelsAsync(a, ct);
    }

    public async Task<List<IptvChannel>> RefreshChannelsAsync(CancellationToken ct = default)
    {
        _channels = []; _channelsAt = DateTimeOffset.MinValue;
        _authedUntil = DateTimeOffset.MinValue; _identity = ""; _guides.Clear();
        return await GetChannelsAsync(ct);
    }

    private async Task<List<IptvChannel>> FetchChannelsAsync(Account a, CancellationToken ct)
    {
        var catsTask = RequestJsonAsync(PlayerApi(a, "get_live_categories"), ct);
        var streamsTask = RequestJsonAsync(PlayerApi(a, "get_live_streams"), ct);
        var categories = ParseList(await catsTask).ToDictionary(
            o => StalkerClient.Str(o, "category_id", "id") ?? "",
            o => StalkerClient.Str(o, "category_name", "name") ?? "Live TV");
        var channels = ParseList(await streamsTask).Select(o =>
        {
            var streamId = StalkerClient.Str(o, "stream_id", "id");
            if (streamId is null) return null;
            var direct = StalkerClient.Str(o, "direct_source");
            if (direct is not null && !direct.StartsWith("http://") && !direct.StartsWith("https://")) direct = null;
            var bv = StalkerClient.Str(o, "tv_archive");
            return new IptvChannel(
                $"xtream:{streamId}", StalkerClient.Str(o, "num") ?? streamId,
                StalkerClient.Str(o, "name", "stream_name") ?? $"Channel {streamId}",
                categories.TryGetValue(StalkerClient.Str(o, "category_id") ?? "", out var c) ? c
                    : StalkerClient.Str(o, "category_name") ?? "Live TV",
                StalkerClient.Str(o, "stream_icon"), direct,
                null,
                bv is "1" || bv?.Equals("true", StringComparison.OrdinalIgnoreCase) == true || bv?.Equals("yes", StringComparison.OrdinalIgnoreCase) == true,
                int.TryParse(StalkerClient.Str(o, "tv_archive_duration"), out var d) ? d : null);
        }).OfType<IptvChannel>().DistinctBy(c => c.Id).ToList();
        _channels = channels;
        _channelsAt = DateTimeOffset.UtcNow;
        _identity = a.Identity;
        return channels;
    }

    public async Task<string> ResolveStreamUrlAsync(string channelId, CancellationToken ct = default)
    {
        if (channelId.StartsWith("http://") || channelId.StartsWith("https://")) return channelId;
        var a = CurrentAccount();
        if (a is null) return channelId;
        var direct = _channels.FirstOrDefault(c => c.Id == channelId)?.StreamUrl;
        if (!string.IsNullOrEmpty(direct)) return direct;
        var streamId = System.Text.RegularExpressions.Regex.Replace(channelId, "^xtream:", "");
        return LiveStream(a, streamId) ?? channelId;
    }

    public async Task<ChannelGuide?> GetGuideAsync(string channelId, CancellationToken ct = default)
    {
        if (CurrentAccount() is null) return null;
        if (_guides.TryGetValue(channelId, out var g) && DateTimeOffset.UtcNow - g.At < GuideTtl) return g.Guide;
        if (!await AuthenticateAsync(ct)) return _guides.TryGetValue(channelId, out var g2) ? g2.Guide : null;
        var a = CurrentAccount()!;
        var streamId = System.Text.RegularExpressions.Regex.Replace(channelId, "^xtream:", "");
        var url = PlayerApi(a, "get_short_epg") + $"&stream_id={Uri.EscapeDataString(streamId)}&limit=10";
        var guide = ParseGuide(await RequestJsonAsync(url, ct));
        if (guide is null) return _guides.TryGetValue(channelId, out var g3) ? g3.Guide : null;
        _guides[channelId] = (guide, DateTimeOffset.UtcNow);
        return guide;
    }

    internal static ChannelGuide? ParseGuide(object? root)
    {
        var entries = ParseList(root).Select(o => new EpgProgram(
                StalkerClient.Str(o, "title", "name") ?? "",
                StalkerClient.Str(o, "description"),
                StalkerClient.Instant(StalkerClient.Str(o, "start_timestamp", "start")),
                StalkerClient.Instant(StalkerClient.Str(o, "stop_timestamp", "end"))))
            .Where(p => p.Title.Length > 0).ToList();
        if (entries.Count == 0) return null;
        var now = DateTimeOffset.UtcNow;
        var current = entries.FirstOrDefault(p => p.StartTime <= now && now < p.EndTime);
        var next = entries.FirstOrDefault(p => now < p.StartTime);
        return new ChannelGuide(current ?? entries.First(), next ?? entries.Skip(1).FirstOrDefault(), now);
    }

    internal static List<JsonElement> ParseList(object? root)
    {
        if (root is not JsonElement el) return [];
        if (el.ValueKind == JsonValueKind.Array) return [.. el.EnumerateArray()];
        if (el.ValueKind != JsonValueKind.Object) return [];
        foreach (var key in new[] { "data", "live_streams", "epg_listings" })
            if (el.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
                return [.. arr.EnumerateArray()];
        return [];
    }

    private async Task<object?> RequestJsonAsync(string? url, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(url)) return null;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.UserAgent.ParseAdd("Rally/Windows");
            req.Headers.Accept.ParseAdd("application/json");
            using var res = await http.SendAsync(req, ct);
            if (!res.IsSuccessStatusCode) return null;
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            return doc.RootElement.Clone();
        }
        catch { return null; }
    }
}
