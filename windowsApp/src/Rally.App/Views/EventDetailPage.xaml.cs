using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

public sealed partial class EventDetailPage : Page
{
    private readonly SettingsStore _settings = new();
    private readonly EspnDetail _detail = new(new HttpClient());
    private SportEvent? _event;

    public EventDetailPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _event = e.Parameter as SportEvent;
        if (_event is null)
        {
            ErrorText.Text = "No game was passed to this page.";
            ErrorText.Visibility = Visibility.Visible;
            return;
        }
        BindHero(_event);
        _ = LoadDetailAsync(_event);
    }

    private void BindHero(SportEvent ev)
    {
        var isLive = ev.Status is EventStatus.Live or EventStatus.Halftime;
        var isFinal = ev.Status == EventStatus.Finished;
        StatusPillText.Text = isLive ? "LIVE" : isFinal ? "FINAL" : "UPCOMING";
        if (!isLive)
            StatusPill.Background = (Brush)Application.Current.Resources["RallySurface"];
        LeagueText.Text = ev.League.ToUpperInvariant();

        AwayName.Text = ev.AwayTeam?.Name ?? "TBD";
        AwayAbbr.Text = ev.AwayTeam?.Abbreviation ?? "";
        HomeName.Text = ev.HomeTeam?.Name ?? "TBD";
        HomeAbbr.Text = ev.HomeTeam?.Abbreviation ?? "";
        ScoreText.Text = isLive || isFinal
            ? $"{ev.ScoreAway?.ToString() ?? "–"}  –  {ev.ScoreHome?.ToString() ?? "–"}"
            : "VS";
        StartText.Text = (isLive ? ev.GameStatusDetail
            : isFinal ? "FINAL"
            : ev.StartTime.LocalDateTime.ToString("ddd, MMM d · h:mm tt")).ToUpperInvariant();

        var venueBits = new List<string>();
        if (!string.IsNullOrWhiteSpace(ev.Venue)) venueBits.Add(ev.Venue);
        if (ev.Broadcasts is { Count: > 0 }) venueBits.Add(string.Join(", ", ev.Broadcasts));
        VenueText.Text = venueBits.Count > 0 ? string.Join("  ·  ", venueBits) : ev.League;

        WatchButton.Content = isLive ? "Watch live" : "Watch";
        RefreshSaveButtons();
        MatchupTitle.Text = isLive ? "LIVE STATS" : ev.Status == EventStatus.NotStarted ? "MATCHUP PREVIEW" : "MATCHUP STATS";
    }

    private void RefreshSaveButtons()
    {
        if (_event?.AwayTeam is not null)
            SaveAwayButton.Content = _settings.IsFavoriteTeam(_event.AwayTeam.Id, _event.League)
                ? $"Saved {_event.AwayTeam.Abbreviation}" : $"Save {_event.AwayTeam.Abbreviation}";
        if (_event?.HomeTeam is not null)
            SaveHomeButton.Content = _settings.IsFavoriteTeam(_event.HomeTeam.Id, _event.League)
                ? $"Saved {_event.HomeTeam.Abbreviation}" : $"Save {_event.HomeTeam.Abbreviation}";
        SaveAwayButton.Visibility = _event?.AwayTeam is null ? Visibility.Collapsed : Visibility.Visible;
        SaveHomeButton.Visibility = _event?.HomeTeam is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Watch_Click(object sender, RoutedEventArgs e)
    {
        if (_event is not null) Frame.Navigate(typeof(PlayerPage), _event);
    }

    private void PickSource_Click(object sender, RoutedEventArgs e)
    {
        // PlayerPage owns the source picker; navigating with the event is the
        // picker-focus path (same page, no extra param needed).
        if (_event is not null) Frame.Navigate(typeof(PlayerPage), _event);
    }

    private void SaveAway_Click(object sender, RoutedEventArgs e) => ToggleSave(_event?.AwayTeam);

    private void SaveHome_Click(object sender, RoutedEventArgs e) => ToggleSave(_event?.HomeTeam);

    private void ToggleSave(Team? team)
    {
        if (_event is null || team is null) return;
        _settings.ToggleFavoriteTeam(new FavoriteTeam(team.Id, _event.League, team.Name, team.Abbreviation, team.LogoUrl));
        RefreshSaveButtons();
    }

    private async Task LoadDetailAsync(SportEvent ev)
    {
        DispatcherQueue.TryEnqueue(() => Spinner.IsActive = true);
        GameDetail detail = GameDetail.Empty;
        try
        {
            // Map the display league back to ESPN sport/path for the summary endpoint.
            var league = EspnClient.Leagues.FirstOrDefault(l => l.League == ev.League);
            if (league != default)
            {
                detail = await _detail.FetchSummaryAsync(
                    league.Sport, league.Path, ev.Id,
                    ev.AwayTeam?.Abbreviation, ev.HomeTeam?.Abbreviation).ConfigureAwait(false);
            }
        }
        catch
        {
            // Offline: hero stays, panels below explain. Never crash.
        }
        var snapshot = detail;
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = false;
            BindDetail(ev, snapshot);
        });
    }

    private void BindDetail(SportEvent ev, GameDetail detail)
    {
        // Records compare list references, so test emptiness field by field.
        if (detail.Leaders.Count == 0 && detail.Clips.Count == 0 && detail.TeamStats.Count == 0
            && detail.PlayerTables.Count == 0 && detail.Broadcasts.Count == 0)
        {
            DetailErrorText.Text = "Details unavailable offline.";
            DetailErrorText.Visibility = Visibility.Visible;
        }

        // Broadcast stations from the summary enrich the hero line.
        if (detail.Broadcasts.Count > 0 && ev.Broadcasts is not { Count: > 0 })
        {
            var bits = new List<string>();
            if (!string.IsNullOrWhiteSpace(ev.Venue)) bits.Add(ev.Venue);
            bits.Add(string.Join(", ", detail.Broadcasts));
            VenueText.Text = string.Join("  ·  ", bits);
        }

        // Matchup Preview: records, start/broadcast/venue, then team stat comparisons.
        MatchupRows.Children.Clear();
        AddMatchupRow(RecordSummary(ev.AwayTeam), "RECORD", RecordSummary(ev.HomeTeam));
        if (ev.Status == EventStatus.NotStarted)
            AddMatchupRow(ev.StartTime.LocalDateTime.ToString("g"), "START", "LOCAL");
        else
            AddMatchupRow(ev.ScoreAway?.ToString(), "SCORE", ev.ScoreHome?.ToString());
        var broadcast = (ev.Broadcasts is { Count: > 0 } ? string.Join(", ", ev.Broadcasts)
            : detail.Broadcasts is { Count: > 0 } ? string.Join(", ", detail.Broadcasts) : null);
        if (broadcast is not null) AddMatchupRow("", "BROADCAST", broadcast);
        if (!string.IsNullOrWhiteSpace(ev.Venue)) AddMatchupRow("", "VENUE", ev.Venue);
        foreach (var stat in detail.TeamStats.Take(4))
            AddMatchupRow(stat.AwayValue, stat.Label.ToUpperInvariant(), stat.HomeValue);

        // Team Outlook: records per side (mirrors Android preview fallback copy).
        AwayOutlook.Text = $"{ev.AwayTeam?.Name ?? "TBD"} — {RecordSummary(ev.AwayTeam) ?? "Season record unavailable"}";
        HomeOutlook.Text = $"{ev.HomeTeam?.Name ?? "TBD"} — {RecordSummary(ev.HomeTeam) ?? "Season record unavailable"}";

        // Game Information.
        InfoRows.Children.Clear();
        AddInfoRow("STATUS", StatusText(ev));
        AddInfoRow("LEAGUE", ev.League.ToUpperInvariant());
        AddInfoRow("VENUE", (ev.Venue ?? "TBD").ToUpperInvariant());
        AddInfoRow("DATE", ev.StartTime.LocalDateTime.ToString("MMM d").ToUpperInvariant());

        // Leaders grouped by side; upcoming games show the outlook placeholder instead.
        AwayLeaders.Children.Clear();
        HomeLeaders.Children.Clear();
        var showLeaders = ev.Status != EventStatus.NotStarted && detail.Leaders.Count > 0;
        LeadersTitle.Text = showLeaders ? "TOP PERFORMERS" : "TEAM OUTLOOK";
        if (showLeaders)
        {
            AddLeaderColumn(AwayLeaders, ev.AwayTeam?.Abbreviation ?? "", DetailLeaders(detail.Leaders, ev.AwayTeam?.Abbreviation));
            AddLeaderColumn(HomeLeaders, ev.HomeTeam?.Abbreviation ?? "", DetailLeaders(detail.Leaders, ev.HomeTeam?.Abbreviation));
        }
        else
        {
            AwayLeaders.Children.Add(new TextBlock
            {
                Text = "Official lineups and player availability will appear when published.",
                FontSize = 12, Opacity = 0.6, TextWrapping = TextWrapping.Wrap,
            });
        }

        // Clips: button per highlight showing duration. Per the nav contract,
        // PlayerPage plays a raw string param as a one-off URL, so pass
        // clip.StreamUrl directly (NO synthetic SportEvent).
        ClipsHost.Children.Clear();
        ClipsTitle.Text = $"HIGHLIGHTS{(detail.Clips.Count > 0 ? $" ({detail.Clips.Count})" : "")}";
        if (detail.Clips.Count == 0)
        {
            ClipsHost.Children.Add(new TextBlock
            {
                Text = "No highlights yet.",
                FontSize = 12, Opacity = 0.6,
            });
            return;
        }
        foreach (var clip in detail.Clips)
        {
            var label = $"▶  {clip.Title}";
            if (clip.DurationSeconds is int secs) label += $"  ({secs / 60}:{secs % 60:00})";
            var button = new Button
            {
                Content = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Tag = clip,
                IsEnabled = !string.IsNullOrEmpty(clip.StreamUrl),
            };
            button.Click += Clip_Click;
            ClipsHost.Children.Add(button);
        }
    }

    private void Clip_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: HighlightClip clip } && !string.IsNullOrEmpty(clip.StreamUrl))
            Frame.Navigate(typeof(PlayerPage), clip.StreamUrl);
    }

    private void AddMatchupRow(string? away, string label, string? home)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(away) ? "–" : away,
            FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Bold, TextWrapping = TextWrapping.Wrap,
        });
        var mid = new TextBlock
        {
            Text = label, FontSize = 10, Opacity = 0.6, TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(mid, 1);
        grid.Children.Add(mid);
        var right = new TextBlock
        {
            Text = string.IsNullOrEmpty(home) ? "–" : home,
            FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            TextAlignment = TextAlignment.Right, TextWrapping = TextWrapping.Wrap,
        };
        Grid.SetColumn(right, 2);
        grid.Children.Add(right);
        MatchupRows.Children.Add(grid);
    }

    private void AddInfoRow(string label, string value)
    {
        InfoRows.Children.Add(new TextBlock
        {
            Text = label, FontSize = 9, Opacity = 0.6, FontWeight = Microsoft.UI.Text.FontWeights.Bold,
        });
        InfoRows.Children.Add(new TextBlock
        {
            Text = value, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            TextWrapping = TextWrapping.Wrap,
        });
    }

    private void AddLeaderColumn(StackPanel host, string teamAbbr, List<PlayerLeader> leaders)
    {
        host.Children.Add(new TextBlock
        {
            Text = teamAbbr, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Bold,
        });
        if (leaders.Count == 0)
        {
            host.Children.Add(new TextBlock { Text = "No official leaders yet", FontSize = 11, Opacity = 0.6 });
            return;
        }
        foreach (var leader in leaders)
        {
            host.Children.Add(new TextBlock
            {
                Text = leader.PlayerShortName,
                FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            });
            host.Children.Add(new TextBlock
            {
                Text = $"{leader.Category} · {leader.StatDisplay}",
                FontSize = 11, Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
            });
        }
    }

    private static List<PlayerLeader> DetailLeaders(List<PlayerLeader> all, string? abbr) =>
        all.Where(l => l.TeamAbbr?.Equals(abbr ?? "", StringComparison.OrdinalIgnoreCase) == true)
            .Take(3).ToList();

    private static string? RecordSummary(Team? team)
    {
        if (team?.Records is not { Count: > 0 }) return null;
        var summary = string.Join(" · ", team.Records.Select(r => r.Summary).OfType<string>().Where(s => s.Length > 0));
        return summary.Length > 0 ? summary : null;
    }

    private static string StatusText(SportEvent ev) => ev.Status switch
    {
        EventStatus.Live => "LIVE",
        EventStatus.Halftime => "HALFTIME",
        EventStatus.Finished => "FINAL",
        EventStatus.Delayed => "DELAYED",
        EventStatus.Canceled => "CANCELED",
        _ => "UPCOMING",
    };
}
