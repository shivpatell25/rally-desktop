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
    private sealed class SharedState
    {
        public readonly System.Collections.Concurrent.ConcurrentDictionary<string, JsonElement> Preferences = new();
        public readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> Secrets = new();
        public readonly object Gate = new();
        public bool Loaded;
        public bool PreferencesWriteFailed, SecretsWriteFailed;
        public string? PersistenceError;
        public event Action<string>? Changed;
        public void Notify(string key) => Changed?.Invoke(key);
    }
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, SharedState> States = new(StringComparer.OrdinalIgnoreCase);
    private readonly SharedState _state;
    private System.Collections.Concurrent.ConcurrentDictionary<string, JsonElement> _prefs => _state.Preferences;
    private System.Collections.Concurrent.ConcurrentDictionary<string, string> _secrets => _state.Secrets;

    public SettingsStore(string? dir = null)
    {
        _dir = dir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Rally");
        Directory.CreateDirectory(_dir);
        _prefsPath = Path.Combine(_dir, "settings.json");
        _secretsPath = Path.Combine(_dir, "secrets.dat");
        _state = States.GetOrAdd(Path.GetFullPath(_dir), _ => new SharedState());
        lock (_state.Gate)
        {
            if (!_state.Loaded) { Load(); _state.Loaded = true; }
        }
    }

    public event Action<string> Changed { add => _state.Changed += value; remove => _state.Changed -= value; }

    public string? PersistenceError => _state.PersistenceError;

    public string CacheDirectory => Path.Combine(_dir, "cache");

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
            var protectedValue = Secret("stremio_addon_urls");
            if (protectedValue.Length > 0) { try { return JsonSerializer.Deserialize<List<string>>(protectedValue) ?? []; } catch { return []; } }
            var list = Arr("stremio_addon_urls");
            var legacy = (Str("stremio_addon_url") ?? "").Trim();
            if (list is null && legacy.Length > 0 && UrlNormalizer.NormalizeAddon(legacy) is string norm) list = [norm];
            if (list is not null) { StremioAddonUrls = list; return list; }
            return [DefaultAddon];
        }
        set
        {
            lock (_state.Gate)
            {
                SetSecret("stremio_addon_urls", JsonSerializer.Serialize(value.Select(u => UrlNormalizer.NormalizeAddon(u)).OfType<string>().Distinct().ToList()));
                _prefs.TryRemove("stremio_addon_urls", out _); _prefs.TryRemove("stremio_addon_url", out _); Save();
            }
        }
    }
    public string M3uUrl { get => Secret("m3u_url"); set => SetSecret("m3u_url", value.Trim()); }
    public string XmltvUrl { get => Secret("xmltv_url"); set => SetSecret("xmltv_url", value.Trim()); }
    public bool HighContrastFocus { get => Bool("high_contrast_focus", false); set => Set("high_contrast_focus", value); }
    public bool SpokenScoreSummaries { get => Bool("spoken_score_summaries", false); set => Set("spoken_score_summaries", value); }
    public bool ScoreSaverEnabled { get => Bool("score_saver", true); set => Set("score_saver", value); }
    public bool FollowFocusedAudio { get => Bool("follow_focused_audio", false); set => Set("follow_focused_audio", value); }
    public List<string> DisabledLeagues { get => Arr("disabled_leagues") ?? []; set => Set("disabled_leagues", value.Distinct().ToList()); }
    public List<SportEvent> SavedEvents
    {
        get
        {
            try { return _prefs.TryGetValue("saved_events", out var data) ? data.Deserialize<List<SportEvent>>() ?? [] : []; }
            catch { return []; }
        }
        set => Set("saved_events", value.DistinctBy(e => $"{e.League}:{e.Id}").ToList());
    }
    public bool ToggleSavedEvent(SportEvent ev)
    {
        lock (_state.Gate)
        {
            var events = SavedEvents; var index = events.FindIndex(e => e.Id == ev.Id && e.League == ev.League);
            if (index >= 0) events.RemoveAt(index); else events.Add(ev);
            SavedEvents = events; return index < 0;
        }
    }
    public bool IsSavedEvent(SportEvent ev) => SavedEvents.Any(e => e.Id == ev.Id && e.League == ev.League);
    private static readonly string[] PortableKeys = ["sports_order", "disabled_leagues", "favorite_team_profiles_v2", "saved_events", "live_game_alerts_enabled", "redzone_alerts_enabled", "low_latency_mode", "audio_normalization_enabled", "adaptive_quality_enabled", "reduced_motion", "large_text", "score_saver", "follow_focused_audio", "high_contrast_focus", "spoken_score_summaries"];
    public string ExportPreferences() => JsonSerializer.Serialize(_prefs.Where(p => PortableKeys.Contains(p.Key)).ToDictionary(p => p.Key, p => p.Value), new JsonSerializerOptions { WriteIndented = true });
    public void ImportPreferences(string json)
    {
        var values = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json) ?? throw new InvalidDataException("Invalid preferences backup.");
        lock (_state.Gate) { foreach (var pair in values.Where(p => PortableKeys.Contains(p.Key))) _prefs[pair.Key] = pair.Value.Clone(); Save(); }
        _state.Notify("preferences_imported");
    }
    private static void AtomicWrite(string path, byte[] data)
    {
        var temporary = path + ".tmp"; File.WriteAllBytes(temporary, data); File.Move(temporary, path, overwrite: true);
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
        lock (_state.Gate)
        {
            var current = FavoriteTeamProfiles;
            var existing = current.FindIndex(t => t.Key == team.Key);
            if (existing >= 0) current.RemoveAt(existing); else current.Add(team);
            FavoriteTeamProfiles = current; return existing < 0;
        }
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
        lock (_state.Gate) { _prefs[key] = JsonSerializer.SerializeToElement(value); Save(); }
        _state.Notify(key);
    }

    private string Secret(string key) => _secrets.TryGetValue(key, out var v) ? v : "";

    private void SetSecret(string key, string value)
    {
        lock (_state.Gate) { _secrets[key] = value; SaveSecrets(); }
        _state.Notify(key);
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_prefsPath))
                foreach (var pair in JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(_prefsPath)) ?? new()) _prefs[pair.Key] = pair.Value;
        }
        catch { _prefs.Clear(); }
        try
        {
            if (File.Exists(_secretsPath))
            {
                var raw = File.ReadAllBytes(_secretsPath);
                var json = OperatingSystem.IsWindows()
                    ? System.Text.Encoding.UTF8.GetString(ProtectedData.Unprotect(raw, null, DataProtectionScope.CurrentUser))
                    : System.Text.Encoding.UTF8.GetString(raw);
                foreach (var pair in JsonSerializer.Deserialize<Dictionary<string, string>>(json) ?? new()) _secrets[pair.Key] = pair.Value;
            }
        }
        catch { _secrets.Clear(); }
    }

    private void Save()
    {
        try { AtomicWrite(_prefsPath, System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(_prefs))); _state.PreferencesWriteFailed = false; ClearPersistenceError(); }
        catch { _state.PreferencesWriteFailed = true; ReportPersistenceError(); }
    }

    private void SaveSecrets()
    {
        try
        {
            var raw = System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(_secrets));
            var out_ = OperatingSystem.IsWindows() ? ProtectedData.Protect(raw, null, DataProtectionScope.CurrentUser) : raw;
            AtomicWrite(_secretsPath, out_); _state.SecretsWriteFailed = false; ClearPersistenceError();
        }
        catch { _state.SecretsWriteFailed = true; ReportPersistenceError(); }
    }
    private void ClearPersistenceError()
    {
        if (!_state.PreferencesWriteFailed && !_state.SecretsWriteFailed) _state.PersistenceError = null;
    }
    private void ReportPersistenceError()
    {
        _state.PersistenceError = "Rally could not save your changes to this Windows profile. They remain available for this session. Check that your profile has free space and is writable, then save again.";
        _state.Notify("persistence_error");
    }
}
