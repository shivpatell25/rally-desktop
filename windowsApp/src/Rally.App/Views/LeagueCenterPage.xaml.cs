using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

// League center. Mirrors Android LeagueHubDashboard + macOS TvLeagueCenter:
// header (league, games/teams counts), Games/Standings/Playoffs tabs, day
// pager, NFL RedZone button. Param = string league.
public sealed partial class LeagueCenterPage : Page
{
    // 1:1 with EspnRepositoryImpl.getLeagueHub postseasonTerms.
    private static readonly string[] PostseasonTerms =
        ["playoff", "wild card", "divisional", "conference", "championship", "final", "postseason"];

    private readonly HttpClient _http = new();
    private readonly EspnClient _espn;
    private readonly EspnDetail _detail;
    private readonly SettingsStore _settings = new();
    private readonly StalkerClient _stalker;
    private readonly XtreamClient _xtream;

    private string _league = "";
    private string _sport = "";
    private string _path = "";
    private int _dayOffset;
    private int _tab;
    private List<SportEvent> _todayEvents = [];
    private List<StandingRow> _standings = [];
    private IptvChannel? _redZone;

    public LeagueCenterPage()
    {
        InitializeComponent();
        _espn = new EspnClient(_http);
        _detail = new EspnDetail(_http);
        _stalker = new StalkerClient(_http, _settings);
        _xtream = new XtreamClient(_http, _settings);
        Unloaded += (_, _) => _http.Dispose();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _league = e.Parameter as string ?? "";
        var found = EspnClient.Leagues.FirstOrDefault(l =>
            l.League.Equals(_league, StringComparison.OrdinalIgnoreCase));
        if (found != default)
        {
            _league = found.League;
            _sport = found.Sport;
            _path = found.Path;
        }
        Title.Text = _league;
        await LoadAsync().ConfigureAwait(false);
    }

