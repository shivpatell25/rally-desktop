using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.Core;

namespace Rally.App.Views;

// Global search across games, favorite teams, leagues, Live TV channels and
// Stremio addon streams. Mirrors SearchScreen + SearchViewModel: 250ms
// debounce, capped groups, guide enrichment for the first 8 channels, addon
// lookup only for queries of 3+ chars. Clicks route to EventDetailPage (game),
// TeamHubPage (team), LeagueCenterPage (league string), PlayerPage with the
// IptvChannel directly (channel — same player path as LiveTv; PlayerPage
// resolves via StreamResolver.ChannelCandidates), and PlayerPage with the
// stream URL string (addon option — PlayerPage plays it as a Stremio-kind
// one-off, same branch as highlight clips).
public sealed partial class SearchPage : Page
{
    private readonly HttpClient _http = new();
    private readonly EspnClient _espn;
    private readonly StremioClient _stremio;
    private readonly SettingsStore _settings = new();
    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(250) };

    private List<SportEvent> _index = [];
    private List<IptvChannel> _channels = [];
    private bool _indexReady;
    private int _searchSeq;

    public SearchPage()
    {
        InitializeComponent();
        _espn = new EspnClient(_http);
        _stremio = new StremioClient(_http);
        _debounce.Tick += Debounce_Tick;
        Loaded += async (_, _) => await WarmIndexAsync().ConfigureAwait(false);
    }

    private async Task WarmIndexAsync()
    {
        try
        {
            _index = await _espn.FetchAllAsync().ConfigureAwait(false);
            _channels = await LoadChannelsAsync().ConfigureAwait(false);
            _indexReady = true;
            DispatcherQueue.TryEnqueue(() =>
                IndexNote.Text = $"Index ready · {_index.Count} games · {_channels.Count} channels");
        }
        catch
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                IndexNote.Text = "Index unavailable — offline search only.";
                ErrorText.Text = "Could not load games or channels. Check your connection and type to retry.";
                ErrorText.Visibility = Visibility.Visible;
            });
        }
    }

    private Task<List<IptvChannel>> LoadChannelsAsync(CancellationToken ct = default)
    {
        if (_settings.IptvProvider == IptvProvider.Xtream)
            return new XtreamClient(_http, _settings).GetChannelsAsync(ct);
        return new StalkerClient(_http, _settings).GetChannelsAsync(ct);
    }

    private void QueryBox_TextChanged(object sender, TextBoxTextChangedEventArgs e)
    {
        _debounce.Stop();
        _debounce.Start();
    }

    private async void Debounce_Tick(object? sender, object e)
    {
        _debounce.Stop();
        await RunSearchAsync(QueryBox.Text, ++_searchSeq).ConfigureAwait(false);
    }

    private async Task RunSearchAsync(string rawQuery, int seq)
    {
        var q = rawQuery.Trim();
        if (q.Length == 0)
        {
            DispatcherQueue.TryEnqueue(ClearResults);
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = true;
            ErrorText.Visibility = Visibility.Collapsed;
            EmptyText.Text = "Searching…";
            EmptyText.Visibility = Visibility.Visible;
        });

        // Local groups: cheap synchronous filters over the warmed index.
        var games = _index.Where(ev =>
            ev.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
            || (ev.League?.Contains(q, StringComparison.OrdinalIgnoreCase) == true)
            || (ev.Sport?.Contains(q, StringComparison.OrdinalIgnoreCase) == true)
            || (ev.HomeTeam?.Name.Contains(q, StringComparison.OrdinalIgnoreCase) == true)
            || (ev.AwayTeam?.Name.Contains(q, StringComparison.OrdinalIgnoreCase) == true))
            .Take(20).Select(ev => new EventRow(ev)).ToList();
        var teams = _settings.FavoriteTeamProfiles.Where(t =>
            t.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
            || t.Abbreviation.Contains(q, StringComparison.OrdinalIgnoreCase)
            || t.League.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Take(12).Select(t => new TeamRow(t)).ToList();
        var leagues = EspnClient.Leagues.Where(l =>
            l.League.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Take(8).Select(l => new LeagueRow(l.League)).ToList();

        // Live TV: filter cached channels, enrich the first 8 with now/next guide.
        List<ChannelRow> channels = [];
        try
        {
            var matches = _channels.Where(c => c.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
                .Take(24).ToList();
            var head = matches.Take(8).ToList();
            var enriched = new IptvChannel[head.Count];
            var tasks = head.Select(async (c, i) =>
            {
                try
                {
                    var guide = _settings.IptvProvider == IptvProvider.Xtream
                        ? await new XtreamClient(_http, _settings).GetGuideAsync(c.Id).ConfigureAwait(false)
                        : await new StalkerClient(_http, _settings).GetGuideAsync(c.Id).ConfigureAwait(false);
                    enriched[i] = guide is null ? c : c with { Guide = guide };
                }
                catch { enriched[i] = c; }
            });
            await Task.WhenAll(tasks).ConfigureAwait(false);
            channels = enriched.Select(c => new ChannelRow(c))
                .Concat(matches.Skip(8).Select(c => new ChannelRow(c))).ToList();
        }
        catch { /* channel search degrades to local groups */ }

        // Addon streams: only for queries of 3+ chars, across configured addons
        // for query-matched events; only directly playable options are shown.
        List<StreamRow> streams = [];
        if (q.Length >= 3)
        {
            try
            {
                var seeds = games.Take(5).Select(r => r.Event).ToList();
                var addons = _settings.StremioAddonUrls;
                var found = new List<StremioStreamOption>();
                foreach (var ev in seeds)
                {
                    foreach (var addon in addons)
                    {
                        try { found.AddRange(await _stremio.FindStreamsAsync(ev, addon).ConfigureAwait(false)); }
                        catch { /* per-addon failure is not fatal */ }
                    }
                }
                streams = found.Where(s => s.IsDirectPlayable)
                    .Take(20).Select(s => new StreamRow(s)).ToList();
            }
            catch { /* addon search degrades to the other groups */ }
        }

        if (seq != _searchSeq) return;
        DispatcherQueue.TryEnqueue(() => BindResults(q, games, teams, leagues, channels, streams));
    }

    private void ClearResults()
    {
        Spinner.IsActive = false;
        Games.Visibility = Teams.Visibility = Leagues.Visibility = Channels.Visibility = Streams.Visibility =
            GamesHeader.Visibility = TeamsHeader.Visibility = LeaguesHeader.Visibility =
            ChannelsHeader.Visibility = StreamsHeader.Visibility = Visibility.Collapsed;
        EmptyText.Text = "Start typing to search every source.";
        EmptyText.Visibility = Visibility.Visible;
    }

    private void BindResults(string q, List<EventRow> games, List<TeamRow> teams,
        List<LeagueRow> leagues, List<ChannelRow> channels, List<StreamRow> streams)
    {
        Spinner.IsActive = false;
        Bind(Games, GamesHeader, games);
        Bind(Teams, TeamsHeader, teams);
        Bind(Leagues, LeaguesHeader, leagues);
        Bind(Channels, ChannelsHeader, channels);
        Bind(Streams, StreamsHeader, streams);
        var total = games.Count + teams.Count + leagues.Count + channels.Count + streams.Count;
        EmptyText.Text = total == 0 ? "No results found." : $"{total} result{(total == 1 ? "" : "s")} for “{q}”.";
        EmptyText.Visibility = Visibility.Visible;
        if (!_indexReady) IndexNote.Text = "Index still loading — results may be partial.";
    }

    private static void Bind<T>(ListView view, TextBlock header, List<T> rows)
    {
        if (rows.Count == 0)
        {
            view.Visibility = header.Visibility = Visibility.Collapsed;
            return;
        }
        view.ItemsSource = rows;
        view.Visibility = header.Visibility = Visibility.Visible;
    }

    private void Games_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Games.SelectedItem is EventRow row)
        {
            Games.SelectedItem = null;
            Frame.Navigate(typeof(EventDetailPage), row.Event);
        }
    }

    private void Teams_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Teams.SelectedItem is TeamRow row)
        {
            Teams.SelectedItem = null;
            Frame.Navigate(typeof(TeamHubPage), row.Team);
        }
    }

    private void Leagues_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Leagues.SelectedItem is LeagueRow row)
        {
            Leagues.SelectedItem = null;
            Frame.Navigate(typeof(LeagueCenterPage), row.League);
        }
    }

    private void Channels_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Channels.SelectedItem is ChannelRow row)
        {
            Channels.SelectedItem = null;
            Frame.Navigate(typeof(PlayerPage), row.Channel);
        }
    }

    private void Streams_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Streams.SelectedItem is StreamRow row)
        {
            Streams.SelectedItem = null;
            Frame.Navigate(typeof(PlayerPage), row.Option.StreamUrl);
        }
    }

    public sealed record EventRow(SportEvent Event)
    {
        public string Name => Event.Name;
        public string Subtitle => $"{Event.League} · {Event.GameStatusDetail ?? Event.Status.ToString()}";
    }

    public sealed record TeamRow(FavoriteTeam Team)
    {
        public string Name => Team.Name;
        public string Subtitle => $"Favorite · {Team.League}";
    }

    public sealed record LeagueRow(string League)
    {
        public string Name => League;
        public string Subtitle => "League Center";
    }

    public sealed record ChannelRow(IptvChannel Channel)
    {
        public string Name => Channel.Name;
        public string Subtitle
        {
            get
            {
                var now = Channel.Guide?.Now?.Title;
                var next = Channel.Guide?.Next?.Title;
                var parts = new List<string>();
                if (!string.IsNullOrEmpty(now)) parts.Add($"Now · {now}");
                if (!string.IsNullOrEmpty(next)) parts.Add($"Next · {next}");
                if (parts.Count == 0) parts.Add(Channel.Category);
                return string.Join("   ", parts);
            }
        }
    }

    public sealed record StreamRow(StremioStreamOption Option)
    {
        public string Title => Option.Title;
        public string Subtitle
        {
            get
            {
                var bits = new List<string>();
                if (!string.IsNullOrEmpty(Option.Quality)) bits.Add(Option.Quality);
                if (!string.IsNullOrEmpty(Option.AddonName)) bits.Add(Option.AddonName);
                if (bits.Count == 0) bits.Add("Adaptive");
                return string.Join(" · ", bits);
            }
        }
    }
}
