// 1:1 port of StreamSelector (StreamSelector.swift / SelectBestStreamUseCase.kt).
namespace Rally.Core;

public static class StreamSelector
{
    public static string Normalize(string value)
    {
        var mapped = value.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : ' ');
        return string.Join(" ", new string([.. mapped]).Split(' ', StringSplitOptions.RemoveEmptyEntries)).Trim();
    }

    public static bool TeamMatches(string normalizedText, string teamName, string abbreviation)
    {
        var teamNorm = Normalize(teamName);
        if (teamNorm.Length == 0) return false;
        if (normalizedText.Contains(teamNorm, StringComparison.Ordinal)) return true;
        var abbr = abbreviation.Trim().ToLowerInvariant();
        if (abbr.Length >= 2 && normalizedText.Split(' ').Contains(abbr)) return true;
        var stop = new HashSet<string> { "fc", "cf", "sc", "ac", "cd", "ud", "rc", "bk", "if", "fk", "city", "united", "club", "real", "de", "la", "the", "athletic" };
        return teamNorm.Split(' ').Where(w => w.Length > 2 && !stop.Contains(w))
            .Any(w => normalizedText.Split(' ').Contains(w));
    }

    public static bool TextMatchesEvent(string text, SportEvent ev)
    {
        var norm = Normalize(text);
        if (norm.Length == 0) return false;
        var homeOk = ev.HomeTeam is not null && TeamMatches(norm, ev.HomeTeam.Name, ev.HomeTeam.Abbreviation);
        var awayOk = ev.AwayTeam is not null && TeamMatches(norm, ev.AwayTeam.Name, ev.AwayTeam.Abbreviation);
        return homeOk && awayOk;
    }

    // 1:1 with qualityRank in SelectBestStreamUseCase.kt — higher wins:
    // 4K(700) > 1080p(500) > 720p/HD(300) > unknown(100), HDR +60, 60fps +30.
    public static int QualityRank(StreamQualityInfo q)
    {
        var baseRank = q.Is4K ? 700 : q.Resolution switch { "1080p" => 500, "720p" or "HD" => 300, _ => 100 };
        if (q.IsHdr) baseRank += 60;
        if (q.Is60Fps) baseRank += 30;
        return baseRank;
    }
}
