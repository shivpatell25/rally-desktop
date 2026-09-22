using System.Text.Json;

// Stalker/Ministra middleware client. 1:1 port of StalkerClient.swift:
// MAG250 headers, handshake→profile auth, portal auto-discovery,
// get_all_channels with paged get_ordered_list fallback, create_link,
// short EPG now/next. 15-min channel TTL, 2-min guide TTL.
namespace Rally.Core;

public sealed class StalkerClient(HttpClient http, SettingsStore settings)
{
    private readonly SemaphoreSlim _authGate = new(1, 1);
    private List<IptvChannel> _channels = [];
    private DateTimeOffset _channelsAt = DateTimeOffset.MinValue;
    private readonly Dictionary<string, (ChannelGuide Guide, DateTimeOffset At)> _guides = new();

    private static readonly TimeSpan ChannelTtl = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan GuideTtl = TimeSpan.FromMinutes(2);

    public async Task<bool> AuthenticateAsync(bool force = false, CancellationToken ct = default)
    {
        if (!force && !string.IsNullOrEmpty(settings.AuthToken)) return true;
        if (string.IsNullOrEmpty(settings.PortalUrl)) return false;
        await _authGate.WaitAsync(ct);
        try
        {
            settings.AuthToken = "";
            if (await TryAuthAsync(ct)) return true;
            var current = settings.PortalUrl;
            var baseUrl = System.Text.RegularExpressions.Regex.Replace(current, "/c$", "")
                .Replace("/stalker_portal", "").TrimEnd('/');
            foreach (var candidate in new[] { current, baseUrl + "/c", baseUrl + "/stalker_portal", baseUrl + "/stalker_portal/c" }.Distinct())
            {
                settings.PortalUrl = candidate;
                if (await TryAuthAsync(ct)) return true;
            }
            settings.PortalUrl = current;
            return false;
        }
        finally { _authGate.Release(); }
    }

    private async Task<bool> TryAuthAsync(CancellationToken ct)
    {
        JsonElement js;
        try { js = await GetAsync("stb", "handshake", new() { ["token"] = "", ["prehash"] = "0" }, false, ct); }
        catch { return false; }
        var raw = Str(js, "token", "random");
        if (string.IsNullOrEmpty(raw)) return false;
        var bearer = raw.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? raw : "Bearer " + raw;
        settings.AuthToken = bearer;
        JsonElement profile;
        try
        {
            profile = await GetAsync("stb", "get_profile", new()
            {
                ["hd"] = "1",
                ["ver"] = "ImageDescription: 0.2.18-r23-250; ImageDate: Wed Sep 18 12:40:14 EEST 2013; PORTAL version: 5.6.0; API Version: JS API version: 343; STB API version: 146; Player Engine version: 0x58c",
                ["num_banks"] = "2", ["stb_type"] = "MAG250", ["client_type"] = "STB",
                ["image_version"] = "218", ["video_out"] = "hdmi", ["auth_second_step"] = "1",
                ["hw_version"] = "1.7-BD-00", ["not_valid_token"] = "0",
            }, true, ct);
        }
        catch { settings.AuthToken = ""; return false; }
        if (StatusRejected(profile)) { settings.AuthToken = ""; return false; }
        return true;
    }

    internal static bool StatusRejected(JsonElement js)
    {
        if (js.ValueKind != JsonValueKind.Object || !js.TryGetProperty("status", out var raw)) return false;
        if (raw.ValueKind == JsonValueKind.Number) return raw.GetDouble() is 1 or 2;
        if (raw.ValueKind == JsonValueKind.String)
        {
            var s = raw.GetString() ?? "";
            if (int.TryParse(s, out var n)) return n is 1 or 2;
            return s.ToLowerInvariant() is "error" or "failed";
        }
        return false;
    }

