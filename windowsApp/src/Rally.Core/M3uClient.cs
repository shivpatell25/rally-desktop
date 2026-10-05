using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;

namespace Rally.Core;

public sealed partial class M3uClient(HttpClient http, SettingsStore settings)
{
    public async Task<List<IptvChannel>> GetChannelsAsync(CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(settings.M3uUrl)) return [];
        var source = settings.M3uUrl;
        var text = Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https"
            ? await http.GetStringAsync(uri, ct) : await File.ReadAllTextAsync(source, ct);
        return Parse(text, uri);
    }

    public static List<IptvChannel> Parse(string text, Uri? baseUri = null)
    {
        // An HLS manifest is a single stream, not an IPTV channel directory.
        if (text.Split('\n').Any(l => l.TrimStart().StartsWith("#EXT-X-", StringComparison.OrdinalIgnoreCase)))
        {
            if (baseUri?.Scheme is not ("http" or "https")) return [];
            return [new IptvChannel("m3u-direct", "1", "Playlist stream", StreamUrl: baseUri.AbsoluteUri)];
        }
        var channels = new List<IptvChannel>();
        var attributes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var name = "";
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimStart('\uFEFF');
            if (line.StartsWith("#EXTINF:", StringComparison.OrdinalIgnoreCase))
            {
                attributes = AttributeRegex().Matches(line).GroupBy(m => m.Groups[1].Value, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.Last().Groups[2].Value, StringComparer.OrdinalIgnoreCase);
                // A quoted attribute may contain commas; the display name begins
                // after the first comma outside quoted values.
                var quoted = false; var comma = -1;
                for (var i = 0; i < line.Length; i++)
                {
                    if (line[i] == '"') quoted = !quoted;
                    if (line[i] == ',' && !quoted) { comma = i; break; }
                }
                name = comma >= 0 ? line[(comma + 1)..].Trim() : "";
            }
            else if (line.Length > 0 && !line.StartsWith('#'))
            {
                if (!Uri.TryCreate(line, UriKind.Absolute, out var stream) &&
                    (baseUri is null || !Uri.TryCreate(baseUri, line, out stream))) continue;
                if (stream.Scheme is not ("http" or "https" or "rtsp" or "rtmp" or "udp")) continue;
                var guideId = attributes.GetValueOrDefault("tvg-id");
                var title = name.Length > 0 ? name : attributes.GetValueOrDefault("tvg-name") ?? $"Channel {channels.Count + 1}";
                var id = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(stream.AbsoluteUri)))[..20];
                channels.Add(new IptvChannel(id, attributes.GetValueOrDefault("tvg-chno") ?? (channels.Count + 1).ToString(), title,
                    attributes.GetValueOrDefault("group-title") ?? "Live TV", attributes.GetValueOrDefault("tvg-logo"),
                    stream.AbsoluteUri, GuideId: guideId));
                attributes.Clear(); name = "";
            }
        }
        return channels.DistinctBy(c => c.StreamUrl).ToList();
    }

    public async Task<List<IptvChannel>> WithGuideAsync(List<IptvChannel> channels, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(settings.XmltvUrl)) return channels;
        var text = Uri.TryCreate(settings.XmltvUrl, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https"
            ? await http.GetStringAsync(uri, ct) : await File.ReadAllTextAsync(settings.XmltvUrl, ct);
        var guides = ParseGuide(text, DateTimeOffset.UtcNow);
        return channels.Select(c => guides.TryGetValue(c.GuideId ?? c.Id, out var guide) ? c with { Guide = guide } : c).ToList();
    }

    public static Dictionary<string, ChannelGuide> ParseGuide(string xml, DateTimeOffset now)
    {
        using var reader = XmlReader.Create(new StringReader(xml), new XmlReaderSettings {
            DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 30_000_000 });
        var document = XDocument.Load(reader);
        var groups = new Dictionary<string, List<EpgProgram>>(StringComparer.Ordinal);
        foreach (var p in document.Descendants("programme"))
        {
            var id = (string?)p.Attribute("channel");
            static DateTimeOffset? Time(string? value)
            {
                if (value is null) return null;
                var normalized = value.Trim();
                if (normalized.Length == 20 && normalized[14] == ' ')
                    normalized = normalized[..18] + ":" + normalized[18..];
                return DateTimeOffset.TryParseExact(normalized, ["yyyyMMddHHmmss zzz", "yyyyMMddHHmmss"],
                    CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : null;
            }
            var start = Time((string?)p.Attribute("start")); var end = Time((string?)p.Attribute("stop"));
            if (id is null || start is null || end is null || end <= now) continue;
            if (!groups.TryGetValue(id, out var programs)) groups[id] = programs = [];
            programs.Add(new EpgProgram(p.Element("title")?.Value ?? "Program", p.Element("desc")?.Value, start, end));
        }
        return groups.ToDictionary(pair => pair.Key, pair => {
            var ordered = pair.Value.OrderBy(p => p.StartTime).ToList();
            return new ChannelGuide(ordered.FirstOrDefault(p => p.StartTime <= now && p.EndTime > now),
                ordered.FirstOrDefault(p => p.StartTime > now), now);
        });
    }

    [GeneratedRegex("([\\w-]+)=\"([^\"]*)\"")]
    private static partial Regex AttributeRegex();
}
