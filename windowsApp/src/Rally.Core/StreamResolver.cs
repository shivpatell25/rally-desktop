// Candidate ranking. Mirrors SelectBestStreamUseCase ordering: exact-game
// first, then preflight-verified, then quality rank blended with stream-health
// score, Stremio-first, confidence, title. Health is URL-keyed; pass a lookup
// so sorting stays pure.
namespace Rally.Core;

public static class StreamResolver
{
    public static List<PlayCandidate> Candidates(
        SportEvent ev, List<IptvChannel> channels, List<StremioStreamOption> options,
        Func<string, int>? health = null, IReadOnlyList<string>? tvStations = null)
    {
        health ??= _ => 0;
        var out_ = new List<PlayCandidate>();
        // Addon results are already scoped to the event by FindStreamsAsync,
        // so every direct-playable option is an exact match (toCandidate).
        foreach (var opt in options.Where(o => o.IsDirectPlayable))
        {
            var quality = Quality.Parse(string.Join(" ", new[] { opt.Title, opt.Description, opt.Quality }.Where(x => x is not null)));
            out_.Add(new PlayCandidate(Guid.NewGuid().ToString(), opt.Title, opt.StreamUrl, opt.Headers,
                PlayKind.Stremio, true, StreamSelector.QualityRank(quality), null, opt.AddonName,
                null, null, null, 0.98f, "Exact event match"));
        }
        var relevant = EventMatcher.GetRelevantChannels(ev, channels, tvStations)
            .ToDictionary(r => r.Channel.Id);
        foreach (var ch in channels)
        {
            var guideTitle = ch.Guide?.Now?.Title ?? "";
            var exactFromGuide = guideTitle.Length > 0 && StreamSelector.TextMatchesEvent(guideTitle, ev);
            var exactFromName = StreamSelector.TextMatchesEvent(ch.Name, ev);
            var redZone = ch.Name.Contains("redzone", StringComparison.OrdinalIgnoreCase) ||
                ch.Name.Contains("red zone", StringComparison.OrdinalIgnoreCase);
            relevant.TryGetValue(ch.Id, out var match);
            var exact = !redZone && (exactFromGuide || (exactFromName && (match?.LikelihoodScore ?? 0) >= 90));
            if (!exact && !relevant.ContainsKey(ch.Id) &&
                !ch.Name.Contains(ev.League, StringComparison.OrdinalIgnoreCase)) continue;
            var quality = Quality.Parse(ch.Name + " " + guideTitle);
            string? evidence = exactFromGuide ? $"Now playing: {guideTitle}"
                : exactFromName ? "Dedicated matchup channel"
                : !string.IsNullOrEmpty(guideTitle) ? $"Now playing: {guideTitle}"
                : match?.MatchBadge ?? "Unverified channel";
            out_.Add(new PlayCandidate(Guid.NewGuid().ToString(), ch.Name, ch.StreamUrl ?? ch.Id, null,
                PlayKind.Iptv, exact, StreamSelector.QualityRank(quality), ch,
                null, null, null, null, exact ? 0.9f : 0.25f, evidence));
        }
        var ranked = Sort(out_, health);
        // Addons often return the same URL across matched metas — collapse
        // duplicates (keep best rank) and cap the picker list.
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return ranked.Where(c => seen.Add(c.Url.Trim().ToLowerInvariant())).Take(40).ToList();
    }

    public static List<PlayCandidate> Sort(List<PlayCandidate> cands, Func<string, int>? health = null)
    {
        health ??= _ => 0;
        return cands.OrderByDescending(c => c.ExactMatch)
            .ThenByDescending(c => c.PreflightPassed != false)
            .ThenByDescending(c => c.Rank + health(c.Url))
            .ThenByDescending(c => c.Kind == PlayKind.Stremio)
            .ThenByDescending(c => c.MatchConfidence)
            .ThenBy(c => c.Title, StringComparer.Ordinal).ToList();
    }

    // Primary must be an exact match that hasn't failed verification.
    public static PlayCandidate? Primary(List<PlayCandidate> cands) =>
        cands.FirstOrDefault(c => c.ExactMatch && c.PreflightPassed != false);

    public static List<PlayCandidate> ChannelCandidates(List<IptvChannel> channels) =>
        channels.Select(ch => new PlayCandidate(Guid.NewGuid().ToString(), ch.Name, ch.StreamUrl ?? ch.Id, null,
            PlayKind.Iptv, true, StreamSelector.QualityRank(Quality.Parse(ch.Name)), ch)).ToList();
}
