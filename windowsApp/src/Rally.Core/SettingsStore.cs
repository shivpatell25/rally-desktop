using System.Security.Cryptography;
using System.Text.Json;

// Settings + secrets. Mirrors SettingsStore.swift / PreferencesManager keys.
// Prefs in %LocalAppData%/Rally/settings.json; token + Xtream password via
// DPAPI on Windows, restricted file elsewhere.
namespace Rally.Core;

public sealed class SettingsStore
{
    public const string DefaultAddon = "https://sports.highfly.to/manifest.json";
    public static readonly string[] DefaultSportsOrder =
        ["NFL", "NCAAF", "NBA", "NCAAB", "MLB", "NHL", "EPL", "La Liga", "Champions League", "Serie A"];

    private readonly string _dir;
    private readonly string _prefsPath;
    private readonly string _secretsPath;
    private Dictionary<string, JsonElement> _prefs = new();
    private Dictionary<string, string> _secrets = new();

    public SettingsStore(string? dir = null)
    {
        _dir = dir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Rally");
        Directory.CreateDirectory(_dir);
        _prefsPath = Path.Combine(_dir, "settings.json");
        _secretsPath = Path.Combine(_dir, "secrets.dat");
        Load();
    }

    public IptvProvider IptvProvider
    {
        get => Enum.TryParse<IptvProvider>(Str("iptv_provider"), out var p) ? p : IptvProvider.Stalker;
        set => Set("iptv_provider", value.ToString());
    }
    public string PortalUrl
    {
        get => Str("portal_url") ?? "";
        set => Set("portal_url", UrlNormalizer.NormalizePortal(value));
    }
    public string XtreamServerUrl
    {
        get => Str("xtream_server_url") ?? "";
        set => Set("xtream_server_url", UrlNormalizer.NormalizeXtreamServer(value));
    }
    public string XtreamUsername
    {
        get => Str("xtream_username") ?? "";
        set => Set("xtream_username", value.Trim());
    }
    public string XtreamPassword
    {
        get => Secret("xtream_password");
        set => SetSecret("xtream_password", value);
    }
    public string AuthToken
    {
        get => Secret("auth_token");
        set => SetSecret("auth_token", value);
    }
    public string MacAddress
    {
        get
        {
            var saved = (Str("mac_address") ?? "").Trim();
            if (saved.Length > 0) return saved;
            var mac = "00:1A:79:" + string.Join(":", Enumerable.Range(0, 3).Select(_ => RandomNumberGenerator.GetInt32(256).ToString("X2")));
            Set("mac_address", mac);
            return mac;
        }
        set => Set("mac_address", value.Trim());
    }
    public string SerialNumber
    {
        get => Str("serial_number") ?? "";
        set => Set("serial_number", value);
    }
    public string DeviceId
    {
        get => Str("device_id") ?? "";
        set => Set("device_id", value);
    }
    public List<string> StremioAddonUrls
    {
        get
        {
            if (Arr("stremio_addon_urls") is List<string> list && list.Count > 0) return list;
            var legacy = (Str("stremio_addon_url") ?? "").Trim();
            if (legacy.Length > 0 && UrlNormalizer.NormalizeAddon(legacy) is string norm) return [norm];
            return [DefaultAddon];
        }
        set => Set("stremio_addon_urls", value.Select(u => UrlNormalizer.NormalizeAddon(u)).OfType<string>().Distinct().OrderBy(x => x).ToList());
    }
    public string ChannelCacheIdentity
    {
        get => Str("channel_cache_identity") ?? "";
        set => Set("channel_cache_identity", value);
    }
    public bool SetupComplete
    {
        get => Bool("setup_complete", false);
        set => Set("setup_complete", value);
    }
    public bool LiveGameAlertsEnabled
    {
        get => Bool("live_game_alerts_enabled", true);
        set => Set("live_game_alerts_enabled", value);
    }
    public bool RedZoneAlertsEnabled
    {
        get => Bool("redzone_alerts_enabled", true);
        set => Set("redzone_alerts_enabled", value);
    }
    public bool LowLatencyMode
    {
        get => Bool("low_latency_mode", true);
        set => Set("low_latency_mode", value);
    }
    public bool AudioNormalizationEnabled
    {
        get => Bool("audio_normalization_enabled", true);
        set => Set("audio_normalization_enabled", value);
    }
    public bool AdaptiveQualityEnabled
    {
        get => Bool("adaptive_quality_enabled", true);
        set => Set("adaptive_quality_enabled", value);
    }
    public bool ReducedMotion
    {
        get => Bool("reduced_motion", false);
        set => Set("reduced_motion", value);
    }
    public bool LargeText
    {
        get => Bool("large_text", false);
        set => Set("large_text", value);
    }
    public List<FavoriteTeam> FavoriteTeamProfiles
    {
        get
        {
            try
            {
                if (_prefs.TryGetValue("favorite_team_profiles_v2", out var el) && el.ValueKind == JsonValueKind.Array)
                    return el.Deserialize<List<FavoriteTeam>>() ?? [];
            }
            catch { }
            return [];
        }
        set
        {
            var deduped = value.DistinctBy(t => t.Key).ToList();
            Set("favorite_team_profiles_v2", deduped);
        }
    }
    public List<string> SportsOrder
    {
        get
        {
            var raw = Str("sports_order");
            if (string.IsNullOrEmpty(raw)) return [.. DefaultSportsOrder];
            var saved = raw.Split(',').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
            return [.. saved, .. DefaultSportsOrder.Where(d => !saved.Contains(d))];
        }
        set => Set("sports_order", string.Join(",", value));
    }