    public async Task<List<IptvChannel>> GetChannelsAsync(CancellationToken ct = default)
    {
        EnsureOwner();
        if (_channels.Count > 0 && DateTimeOffset.UtcNow - _channelsAt < ChannelTtl) return _channels;
        var disk = new ChannelDiskStore(settings.CacheDirectory);
        var identity = settings.ChannelCacheIdentity;
        if (_channels.Count == 0)
        {
            // Instant catalog from disk; the 15-min memory TTL still bounds staleness.
            var cached = disk.LoadFresh(identity);
            if (cached is not null) { _channels = cached; _channelsAt = DateTimeOffset.UtcNow; return cached; }
        }
        if (string.IsNullOrEmpty(settings.AuthToken) && !await AuthenticateAsync(false, ct))
        {
            if (_channels.Count > 0) return _channels;
            return disk.LoadAny(identity) ?? [];
        }
        var fresh = await FetchChannelsAsync(ct);
        if (fresh.Count == 0)
        {
            await AuthenticateAsync(true, ct);
            fresh = await FetchChannelsAsync(ct);
        }
        if (fresh.Count > 0) { _channels = fresh; _channelsAt = DateTimeOffset.UtcNow; disk.Save(fresh, identity); }
        if (fresh.Count > 0) return fresh;
        if (_channels.Count > 0) return _channels;
        return disk.LoadAny(identity) ?? [];
    }

    public async Task<List<IptvChannel>> RefreshChannelsAsync(CancellationToken ct = default)
    {
        _channels = [];
        return await GetChannelsAsync(ct);
    }

    private async Task<List<IptvChannel>> FetchChannelsAsync(CancellationToken ct)
    {
        var all = new List<JsonElement>();
        try
        {
            var js = await GetAsync("itv", "get_all_channels", new(), true, ct);
            all.AddRange(ChannelObjects(js));
        }
        catch { /* fall through to ordered list */ }
        if (all.Count == 0)
        {
            for (var page = 1; page <= 50; page++)
            {
                JsonElement js;
                try
                {
                    js = await GetAsync("itv", "get_ordered_list",
                        new() { ["p"] = page.ToString(), ["fav"] = "0", ["sortby"] = "number" }, true, ct);
                }
                catch { break; }
                var (objs, total) = ChannelObjectsWithTotal(js);
                all.AddRange(objs);
                if ((total is int t && all.Count >= t) || objs.Count == 0) break;
            }
        }
        Dictionary<string, string> genres = new();
        try { genres = GenreMap(await GetAsync("itv", "get_genres", new(), true, ct)); } catch { }
        return all.Select(o => MapChannel(o, genres)).OfType<IptvChannel>().ToList();
    }

    internal static IptvChannel? MapChannel(JsonElement o, Dictionary<string, string> genres)
    {
        var id = Str(o, "id", "ch_id");
        if (id is null) return null;
        var genreId = Str(o, "tv_genre_id") ?? "";
        var archiveHours = IntVal(o, "tv_archive_duration", "archive_hours");
        var archiveDays = IntVal(o, "archive_days");
        return new IptvChannel(
            id, Str(o, "number", "num") ?? id, Str(o, "name") ?? $"Channel {id}",
            genres.TryGetValue(genreId, out var g) ? g : "Live TV",
            Str(o, "logo"), Str(o, "cmd"),
            null,
            Truthy(o, "tv_archive", "allow_timeshift", "archive"),
            archiveHours ?? (archiveDays is int days ? days * 24 : null));
    }

    public async Task<string> ResolveStreamUrlAsync(string channelId, CancellationToken ct = default)
    {
        if ((channelId.StartsWith("http://") || channelId.StartsWith("https://")) && !channelId.Contains("localhost"))
            return CleanStreamUrl(channelId);
        var cmd = channelId;
        if (!cmd.Contains("localhost") && !cmd.StartsWith("ffmpeg") && !cmd.StartsWith("ffrt") && !cmd.StartsWith("auto"))
        {
            var cached = _channels.FirstOrDefault(c => c.Id == channelId)?.StreamUrl;
            if (!string.IsNullOrEmpty(cached)) cmd = cached;
        }
        if (string.IsNullOrEmpty(settings.AuthToken)) await AuthenticateAsync(false, ct);
        JsonElement? js = null;
        try { js = await GetAsync("itv", "create_link", new() { ["cmd"] = cmd }, true, ct); }
        catch
        {
            if (await AuthenticateAsync(true, ct))
                try { js = await GetAsync("itv", "create_link", new() { ["cmd"] = cmd }, true, ct); } catch { }
        }
        if (js is JsonElement el)
        {
            if (el.ValueKind == JsonValueKind.Object && el.TryGetProperty("cmd", out var c) && c.GetString() is string s) return CleanStreamUrl(s);
            if (el.ValueKind == JsonValueKind.String) return CleanStreamUrl(el.GetString() ?? cmd);
        }
        return CleanStreamUrl(cmd);
    }

