using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Rally.Core;

public sealed class StremioClient(HttpClient http)
{
    private readonly AsyncDataCache<JsonElement> _manifests = new(TimeSpan.FromMinutes(30), 32);
    private readonly AsyncDataCache<List<StremioStreamOption>> _streams = new(TimeSpan.FromSeconds(90), 128);

    public async Task<JsonDocument> FetchManifestAsync(string manifestUrl, CancellationToken ct = default)
    {
        var normalized = UrlNormalizer.NormalizeAddon(manifestUrl) ?? throw new ArgumentException("Invalid addon URL.");
        var root = await ManifestAsync(normalized, ct);
        return JsonDocument.Parse(root.GetRawText());
    }

    private Task<JsonElement> ManifestAsync(string url, CancellationToken ct) =>
        _manifests.GetAsync(url, () => JsonAsync(url, CancellationToken.None), false, ct);

    private async Task<JsonElement> JsonAsync(string url, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(8));
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.UserAgent.ParseAdd("Rally/Windows"); req.Headers.Accept.ParseAdd("application/json");
        using var response = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        response.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
        return doc.RootElement.Clone();
    }

    public Task<List<StremioStreamOption>> FindStreamsAsync(SportEvent ev, string addonBase, CancellationToken ct = default) =>
        DiscoverAsync(addonBase, ev, ev.Name, ct);
    public Task<List<StremioStreamOption>> RefreshStreamsAsync(SportEvent ev, string addonBase, CancellationToken ct = default) =>
        DiscoverAsync(addonBase, ev, ev.Name, ct, refresh: true);
    public Task<List<StremioStreamOption>> SearchAsync(string query, string addonBase, CancellationToken ct = default) =>
        DiscoverAsync(addonBase, null, query.Trim(), ct);

    private Task<List<StremioStreamOption>> DiscoverAsync(string addonBase, SportEvent? ev, string query, CancellationToken ct, bool refresh = false)
    {
        var normalized = UrlNormalizer.NormalizeAddon(addonBase) ?? throw new ArgumentException("Invalid addon URL.");
        var key = normalized + "|" + (ev is null ? query : ev.League + ":" + ev.Id);
        return _streams.GetAsync(key, () => DiscoverCoreAsync(normalized, ev, query, CancellationToken.None), refresh, ct);
    }
    private async Task<List<StremioStreamOption>> DiscoverCoreAsync(string normalized, SportEvent? ev, string query, CancellationToken ct)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(ct); budget.CancelAfter(TimeSpan.FromSeconds(20));
        var manifest = await ManifestAsync(normalized, budget.Token);
        var root = new Uri(normalized);
        var name = manifest.GetPropertyOrNull("name")?.GetString();
        var catalogs = manifest.GetPropertyOrNull("catalogs")?.EnumerateArray().ToList() ?? [];
        var selected = ev is null ? catalogs : catalogs.Where(c => Relevant(c, ev)).ToList();
        if (selected.Count == 0) selected = catalogs;
        using var concurrency = new SemaphoreSlim(4);
        var found = new ConcurrentBag<StremioStreamOption>();
        var succeeded = 0; var failed = 0;
        async Task<JsonElement> CatalogJsonAsync(string url, CancellationToken token)
        {
            try { var json = await JsonAsync(url, token); Interlocked.Increment(ref succeeded); return json; }
            catch { Interlocked.Increment(ref failed); throw; }
        }
        await Task.WhenAll(selected.Take(16).Select(async catalog => {
            var entered = false;
            try
            {
                await concurrency.WaitAsync(budget.Token); entered = true;
                var type = catalog.GetPropertyOrNull("type")?.GetString() ?? "sport";
                var id = catalog.GetPropertyOrNull("id")?.GetString(); if (id is null) return;
                var extras = catalog.GetPropertyOrNull("extra")?.EnumerateArray().ToList() ?? [];
                var required = new Dictionary<string, string>();
                foreach (var extra in extras.Where(e => e.GetPropertyOrNull("isRequired")?.GetBoolean() == true))
                {
                    var extraName = extra.GetPropertyOrNull("name")?.GetString();
                    if (extraName is null || extraName == "search") continue;
                    var option = extra.GetPropertyOrNull("options")?.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.String ? x.GetString() : null).FirstOrDefault();
                    if (extraName == "date") option = (ev?.StartTime ?? DateTimeOffset.UtcNow).ToString("yyyy-MM-dd");
                    if (option is null) return;
                    required[extraName] = option;
                }
                bool Matches(JsonElement meta)
                {
                    var text = (meta.GetPropertyOrNull("name")?.GetString() ?? "") + " " + (meta.GetPropertyOrNull("description")?.GetString() ?? "");
                    return ev is null ? text.Contains(query, StringComparison.OrdinalIgnoreCase) : MatchesEvent(text, ev);
                }
                var metas = new List<JsonElement>();
                var searchRequired = extras.Any(e => e.GetPropertyOrNull("name")?.GetString() == "search" && e.GetPropertyOrNull("isRequired")?.GetBoolean() == true);
                if (!searchRequired)
                {
                    try { var data = await CatalogJsonAsync(ResourceUrl(root, "catalog", type, id, required), budget.Token); metas.AddRange(data.GetPropertyOrNull("metas")?.EnumerateArray().Where(Matches) ?? []); }
                    catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
                    catch (HttpRequestException) { }
                }
                if (metas.Count == 0 && (!catalog.TryGetProperty("extra", out _) || extras.Any(e => e.GetPropertyOrNull("name")?.GetString() == "search")))
                {
                    var queries = ev is null ? [query] : new[] { ev.HomeTeam?.Name, ev.AwayTeam?.Name, query }
                        .OfType<string>().SelectMany(n => new[] { Keywords(n).FirstOrDefault() ?? n, n }).Distinct().Take(5).ToArray();
                    foreach (var search in queries)
                    {
                        if (budget.IsCancellationRequested) break;
                        var values = new Dictionary<string, string>(required) { ["search"] = search };
                        try { var data = await CatalogJsonAsync(ResourceUrl(root, "catalog", type, id, values), budget.Token); metas.AddRange(data.GetPropertyOrNull("metas")?.EnumerateArray().Where(Matches) ?? []); }
                        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
                        catch (HttpRequestException) { }
                        if (metas.Count > 0) break;
                    }
                }
                foreach (var meta in metas.DistinctBy(m => m.GetPropertyOrNull("id")?.GetString()).Take(8))
                {
                    if (budget.IsCancellationRequested) break;
                    var metaId = meta.GetPropertyOrNull("id")?.GetString(); if (metaId is null) continue;
                    try { var data = await CatalogJsonAsync(ResourceUrl(root, "stream", meta.GetPropertyOrNull("type")?.GetString() ?? type, metaId), budget.Token);
                        foreach (var stream in data.GetPropertyOrNull("streams")?.EnumerateArray() ?? []) if (ToOption(stream, name) is { } option) found.Add(option);
                    }
                    catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
                    catch (HttpRequestException) { }
                }
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
            catch (Exception) when (!ct.IsCancellationRequested) { /* isolate malformed catalogs */ }
            finally { if (entered) concurrency.Release(); }
        }));
        ct.ThrowIfCancellationRequested();
        if (failed > 0 && succeeded == 0) throw new HttpRequestException("The addon catalogs are unavailable.");
        var result = found.DistinctBy(s => s.StreamUrl, StringComparer.Ordinal).ToList();
        return result;
    }

    public void Invalidate() { _streams.Clear(); _manifests.Clear(); }

    private static bool Relevant(JsonElement catalog, SportEvent ev)
    {
        var text = ((catalog.GetPropertyOrNull("id")?.GetString() ?? "") + " " + (catalog.GetPropertyOrNull("name")?.GetString() ?? "")).ToLowerInvariant();
        var terms = ev.League switch { "NFL" or "NCAAF" => new[] { "american", "nfl", "college", "ncaa" },
            "NBA" or "NCAAB" => ["basket", "nba"], "MLB" => ["baseball", "mlb"], "NHL" => ["hockey", "nhl"], _ => [ev.Sport.ToLowerInvariant(), ev.League.ToLowerInvariant()] };
        return new[] { "live", "today", "schedule" }.Concat(terms).Any(text.Contains);
    }
    private static IEnumerable<string> Keywords(string value) => Regex.Matches(value.ToLowerInvariant(), "[\\p{L}\\p{N}]+")
        .Select(m => m.Value).Where(w => w.Length >= 3 && !new[] { "state", "university", "college", "city", "united", "the", "and" }.Contains(w));
    internal static bool MatchesEvent(string text, SportEvent ev)
    {
        var words = Keywords(text).ToHashSet();
        if (ev.HomeTeam is { } home && ev.AwayTeam is { } away)
        {
            var h = Keywords(home.Name).ToHashSet(); var a = Keywords(away.Name).ToHashSet();
            if (h.Except(a).Any(words.Contains) && a.Except(h).Any(words.Contains)) return true;
            var all = Regex.Matches(text.ToLowerInvariant(), "[\\p{L}\\p{N}]+").Select(m => m.Value).ToHashSet();
            if (home.Abbreviation != away.Abbreviation && all.Contains(home.Abbreviation.ToLowerInvariant()) && all.Contains(away.Abbreviation.ToLowerInvariant())) return true;
        }
        return ev.Name.Length > 5 && text.Contains(ev.Name, StringComparison.OrdinalIgnoreCase);
    }
    internal static string ResourceUrl(Uri manifest, string resource, string type, string id, IDictionary<string, string>? extras = null)
    {
        var path = manifest.GetLeftPart(UriPartial.Path); path = path[..path.LastIndexOf('/')];
        var parts = string.Join("/", new[] { resource, type, id }.Select(Uri.EscapeDataString));
        var filter = extras?.Count > 0 ? "/" + string.Join("&", extras.OrderBy(p => p.Key).Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value))) : "";
        return path + "/" + parts + filter + ".json" + manifest.Query;
    }
    internal static StremioStreamOption? ToOption(JsonElement s, string? addonName)
    {
        var title = string.Join(" ", new[] { s.GetPropertyOrNull("name")?.GetString(), s.GetPropertyOrNull("title")?.GetString() }.Where(x => !string.IsNullOrWhiteSpace(x))).Trim();
        if (title.Contains("🔒") || title.Contains("upgrade to", StringComparison.OrdinalIgnoreCase)) return null;
        var raw = s.GetPropertyOrNull("url")?.GetString() ?? s.GetPropertyOrNull("externalUrl")?.GetString();
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var url) || url.Scheme is not ("https" or "http")) return null;
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (s.GetPropertyOrNull("behaviorHints")?.GetPropertyOrNull("proxyHeaders")?.GetPropertyOrNull("request") is { ValueKind: JsonValueKind.Object } rh)
            foreach (var p in rh.EnumerateObject()) if (p.Value.ValueKind == JsonValueKind.String) headers[p.Name] = p.Value.GetString()!;
        var clean = StreamRequestHeaders.Sanitize(headers);
        var browser = s.GetPropertyOrNull("externalUrl") is not null || url.Host.Contains("youtube.", StringComparison.OrdinalIgnoreCase) || url.AbsolutePath.EndsWith(".html", StringComparison.OrdinalIgnoreCase);
        return new StremioStreamOption(string.IsNullOrWhiteSpace(title) ? addonName ?? "Stream" : title,
            s.GetPropertyOrNull("description")?.GetString(), url.AbsoluteUri, s.GetPropertyOrNull("name")?.GetString(), addonName,
            clean.Count > 0 ? clean : null, !browser && s.GetPropertyOrNull("ytId") is null);
    }
}
