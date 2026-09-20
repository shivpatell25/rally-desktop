// v1 candidate ranking. Mirrors StreamResolver.swift: exact-game matches
// first, then evidence-based quality rank.
namespace Rally.Core;

public static class StreamResolver
{
    public static List<PlayCandidate> Candidates(SportEvent ev, List<IptvChannel> channels, List<StremioStreamOption> options)
    {
        var out_ = new List<PlayCandidate>();
        foreach (var opt in options.Where(o => o.IsDirectPlayable))
        {
            var text = $"{opt.Title} {opt.Description ?? ""}";
            out_.Add(new PlayCandidate(Guid.NewGuid().ToString(), opt.Title, opt.StreamUrl, opt.Headers,
                PlayKind.Stremio, StreamSelector.TextMatchesEvent(text, ev),
                StreamSelector.QualityRank(Quality.Parse(opt.Quality ?? opt.Title)), null, opt.AddonName));
        }
        foreach (var ch in channels)
        {
            var guideText = string.Join(" ", new[] { ch.Guide?.Now?.Title, ch.Guide?.Next?.Title }.Where(x => x is not null));
            var exact = StreamSelector.TextMatchesEvent(ch.Name, ev)
                || (!string.IsNullOrEmpty(guideText) && StreamSelector.TextMatchesEvent(guideText, ev));
            if (!exact && !ch.Name.Contains(ev.League, StringComparison.OrdinalIgnoreCase)) continue;
            out_.Add(new PlayCandidate(Guid.NewGuid().ToString(), ch.Name, ch.StreamUrl ?? ch.Id, null,
                PlayKind.Iptv, exact, StreamSelector.QualityRank(Quality.Parse(ch.Name)), ch));
        }
        return out_.OrderByDescending(c => c.ExactMatch).ThenByDescending(c => c.Rank).ToList();
    }

    public static List<PlayCandidate> ChannelCandidates(List<IptvChannel> channels) =>
        channels.Select(ch => new PlayCandidate(Guid.NewGuid().ToString(), ch.Name, ch.StreamUrl ?? ch.Id, null,
            PlayKind.Iptv, true, StreamSelector.QualityRank(Quality.Parse(ch.Name)), ch)).ToList();
}