    public static string CleanStreamUrl(string raw)
    {
        var url = raw.Trim();
        foreach (var prefix in new[] { "ffmpeg ", "ffrt ", "auto " })
            if (url.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                url = url[prefix.Length..].Trim();
        return url;
    }

    public async Task<ChannelGuide?> GetGuideAsync(string channelId, CancellationToken ct = default)
    {
        if (_guides.TryGetValue(channelId, out var g) && DateTimeOffset.UtcNow - g.At < GuideTtl) return g.Guide;
        if (string.IsNullOrEmpty(settings.PortalUrl)) return null;
        if (string.IsNullOrEmpty(settings.AuthToken) && !await AuthenticateAsync(false, ct)) return null;
        ChannelGuide? guide;
        try
        {
            var js = await GetAsync("itv", "get_short_epg",
                new() { ["ch_id"] = channelId, ["size"] = "4" }, true, ct);
            guide = ParseGuide(js);
        }
        catch { return g.Guide; }
        if (guide is not null) _guides[channelId] = (guide, DateTimeOffset.UtcNow);
        return guide;
    }

    internal static ChannelGuide? ParseGuide(JsonElement js)
    {
        var entries = new List<JsonElement>();
        void Collect(JsonElement el)
        {
            if (el.ValueKind == JsonValueKind.Array) { foreach (var i in el.EnumerateArray()) Collect(i); return; }
            if (el.ValueKind != JsonValueKind.Object) return;
            foreach (var key in new[] { "data", "epg", "programs", "items" })
                if (el.TryGetProperty(key, out var nested)) { Collect(nested); return; }
            entries.Add(el);
        }
        Collect(js);
        var programs = entries.Select(o => new EpgProgram(
                Str(o, "name", "title", "program", "programme") ?? "",
                Str(o, "descr", "description", "desc"),
                Instant(Str(o, "start_timestamp", "start", "begin", "time")),
                Instant(Str(o, "stop_timestamp", "end_timestamp", "end", "stop"))))
            .Where(p => p.Title.Length > 0)
            .OrderBy(p => p.StartTime ?? DateTimeOffset.MaxValue).ToList();
        if (programs.Count == 0) return null;
        var now = DateTimeOffset.UtcNow;
        var idx = programs.FindIndex(p => p.StartTime <= now && now < p.EndTime);
        if (idx < 0) idx = 0;
        return new ChannelGuide(programs[idx], idx + 1 < programs.Count ? programs[idx + 1] : null, now);
    }

    private async Task<JsonElement> GetAsync(string type, string action, Dictionary<string, string> extra, bool authorized, CancellationToken ct)
    {
        var portal = settings.PortalUrl;
        var query = new List<string> { "JsHttpRequest=1-xml", $"type={type}", $"action={action}" };
        if (action == "handshake") query.AddRange(["token=", "prehash=0"]);
        if (action == "get_ordered_list")
        {
            if (!extra.ContainsKey("fav")) query.Add("fav=0");
            if (!extra.ContainsKey("sortby")) query.Add("sortby=number");
        }
        foreach (var (k, v) in extra)
        {
            if (action == "get_ordered_list" && (k is "fav" or "sortby")) continue;
            query.Add($"{Uri.EscapeDataString(k)}={Uri.EscapeDataString(v)}");
        }
        if (!string.IsNullOrEmpty(settings.SerialNumber)) query.Add($"sn={Uri.EscapeDataString(settings.SerialNumber)}");
        if (!string.IsNullOrEmpty(settings.DeviceId))
            query.AddRange([$"device_id={Uri.EscapeDataString(settings.DeviceId)}", $"device_id2={Uri.EscapeDataString(settings.DeviceId)}"]);
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{portal}/server/load.php?{string.Join("&", query)}");
        var mac = settings.MacAddress;
        var xua = "Model: MAG250; Link: Ethernet"
            + (string.IsNullOrEmpty(settings.SerialNumber) ? "" : $"; SerialNumber: {settings.SerialNumber}")
            + (string.IsNullOrEmpty(settings.DeviceId) ? "" : $"; DeviceId: {settings.DeviceId}; DeviceId2: {settings.DeviceId}")
            + (string.IsNullOrEmpty(mac) ? "" : $"; Mac: {mac}");
        req.Headers.Add("X-User-Agent", xua);
        req.Headers.UserAgent.ParseAdd("Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3");
        req.Headers.Add("X-Requested-With", "XMLHttpRequest");
        req.Headers.Referrer = new Uri(RefererFor(portal));
        if (!string.IsNullOrEmpty(mac)) req.Headers.Add("Cookie", $"mac={mac}; stb_lang=en; timezone=GMT");
        if (authorized && !string.IsNullOrEmpty(settings.AuthToken))
            req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", settings.AuthToken.Replace("Bearer ", "", StringComparison.OrdinalIgnoreCase));
        using var res = await http.SendAsync(req, ct);
        res.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        var root = doc.RootElement.Clone();
        if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("js", out var js)) return js;
        return root;
    }