    public bool HasCredentials => SetupComplete || PortalUrl.Length > 0 || StremioAddonUrls.Count > 0;

    public bool ToggleFavoriteTeam(FavoriteTeam team)
    {
        var current = FavoriteTeamProfiles;
        var existing = current.FindIndex(t => t.Key == team.Key);
        if (existing >= 0) { current.RemoveAt(existing); FavoriteTeamProfiles = current; return false; }
        current.Add(team);
        FavoriteTeamProfiles = current;
        return true;
    }

    public bool IsFavoriteTeam(string id, string league) =>
        FavoriteTeamProfiles.Any(t => t.Id == id && t.League.Equals(league, StringComparison.OrdinalIgnoreCase));

    public StreamHealth GetStreamHealth(string target)
    {
        try
        {
            if (_prefs.TryGetValue("stream_health_" + HealthKey(target), out var el))
                return el.Deserialize<StreamHealth>() ?? new StreamHealth();
        }
        catch { }
        return new StreamHealth();
    }
    public void RecordStreamSuccess(string target, long startupMs)
    {
        var h = GetStreamHealth(target);
        var successes = Math.Min(100, h.Successes + 1);
        var avg = successes <= 1 ? startupMs : (h.AverageStartupMs * (successes - 1) + startupMs) / successes;
        SaveHealth(target, h with { Successes = successes, AverageStartupMs = avg, LastUpdatedMs = NowMs() });
    }
    public void RecordStreamFailure(string target)
    {
        var h = GetStreamHealth(target);
        SaveHealth(target, h with { Failures = Math.Min(100, h.Failures + 1), LastUpdatedMs = NowMs() });
    }
    public void RecordStreamStall(string target)
    {
        var h = GetStreamHealth(target);
        SaveHealth(target, h with { Stalls = Math.Min(200, h.Stalls + 1), LastUpdatedMs = NowMs() });
    }
    private void SaveHealth(string target, StreamHealth h) => Set("stream_health_" + HealthKey(target), h);

    internal static string HealthKey(string target) =>
        Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(target)))[..20].ToLowerInvariant();

    private static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    private string? Str(string key) =>
        _prefs.TryGetValue(key, out var el) && el.ValueKind == JsonValueKind.String ? el.GetString() : null;

    private List<string>? Arr(string key)
    {
        try
        {
            if (_prefs.TryGetValue(key, out var el) && el.ValueKind == JsonValueKind.Array)
                return el.Deserialize<List<string>>();
        }
        catch { }
        return null;
    }

    private bool Bool(string key, bool fallback) =>
        _prefs.TryGetValue(key, out var el) && el.ValueKind is JsonValueKind.True or JsonValueKind.False ? el.GetBoolean() : fallback;

    private void Set(string key, object? value)
    {
        _prefs[key] = JsonSerializer.SerializeToElement(value);
        Save();
    }

    private string Secret(string key) => _secrets.TryGetValue(key, out var v) ? v : "";

    private void SetSecret(string key, string value)
    {
        _secrets[key] = value;
        SaveSecrets();
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_prefsPath))
                _prefs = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(_prefsPath)) ?? new();
        }
        catch { _prefs = new(); }
        try
        {
            if (File.Exists(_secretsPath))
            {
                var raw = File.ReadAllBytes(_secretsPath);
                var json = OperatingSystem.IsWindows()
                    ? System.Text.Encoding.UTF8.GetString(ProtectedData.Unprotect(raw, null, DataProtectionScope.CurrentUser))
                    : System.Text.Encoding.UTF8.GetString(raw);
                _secrets = JsonSerializer.Deserialize<Dictionary<string, string>>(json) ?? new();
            }
        }
        catch { _secrets = new(); }
    }

    private void Save()
    {
        try { File.WriteAllText(_prefsPath, JsonSerializer.Serialize(_prefs)); } catch { }
    }

    private void SaveSecrets()
    {
        try
        {
            var raw = System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(_secrets));
            var out_ = OperatingSystem.IsWindows() ? ProtectedData.Protect(raw, null, DataProtectionScope.CurrentUser) : raw;
            File.WriteAllBytes(_secretsPath, out_);
        }
        catch { }
    }
}