    private async Task LoadAsync()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = true;
            ErrorText.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
        });
        List<SportEvent> events = [];
        List<StandingRow> standings = [];
        IptvChannel? redZone = null;
        try { events = await _espn.FetchScoreboardAsync(_sport, _path, _league).ConfigureAwait(false); }
        catch { /* offline: empty list, page still loads */ }
        try { standings = await _detail.FetchStandingsAsync(_sport, _path).ConfigureAwait(false); }
        catch { standings = []; }
        if (_league.Equals("NFL", StringComparison.OrdinalIgnoreCase))
        {
            try { redZone = await FindRedZoneAsync().ConfigureAwait(false); }
            catch { redZone = null; }
        }
        _todayEvents = events;
        _standings = standings;
        _redZone = redZone;
        DispatcherQueue.TryEnqueue(RenderHub);
    }

    // Android LeagueHubViewModel: nfl + redzone preferred, any redzone fallback.
    private async Task<IptvChannel?> FindRedZoneAsync(CancellationToken ct = default)
    {
        List<IptvChannel> channels = _settings.IptvProvider == IptvProvider.Xtream
            ? await _xtream.GetChannelsAsync(ct).ConfigureAwait(false)
            : await _stalker.GetChannelsAsync(ct).ConfigureAwait(false);
        return channels.FirstOrDefault(c =>
                c.Name.Contains("nfl", StringComparison.OrdinalIgnoreCase) &&
                (c.Name.Contains("redzone", StringComparison.OrdinalIgnoreCase) ||
                 c.Name.Contains("red zone", StringComparison.OrdinalIgnoreCase)))
            ?? channels.FirstOrDefault(c =>
                c.Name.Contains("redzone", StringComparison.OrdinalIgnoreCase) ||
                c.Name.Contains("red zone", StringComparison.OrdinalIgnoreCase));
    }

    private void RenderHub()
    {
        Spinner.IsActive = false;
        var teamCount = _todayEvents
            .SelectMany(e => new[] { e.HomeTeam?.Id, e.AwayTeam?.Id })
            .Where(id => id is not null).Distinct().Count();
        Subtitle.Text = $"{_todayEvents.Count} games · {teamCount} teams";
        if (_todayEvents.Count == 0 && _standings.Count == 0)
        {
            ErrorText.Text = "League data is unavailable";
            ErrorText.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
        }
        StandingsTab.Visibility = _standings.Count > 0
            ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        var postseason = PostseasonEvents(_todayEvents);
        PlayoffsTab.Visibility = postseason.Count > 0 || PlayoffPicture().Count > 0
            ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        // RedZone only when the channel exists.
        RedZoneButton.Visibility = _redZone is not null
            ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        if (_tab == 1 && _standings.Count == 0) _tab = 0;
        if (_tab == 2 && PlayoffsTab.Visibility == Microsoft.UI.Xaml.Visibility.Collapsed) _tab = 0;
        RenderTabs();
        _ = LoadDayAsync();
    }

    private static List<SportEvent> PostseasonEvents(List<SportEvent> events) =>
        events.Where(e =>
        {
            var ctx = $"{e.Name} {e.GameStatusDetail} {string.Join(" ", e.Broadcasts ?? [])}"
                .ToLowerInvariant();
            return PostseasonTerms.Any(ctx.Contains);
        }).ToList();

    // 1:1 with EspnRepositoryImpl playoffCutoff: NFL14/NBA16/NHL16/MLB12/else 8.
    private static int PlayoffCutoff(string league) => league.ToUpperInvariant() switch
    {
        "NFL" => 14,
        "NBA" or "NHL" => 16,
        "MLB" => 12,
        _ => 8,
    };

    private List<SeedRow> PlayoffPicture() =>
        _standings.Take(PlayoffCutoff(_league))
            .Select((s, i) => new SeedRow(s.TeamName, $"Seed {i + 1} · {RecordLine(s)}".TrimEnd(' ', '·')))
            .ToList();

    private static string RecordLine(StandingRow s)
    {
        var parts = new List<string> { $"W {s.Wins}", $"L {s.Losses}" };
        if (s.Ties is int t) parts.Add($"T {t}");
        if (!string.IsNullOrEmpty(s.Pct)) parts.Add(s.Pct);
        if (!string.IsNullOrEmpty(s.Gb)) parts.Add($"GB {s.Gb}");
        return string.Join(" · ", parts);
    }

    private void RenderTabs()
    {
        GamesTab.IsEnabled = _tab != 0;
        StandingsTab.IsEnabled = _tab != 1;
        PlayoffsTab.IsEnabled = _tab != 2;
        Games.Visibility = _tab == 0
            ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        Pager.Visibility = _tab == 0
            ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        StandingsList.Visibility = _tab == 1
            ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        PlayoffsPanel.Visibility = _tab == 2
            ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        if (_tab == 1)
        {
            EmptyDayText.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
            StandingsList.ItemsSource = _standings.Select(s => new StandingRowVm(s)).ToList();
        }
        if (_tab == 2)
        {
            EmptyDayText.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
            var postseason = PostseasonEvents(_todayEvents);
            if (postseason.Count > 0)
            {
                PlayoffSectionLabel.Text = "PLAYOFFS";
                PlayoffGames.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
                PlayoffSeeds.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
                PlayoffGames.ItemsSource = postseason.Select(e => new GameRow(e)).ToList();
            }
            else
            {
                // Seeded picture (standings.Take(cutoff)) when no postseason events.
                PlayoffSectionLabel.Text = "PLAYOFF PICTURE";
                PlayoffGames.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
                PlayoffSeeds.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
                PlayoffSeeds.ItemsSource = PlayoffPicture();
            }
        }
    }

    private async Task LoadDayAsync()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = true;
            DateLabel.Text = _dayOffset switch
            {
                -1 => "YESTERDAY",
                0 => "TODAY",
                1 => "TOMORROW",
                _ => DateTimeOffset.UtcNow.AddDays(_dayOffset).ToString("yyyy-MM-dd"),
            };
            TodayButton.Visibility = _dayOffset != 0
                ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        });
        List<SportEvent> day = _todayEvents;
        if (_dayOffset != 0)
        {
            var dates = DateTimeOffset.UtcNow.AddDays(_dayOffset).ToString("yyyyMMdd");
            try { day = await _espn.FetchScoreboardAsync(_sport, _path, _league, 100, dates).ConfigureAwait(false); }
            catch { day = []; }
        }
        var rows = day.Select(e => new GameRow(e)).ToList();
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = false;
            if (_tab != 0) return;
            Games.ItemsSource = rows;
            var empty = rows.Count == 0;
            EmptyDayText.Visibility = empty
                ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
            Games.Visibility = !empty && _tab == 0
                ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        });
    }

    private void Tab_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (sender == StandingsTab) _tab = 1;
        else if (sender == PlayoffsTab) _tab = 2;
        else _tab = 0;
        RenderTabs();
        if (_tab == 0) _ = LoadDayAsync();
    }

    private async void PrevDay_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _dayOffset--;
        await LoadDayAsync().ConfigureAwait(false);
    }

    private async void NextDay_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _dayOffset++;
        await LoadDayAsync().ConfigureAwait(false);
    }

    private async void Today_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _dayOffset = 0;
        await LoadDayAsync().ConfigureAwait(false);
    }

    private void Games_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is ListView list && list.SelectedItem is GameRow row)
        {
            list.SelectedItem = null;
            Frame.Navigate(typeof(EventDetailPage), row.Event);
        }
    }

    private void RedZone_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        // PlayerPage resolves the IptvChannel directly via
        // StreamResolver.ChannelCandidates (PlayerOwner owns that branch).
        if (_redZone is not null) Frame.Navigate(typeof(PlayerPage), _redZone);
    }

    public sealed record GameRow(SportEvent Event)
    {
        public string Name => Event.Name;
        public string Detail
        {
            get
            {
                var score = Event.ScoreAway is int a && Event.ScoreHome is int h
                    ? $"{Event.AwayTeam?.Abbreviation} {a} – {h} {Event.HomeTeam?.Abbreviation}"
                    : Event.StartTime.LocalDateTime.ToString("g");
                var status = Event.Status switch
                {
                    EventStatus.Live => "LIVE · ",
                    EventStatus.Halftime => "HALF · ",
                    EventStatus.Finished => "FINAL · ",
                    _ => "",
                };
                var extra = Event.Broadcasts is { Count: > 0 } b
                    ? string.Join(", ", b)
                    : Event.GameStatusDetail ?? "";
                return $"{status}{score}" + (extra.Length > 0 ? $" · {extra}" : "");
            }
        }
    }

    public sealed record StandingRowVm(StandingRow Row)
    {
        public string TeamName => Row.TeamName;
        public string Line => RecordLine(Row);
    }

    public sealed record SeedRow(string TeamName, string Line);
}
