namespace Rally.Core;

/// <summary>One data owner for every destination. Refreshes coalesce and source
/// configuration changes invalidate catalogs before a new playback request.</summary>
public sealed class RallyRepository
{
    public SettingsStore Settings { get; }
    public HttpClient Http { get; }
    public EspnClient Espn { get; }
    public EspnDetail Details { get; }
    public StremioClient Addons { get; }
    public StalkerClient Stalker { get; private set; }
    public XtreamClient Xtream { get; private set; }
    public M3uClient Playlists { get; private set; }
    private readonly SemaphoreSlim _gamesGate = new(1, 1);
    private readonly SemaphoreSlim _channelsGate = new(1, 1);
    private readonly SemaphoreSlim _detailGate = new(4, 4);
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, (GameDetail Data, DateTimeOffset At)> _details = new();
    private List<SportEvent> _games = [];
    private List<IptvChannel> _channels = [];
    private DateTimeOffset _gamesAt, _channelsAt;
    private string _sourceIdentity = "";
    public RallyRepository(SettingsStore? settings = null, HttpClient? http = null)
    {
        Settings = settings ?? new(); Http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(18) };
        Espn = new(Http, Settings.CacheDirectory); Details = new(Http); Addons = new(Http);
        Stalker = new(Http, Settings); Xtream = new(Http, Settings); Playlists = new(Http, Settings);
    }
    public async Task<List<SportEvent>> GamesAsync(bool refresh = false, CancellationToken ct = default)
    {
        await _gamesGate.WaitAsync(ct);
        try
        {
            if (!refresh && DateTimeOffset.UtcNow - _gamesAt < TimeSpan.FromSeconds(35)) return _games.ToList();
            _games = await Espn.FetchAllAsync(ct: ct); _gamesAt = DateTimeOffset.UtcNow;
            return _games.ToList();
        }
        finally { _gamesGate.Release(); }
    }
    public async Task<List<IptvChannel>> ChannelsAsync(bool refresh = false, CancellationToken ct = default)
    {
        await _channelsGate.WaitAsync(ct);
        try
        {
            var identity = $"{Settings.IptvProvider}|{Settings.PortalUrl}|{Settings.MacAddress}|{Settings.XtreamServerUrl}|{Settings.XtreamUsername}|{Settings.XtreamPassword}|{Settings.M3uUrl}|{Settings.XmltvUrl}";
            if (identity != _sourceIdentity)
            {
                _sourceIdentity = identity; _channels = []; _channelsAt = default;
                Stalker = new(Http, Settings); Xtream = new(Http, Settings); Playlists = new(Http, Settings);
            }
            if (!refresh && DateTimeOffset.UtcNow - _channelsAt < TimeSpan.FromMinutes(10)) return _channels.ToList();
            _channels = Settings.IptvProvider switch
            {
                IptvProvider.M3u => await Playlists.GetChannelsAsync(ct),
                IptvProvider.Xtream => refresh ? await Xtream.RefreshChannelsAsync(ct) : await Xtream.GetChannelsAsync(ct),
                _ => refresh ? await Stalker.RefreshChannelsAsync(ct) : await Stalker.GetChannelsAsync(ct)
            };
            if (Settings.IptvProvider == IptvProvider.M3u)
            {
                try { _channels = await Playlists.WithGuideAsync(_channels, ct); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch { /* Channels remain usable when an optional guide is unavailable. */ }
            }
            _channelsAt = DateTimeOffset.UtcNow;
            return _channels.ToList();
        }
        finally { _channelsGate.Release(); }
    }
    public async Task<GameDetail> DetailAsync(SportEvent ev, bool refresh = false, CancellationToken ct = default)
    {
        var key = $"{ev.League}:{ev.Id}";
        if (!refresh && _details.TryGetValue(key, out var cached) && DateTimeOffset.UtcNow - cached.At < TimeSpan.FromSeconds(40)) return cached.Data;
        var path = EspnClient.Leagues.FirstOrDefault(l => l.League == ev.League);
        if (path.Path is null) return GameDetail.Empty;
        await _detailGate.WaitAsync(ct);
        try
        {
            if (!refresh && _details.TryGetValue(key, out cached) && DateTimeOffset.UtcNow - cached.At < TimeSpan.FromSeconds(40)) return cached.Data;
            var detail = await Details.FetchSummaryAsync(path.Sport, path.Path, ev.Id, ev.AwayTeam?.Abbreviation, ev.HomeTeam?.Abbreviation, ct);
            _details[key] = (detail, DateTimeOffset.UtcNow); return detail;
        }
        finally { _detailGate.Release(); }
    }
    public async Task<List<PlayCandidate>> SourcesAsync(SportEvent ev, CancellationToken ct = default, bool refresh = false)
    {
        var addonsTask = Task.WhenAll(Settings.StremioAddonUrls.Select(async url =>
        {
            try { return refresh ? await Addons.RefreshStreamsAsync(ev, url, ct) : await Addons.FindStreamsAsync(ev, url, ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { return new List<StremioStreamOption>(); }
        }));
        var channelsTask = ChannelsAsync(ct: ct);
        List<IptvChannel> channels;
        try { channels = await channelsTask; }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { channels = []; }
        var options = (await addonsTask).SelectMany(x => x).ToList();
        return StreamResolver.Candidates(ev, channels, options, url => Settings.AdaptiveQualityEnabled ? Settings.GetStreamHealth(url).Score : 0, ev.Broadcasts);
    }
    public async Task<string> StreamUrlAsync(PlayCandidate candidate, CancellationToken ct = default) =>
        candidate.Channel is not null && Settings.IptvProvider == IptvProvider.Stalker
            ? await Stalker.ResolveStreamUrlAsync(candidate.Channel.Id, ct) : candidate.Url;
    public async Task<PlayCandidate> RenewSourceAsync(PlayCandidate source, SportEvent? game, CancellationToken ct = default)
    {
        if (source.Kind != PlayKind.Stremio || game is null) return source;
        var sources = await SourcesAsync(game, ct, refresh: true);
        return sources.FirstOrDefault(c => c.Kind == source.Kind && c.Title == source.Title && c.AddonName == source.AddonName)
            ?? sources.FirstOrDefault(c => c.Kind == source.Kind && c.AddonName == source.AddonName && c.ExactMatch)
            ?? throw new InvalidOperationException("The selected addon no longer has a playable source for this game.");
    }
    public async Task<ChannelGuide?> GuideAsync(IptvChannel channel, CancellationToken ct = default) => Settings.IptvProvider switch
    {
        IptvProvider.Stalker => await Stalker.GetGuideAsync(channel.Id, ct),
        IptvProvider.Xtream => await Xtream.GetGuideAsync(channel.Id, ct),
        _ => channel.Guide
    };
}
