using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;

namespace Rally.Core;

public sealed record PlaybackQuality(int Height, long Bandwidth);
public sealed record PlaybackManifestInfo(IReadOnlyList<PlaybackQuality> Qualities, bool? IsLive, Uri? MediaPlaylist = null);
public sealed record PlaybackTimeline(bool IsLive, bool CanSeek, long Position, long Duration)
{
    public bool AtLiveEdge => IsLive && CanSeek && Duration - Position <= 5_000;
    public long LiveTarget => Math.Max(0, Duration - 1_500);
    public static PlaybackTimeline Create(bool live, bool seekable, long position, long duration, bool liveClockFresh = true) =>
        // Live seeks require both a current decoder clock and a position inside
        // the published window; stale live clocks cannot safely identify a seek range.
        new(live, seekable && duration > 0 && (!live || liveClockFresh && position <= duration), Math.Clamp(position, 0, Math.Max(0, duration)), Math.Max(0, duration));
    public long ClampSeek(long position) => Math.Clamp(position, 0, IsLive ? LiveTarget : Duration);
}

public static class PlaybackManifest
{
    public static PlaybackManifestInfo Parse(string text, Uri uri)
    {
        if (text.TrimStart().StartsWith("#EXTM3U", StringComparison.Ordinal))
        {
            var qualities = new List<PlaybackQuality>(); Uri? child = null;
            var lines = text.Split('\n').Select(l => l.Trim()).ToArray();
            for (var i = 0; i < lines.Length; i++)
            {
                if (!lines[i].StartsWith("#EXT-X-STREAM-INF:")) continue;
                var attributes = lines[i][(lines[i].IndexOf(':') + 1)..];
                var resolution = Regex.Match(attributes, @"(?:^|,)RESOLUTION=\d+x(\d+)");
                var bandwidth = Regex.Match(attributes, @"(?:^|,)BANDWIDTH=(\d+)");
                if (resolution.Success && int.TryParse(resolution.Groups[1].Value, out var height))
                    qualities.Add(new(height, long.TryParse(bandwidth.Groups[1].Value, out var rate) ? rate : 0));
                var next = lines.Skip(i + 1).FirstOrDefault(l => l.Length > 0 && !l.StartsWith('#'));
                if (child is null && Uri.TryCreate(uri, next, out var playlist)) child = playlist;
            }
            var media = lines.Any(l => l.StartsWith("#EXTINF:"));
            return new(qualities.DistinctBy(q => q.Height).OrderByDescending(q => q.Height).ToList(), media ? !lines.Contains("#EXT-X-ENDLIST") : null, child);
        }
        using var reader = XmlReader.Create(new StringReader(text), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 2_000_000 });
        var document = XDocument.Load(reader); var root = document.Root;
        if (root?.Name.LocalName != "MPD") return new([], null);
        var representations = root.Descendants().Where(e => e.Name.LocalName == "Representation")
            .Select(e => new PlaybackQuality(int.TryParse((string?)e.Attribute("height") ?? (string?)e.Parent?.Attribute("height"), out var h) ? h : 0,
                long.TryParse((string?)e.Attribute("bandwidth"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var b) ? b : 0))
            .Where(q => q.Height > 0).DistinctBy(q => q.Height).OrderByDescending(q => q.Height).ToList();
        return new(representations, string.Equals((string?)root.Attribute("type"), "dynamic", StringComparison.OrdinalIgnoreCase));
    }
}
