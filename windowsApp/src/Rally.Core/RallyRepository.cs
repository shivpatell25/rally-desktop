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
    private readonly AsyncDataCache<List<SportEvent>> _gamesCache = new(TimeSpan.FromSeconds(35));
    private readonly AsyncDataCache<GameDetail> _details = new(TimeSpan.FromSeconds(35), 256);
    private readonly AsyncDataCache<List<Team>> _teams = new(TimeSpan.FromHours(4));
    private readonly AsyncDataCache<List<SportEvent>> _teamGames = new(TimeSpan.FromMinutes(2));
    private readonly AsyncDataCache<SportsSchedule> _schedule = new(TimeSpan.FromSeconds(35));
    private readonly SemaphoreSlim _channelsGate = new(1, 1);
    private List<IptvChannel> _channels = [];
    private DateTimeOffset _channelsAt;
    private string _sourceIdentity = "";
    public RallyRepository(SettingsStore? settings = null, HttpClient? http = null)
    {
        Settings = settings ?? new(); Http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(18) };
        Espn = new(Http, Settings.CacheDirectory); Details = new(Http); Addons = new(Http);
        Stalker = new(Http, Settings); Xtream = new(Http, Settings); Playlists = new(Http, Settings);
    }
    public Task<List<SportEvent>> GamesAsync(bool refresh = false, CancellationToken ct = default) =>
        _gamesCache.GetAsync("today", () => Espn.FetchAllAsync(), refresh, ct);
    public IReadOnlyList<string> UnavailableLeagues => Espn.UnavailableLeagues;
    public Task<List<Team>> TeamsAsync(string league, CancellationToken ct = default)
    {
        var path = EspnClient.Leagues.FirstOrDefault(l => l.League == league);
        return path.Path is null ? Task.FromResult(new List<Team>()) : _teams.GetAsync(league, () => Details.FetchTeamsAsync(path.Sport, path.Path), false, ct);
    }
    public Task<List<SportEvent>> TeamGamesAsync(FavoriteTeam team, CancellationToken ct = default)
    {
        var path = EspnClient.Leagues.FirstOrDefault(l => l.League == team.League);
        return path.Path is null ? Task.FromResult(new List<SportEvent>()) : _teamGames.GetAsync(team.Key, () => Details.FetchTeamScheduleAsync(path.Sport, path.Path, team.League, team.Id), false, ct);
    }
    public Task<SportsSchedule> ScheduleAsync(DateTimeOffset date, string? sport = null, string? league = null, bool refresh = false, CancellationToken ct = default) =>
        _schedule.GetAsync($"{date:yyyyMMdd}|{sport}|{league}", async () =>
        {
            var requested = EspnClient.Leagues.Where(l => (sport is null || l.Sport == sport) && (league is null || l.League == league)).ToList();
            var results = await Task.WhenAll(requested.Select(async l =>
            {
                try { return (Games: await Espn.FetchScoreboardAsync(l.Sport, l.Path, l.League, dates: date.ToString("yyyyMMdd")), Failed: (string?)null); }
                catch { return (Games: new List<SportEvent>(), Failed: (string?)l.League); }
            }));
            if (results.Length > 0 && results.All(r => r.Failed is not null)) throw new HttpRequestException("The schedule feeds are unavailable.");
            return new SportsSchedule(results.SelectMany(r => r.Games).DistinctBy(e => $"{e.League}:{e.Id}").OrderBy(e => e.StartTime).ToList(), results.Select(r => r.Failed).OfType<string>().ToList());
        }, refresh, ct);
    public void ClearSportsCache()
    {
        _gamesCache.Clear(); _details.Clear(); _schedule.Clear(); _teams.Clear(); _teamGames.Clear();
        if (Directory.Exists(Settings.CacheDirectory)) Directory.Delete(Settings.CacheDirectory, true);
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
    public Task<GameDetail> DetailAsync(SportEvent ev, bool refresh = false, CancellationToken ct = default)
    {
        var path = EspnClient.Leagues.FirstOrDefault(l => l.League == ev.League);
        if (path.Path is null) return Task.FromResult(GameDetail.Empty);
        return _details.GetAsync($"{ev.League}:{ev.Id}", () => Details.FetchSummaryAsync(path.Sport, path.Path, ev.Id, ev.AwayTeam?.Abbreviation, ev.HomeTeam?.Abbreviation), refresh, ct);
    }
    public async Task<List<PlayCandidate>> SourcesAsync(SportEvent ev, CancellationToken ct = default, bool refresh = false)
    {
        var failed = 0; var configured = Settings.StremioAddonUrls.ToArray();
        var addonsTask = Task.WhenAll(configured.Select(async url =>
        {
            try { return refresh ? await Addons.RefreshStreamsAsync(ev, url, ct) : await Addons.FindStreamsAsync(ev, url, ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { Interlocked.Increment(ref failed); return new List<StremioStreamOption>(); }
        }));
        var channelsTask = ChannelsAsync(ct: ct);
        List<IptvChannel> channels;
        try { channels = await channelsTask; }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { channels = []; }
        var options = (await addonsTask).SelectMany(x => x).ToList();
        if (configured.Length > 0 && failed == configured.Length && channels.Count == 0) throw new HttpRequestException("Configured sources are unavailable.");
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
