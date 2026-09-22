using System.Text.Json;

// Atomic JSON disk cache with TTL. Mirrors DiskCache.swift: envelope with
// timestamp + payload, temp-dir injectable for tests.
namespace Rally.Core;

public sealed class DiskCache(string? directory = null)
{
    private readonly string _dir = directory
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Rally", "cache");

    private string PathFor(string name) => Path.Combine(_dir, name);

    public T? Load<T>(string name, TimeSpan maxAge)
    {
        try
        {
            Directory.CreateDirectory(_dir);
            var path = PathFor(name);
            if (!File.Exists(path)) return default;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            if (!root.TryGetProperty("savedAt", out var saved) || !saved.TryGetInt64(out var ms))
                return default;
            if (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - ms > maxAge.TotalMilliseconds)
                return default;
            if (!root.TryGetProperty("payload", out var payload)) return default;
            return payload.Deserialize<T>();
        }
        catch { return default; }
    }

    public T? LoadAny<T>(string name)
    {
        try
        {
            var path = PathFor(name);
            if (!File.Exists(path)) return default;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("payload", out var payload)) return default;
            return payload.Deserialize<T>();
        }
        catch { return default; }
    }

    public void Save<T>(T value, string name)
    {
        try
        {
            Directory.CreateDirectory(_dir);
            var tmp = PathFor(name + ".tmp");
            var json = JsonSerializer.Serialize(new { savedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), payload = value });
            File.WriteAllText(tmp, json);
            File.Move(tmp, PathFor(name), overwrite: true);
        }
        catch { }
    }
}

// Last-known-good ESPN schedule. 72h TTL; stale data beats an empty shelf.
public sealed class ScheduleStore(string? directory = null)
{
    public static readonly TimeSpan Ttl = TimeSpan.FromHours(72);
    private const string Name = "schedule.json";
    private readonly DiskCache _cache = new(directory);

    public List<SportEvent>? LoadFresh()
    {
        var events = _cache.Load<List<SportEvent>>(Name, Ttl);
        return events is { Count: > 0 } ? events : null;
    }

    public List<SportEvent>? LoadAny()
    {
        var events = _cache.LoadAny<List<SportEvent>>(Name);
        return events is { Count: > 0 } ? events : null;
    }

    public void Save(List<SportEvent> events)
    {
        if (events.Count == 0) return;
        _cache.Save(events, Name);
    }
}

// Persisted IPTV catalog, identity-gated like the in-memory cache.
public sealed class ChannelDiskStore(string? directory = null)
{
    public static readonly TimeSpan Ttl = TimeSpan.FromMinutes(15);
    private readonly DiskCache _cache = new(directory);

    public static string FileName(string identity)
    {
        var safe = new string(identity.ToLowerInvariant()
            .Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray());
        if (safe.Length > 64) safe = safe[..64];
        return $"channels-{safe}.json";
    }

    public List<IptvChannel>? LoadFresh(string identity)
    {
        var channels = _cache.Load<List<IptvChannel>>(FileName(identity), Ttl);
        return channels is { Count: > 0 } ? channels : null;
    }

    public List<IptvChannel>? LoadAny(string identity)
    {
        var channels = _cache.LoadAny<List<IptvChannel>>(FileName(identity));
        return channels is { Count: > 0 } ? channels : null;
    }

    public void Save(List<IptvChannel> channels, string identity)
    {
        if (channels.Count == 0) return;
        _cache.Save(channels, FileName(identity));
    }
}
