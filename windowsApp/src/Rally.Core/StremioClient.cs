using System.Text.Json;

// Stremio addon client. Mirrors StremioApi + StremioRepositoryImpl behavior:
// header allowlist, isDirectPlayable, 6-catalog / 6-meta discovery caps.
namespace Rally.Core;

public sealed class StremioClient(HttpClient http)
{
    private static readonly HashSet<string> AllowedHeaders = new(StringComparer.OrdinalIgnoreCase)
        { "user-agent", "referer", "origin", "cookie" };

    public async Task<JsonDocument> FetchManifestAsync(string manifestUrl, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, manifestUrl);
        req.Headers.UserAgent.ParseAdd("Rally/Windows");
        req.Headers.Accept.ParseAdd("application/json");
        using var res = await http.SendAsync(req, ct);
        res.EnsureSuccessStatusCode();
        return JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
    }

    public async Task<List<StremioStreamOption>> FindStreamsAsync(SportEvent ev, string addonBase, CancellationToken ct = default)
    {
        var manifestUrl = addonBase.EndsWith(".json", StringComparison.Ordinal) ? addonBase : addonBase.TrimEnd('/') + "/manifest.json";
        using var manifest = await FetchManifestAsync(manifestUrl, ct);
        var root = manifest.RootElement;
        var addonName = root.GetPropertyOrNull("name")?.GetString();
        var baseUrl = manifestUrl.EndsWith("/manifest.json", StringComparison.Ordinal)
            ? manifestUrl[..^"/manifest.json".Length] : manifestUrl;
        if (!root.TryGetProperty("catalogs", out var catalogs)) return [];
        var metas = new List<(string Id, string? Type, string Name)>();
        foreach (var cat in catalogs.EnumerateArray().Take(6))
        {
            var type = cat.GetPropertyOrNull("type")?.GetString();
            var id = cat.GetPropertyOrNull("id")?.GetString();
            if (type is null || id is null) continue;
            List<(string, string?, string)> items;
            try { items = await FetchCatalogAsync(baseUrl, type, id, ct); }
            catch { continue; }
            metas.AddRange(items);
        }
        var matches = metas.Where(m =>
        {
            var probe = ev with { Id = m.Id, Name = m.Name };
            return StreamSelector.TextMatchesEvent(m.Name, probe);
        }).Take(6).ToList();
        var options = new List<StremioStreamOption>();
        foreach (var m in matches)
        {
            try { options.AddRange(await FetchStreamsAsync(baseUrl, m.Type ?? "sport", m.Id, addonName, ct)); }
            catch { /* per-addon failure is not fatal */ }
        }
        return options;
    }

    private async Task<List<(string Id, string? Type, string Name)>> FetchCatalogAsync(string baseUrl, string type, string id, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl}/catalog/{type}/{id}.json");
        req.Headers.UserAgent.ParseAdd("Rally/Windows");
        using var res = await http.SendAsync(req, ct);
        res.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        var out_ = new List<(string, string?, string)>();
        if (!doc.RootElement.TryGetProperty("metas", out var metas)) return out_;
        foreach (var m in metas.EnumerateArray())
        {
            var mid = m.GetPropertyOrNull("id")?.GetString();
            var name = m.GetPropertyOrNull("name")?.GetString();
            if (mid is not null && !string.IsNullOrWhiteSpace(name))
                out_.Add((mid, m.GetPropertyOrNull("type")?.GetString(), name!));
        }
        return out_;
    }

    private async Task<List<StremioStreamOption>> FetchStreamsAsync(string baseUrl, string type, string metaId, string? addonName, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl}/stream/{type}/{metaId}.json");
        req.Headers.UserAgent.ParseAdd("Rally/Windows");
        using var res = await http.SendAsync(req, ct);
        res.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
        var out_ = new List<StremioStreamOption>();
        if (!doc.RootElement.TryGetProperty("streams", out var streams)) return out_;
        foreach (var s in streams.EnumerateArray())
        {
            var opt = ToOption(s, addonName);
            if (opt is not null) out_.Add(opt);
        }
        return out_;
    }

    internal static StremioStreamOption? ToOption(JsonElement s, string? addonName)
    {
        var url = s.GetPropertyOrNull("url")?.GetString();
        if (string.IsNullOrWhiteSpace(url)) return null;
        var lower = url.ToLowerInvariant();
        var isHtml = lower.Contains("youtube.com/watch") || lower.EndsWith(".html") || lower.Contains("external/");
        var title = string.Join(" ", new[] { s.GetPropertyOrNull("name")?.GetString(), s.GetPropertyOrNull("title")?.GetString() }
            .Where(x => !string.IsNullOrWhiteSpace(x))).Trim();
        Dictionary<string, string>? headers = null;
        if (s.GetPropertyOrNull("behaviorHints")?.GetPropertyOrNull("proxyHeaders")?.GetPropertyOrNull("request") is JsonElement rh
            && rh.ValueKind == JsonValueKind.Object)
        {
            headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var p in rh.EnumerateObject())
                if (AllowedHeaders.Contains(p.Name) && p.Value.GetString() is string v)
                    headers[p.Name] = v;
            if (headers.Count == 0) headers = null;
        }
        return new StremioStreamOption(
            string.IsNullOrWhiteSpace(title) ? (addonName ?? "Stream") : title,
            s.GetPropertyOrNull("description")?.GetString(), url,
            s.GetPropertyOrNull("name")?.GetString(), addonName, headers,
            !isHtml && s.GetPropertyOrNull("ytId")?.GetString() is null);
    }
}