    internal static string RefererFor(string portal)
    {
        if (!Uri.TryCreate(portal, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) return portal + "/";
        var path = uri.AbsolutePath.Trim('/');
        var r = $"{uri.Scheme}://{uri.Authority}{(path.Length == 0 ? "" : "/" + path)}";
        if (!r.EndsWith("/c")) r += "/c";
        return r + "/";
    }

    internal static List<JsonElement> ChannelObjects(JsonElement js) => ChannelObjectsWithTotal(js).Objects;

    internal static (List<JsonElement> Objects, int? Total) ChannelObjectsWithTotal(JsonElement js)
    {
        if (js.ValueKind == JsonValueKind.Array) return ([.. js.EnumerateArray()], null);
        if (js.ValueKind != JsonValueKind.Object) return ([], null);
        int? total = js.TryGetProperty("total_items", out var t)
            ? t.ValueKind == JsonValueKind.Number ? t.GetInt32() : int.TryParse(t.GetString(), out var n) ? n : null : null;
        if (js.TryGetProperty("data", out var data))
        {
            if (data.ValueKind == JsonValueKind.Array) return ([.. data.EnumerateArray()], total);
            if (data.ValueKind == JsonValueKind.Object) return (data.EnumerateObject().Select(p => p.Value).ToList(), total);
        }
        var skip = new HashSet<string> { "total_items", "max_page_items", "selected_item", "cur_page" };
        return (js.EnumerateObject().Where(p => !skip.Contains(p.Name)).Select(p => p.Value).ToList(), total);
    }

    private static Dictionary<string, string> GenreMap(JsonElement js)
    {
        var objs = js.ValueKind switch
        {
            JsonValueKind.Array => js.EnumerateArray(),
            JsonValueKind.Object => js.EnumerateObject().Select(p => p.Value),
            _ => Enumerable.Empty<JsonElement>(),
        };
        var out_ = new Dictionary<string, string>();
        foreach (var o in objs)
            if (o.ValueKind == JsonValueKind.Object && Str(o, "id", "tv_genre_id") is string id && Str(o, "title", "name") is string title)
                out_[id] = title;
        return out_;
    }

    private void EnsureOwner()
    {
        var identity = $"{settings.PortalUrl.ToLowerInvariant()}|{settings.MacAddress.ToUpperInvariant()}";
        if (settings.ChannelCacheIdentity == identity) return;
        _channels = [];
        _guides.Clear();
        settings.ChannelCacheIdentity = identity;
        settings.AuthToken = "";
    }

    internal static string? Str(JsonElement o, params string[] keys)
    {
        if (o.ValueKind != JsonValueKind.Object) return null;
        foreach (var k in keys)
        {
            if (!o.TryGetProperty(k, out var v)) continue;
            var s = v.ValueKind switch
            {
                JsonValueKind.String => v.GetString()?.Trim(),
                JsonValueKind.Number => v.GetRawText(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => null,
            };
            if (!string.IsNullOrEmpty(s)) return s;
        }
        return null;
    }

    private static bool Truthy(JsonElement o, params string[] keys)
    {
        foreach (var k in keys)
        {
            var s = Str(o, k)?.ToLowerInvariant();
            if (s is "1" or "true" or "yes") return true;
            if (int.TryParse(s, out var n) && n > 0) return true;
        }
        return false;
    }

    private static int? IntVal(JsonElement o, params string[] keys)
    {
        foreach (var k in keys)
            if (int.TryParse(Str(o, k), out var n)) return n;
        return null;
    }

    internal static DateTimeOffset? Instant(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        raw = raw.Trim();
        if (long.TryParse(raw, out var n))
            return DateTimeOffset.FromUnixTimeMilliseconds(n < 10_000_000_000 ? n * 1000 : n);
        if (DateTimeOffset.TryParse(raw, out var dto)) return dto;
        if (DateTime.TryParseExact(raw, "yyyy-MM-dd HH:mm:ss", null,
                System.Globalization.DateTimeStyles.AssumeUniversal, out var dt))
            return new DateTimeOffset(dt, TimeSpan.Zero);
        return null;
    }
}
