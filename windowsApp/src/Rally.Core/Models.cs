// 1:1 port of RallyCore Models.swift / Models.kt product models.
namespace Rally.Core;

public enum EventStatus { NotStarted, Live, Halftime, Finished, Delayed, Canceled }

public enum IptvProvider { Stalker, Xtream }

public sealed record Team(string Id, string Name, string Abbreviation, string? LogoUrl = null);

public sealed record SportEvent(
    string Id, string Name, Team? HomeTeam, Team? AwayTeam,
    DateTimeOffset StartTime, EventStatus Status,
    int? ScoreHome, int? ScoreAway,
    string Sport, string League, string? Venue = null, string? GameStatusDetail = null);

public sealed record StreamQualityInfo(string? Resolution, string? Fps, bool Is4K, bool Is60Fps, bool IsHdr);

public sealed record EpgProgram(string Title, string? Description, DateTimeOffset? StartTime, DateTimeOffset? EndTime);

public sealed record ChannelGuide(EpgProgram? Now, EpgProgram? Next, DateTimeOffset FetchedAt);

public sealed record IptvChannel(
    string Id, string Number, string Name, string Category = "Live TV",
    string? LogoUrl = null, string? StreamUrl = null, ChannelGuide? Guide = null,
    bool SupportsCatchUp = false, int? ArchiveDurationHours = null);

public sealed record FavoriteTeam(
    string Id, string League, string Name, string Abbreviation,
    string? LogoUrl = null)
{
    public string Key => $"{League}:{Id}";
}

public sealed record StremioStreamOption(
    string Title, string? Description, string StreamUrl,
    string? Quality = null, string? AddonName = null,
    Dictionary<string, string>? Headers = null, bool IsDirectPlayable = true);

public enum PlayKind { Stremio, Iptv }

public sealed record PlayCandidate(
    string Id, string Title, string Url,
    Dictionary<string, string>? Headers,
    PlayKind Kind, bool ExactMatch, int Rank,
    IptvChannel? Channel = null, string? AddonName = null);

public sealed record StreamHealth(int Successes = 0, int Failures = 0, int Stalls = 0, long AverageStartupMs = 0, long LastUpdatedMs = 0)
{
    // 1:1 with PreferencesManager.StreamHealth.score.
    public int Score => Math.Clamp(Successes * 24 - Failures * 55 - Stalls * 12 - (int)(AverageStartupMs / 750), -240, 120);
}

public static class Quality
{
    // 1:1 with parseQualityFromChannelName. Evidence-based only.
    public static StreamQualityInfo Parse(string name)
    {
        var upper = name.ToUpperInvariant();
        string? res =
            upper.Contains("4K") || upper.Contains("UHD") || upper.Contains("2160P") ? "4K" :
            upper.Contains("1080P") || upper.Contains("1080I") || upper.Contains("FHD") ? "1080p" :
            upper.Contains("720P") ? "720p" :
            upper.Contains(" HD") || upper.EndsWith("HD") || upper.Contains("| HD") || upper.Contains(": HD") ? "HD" : null;
        string? fps =
            upper.Contains("60FPS") || upper.Contains("60 FPS") || upper.Contains(" 60P") || upper.Contains(" 60 ") || upper.EndsWith(" 60") ? "60 fps" :
            upper.Contains("50FPS") || upper.Contains("50 FPS") || upper.Contains(" 50P") || upper.Contains(" 50 ") || upper.EndsWith(" 50") ? "50 fps" :
            upper.Contains("30FPS") || upper.Contains("30 FPS") ? "30 fps" :
            upper.Contains("25FPS") || upper.Contains("25 FPS") ? "25 fps" : null;
        var hdr = upper.Contains("HDR") || upper.Contains("HLG") || upper.Contains("DOLBY VISION") || upper == "DV" || upper.Contains(" DV");
        return new StreamQualityInfo(res, fps, res == "4K", fps == "60 fps", hdr);
    }
}
