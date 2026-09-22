using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

// 1:1 with Android TeamHubScreen + TeamHubViewModel: header (name, league,
// standing summary), Overview / Games / Roster / Injuries sections, Remove
// round-trips to settings, NotFavorite gate when the team isn't favorited.
// Sport/path resolve via EspnClient.Leagues by league, mirroring
// EspnRepositoryImpl.getTeamHub.
public sealed partial class TeamHubPage : Page
{
    private readonly SettingsStore _settings = new();
    private readonly HttpClient _http = new();
    private readonly EspnClient _espn;
    private readonly EspnDetail _detail;
    private FavoriteTeam? _team;

    public TeamHubPage()
    {
        InitializeComponent();
        _espn = new(_http);
        _detail = new(_http);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await LoadAsync(e.Parameter as FavoriteTeam).ConfigureAwait(false);
    }

    private async Task LoadAsync(FavoriteTeam? team)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = true;
            ErrorText.Visibility = Visibility.Collapsed;
            RetryButton.Visibility = Visibility.Collapsed;
            NotFavoriteText.Visibility = Visibility.Collapsed;
            AddButton.Visibility = Visibility.Collapsed;
            RemoveButton.Visibility = Visibility.Collapsed;
            Sections.Visibility = Visibility.Collapsed;
        });
        if (team is null)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                Spinner.IsActive = false;
                ErrorText.Text = "Team data is unavailable.";
                ErrorText.Visibility = Visibility.Visible;
            });
            return;
        }
        _team = team;
        DispatcherQueue.TryEnqueue(() =>
        {
            TeamName.Text = team.Name;
            TeamLeague.Text = $"MY TEAMS · {team.League.ToUpperInvariant()}";
        });
        if (!_settings.IsFavoriteTeam(team.Id, team.League))
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                Spinner.IsActive = false;
                NotFavoriteText.Visibility = Visibility.Visible;
                AddButton.Visibility = Visibility.Visible;
            });
            return;
        }
        try
        {
            var league = EspnClient.Leagues
                .FirstOrDefault(l => l.League.Equals(team.League, StringComparison.OrdinalIgnoreCase));
            var knownLeague = league.League is not null;
            var scheduleTask = _espn.FetchAllAsync();
            var standingsTask = knownLeague
                ? _detail.FetchStandingsAsync(league.Sport, league.Path)
                : Task.FromResult<List<StandingRow>>([]);
            var rosterTask = knownLeague
                ? _detail.FetchTeamRosterAsync(league.Sport, league.Path, team.Id)
                : Task.FromResult<List<RosterPlayer>>([]);
            var injuriesTask = knownLeague
                ? _detail.FetchTeamInjuriesAsync(league.Sport, league.Path, team.Id)
                : Task.FromResult<List<InjuryEntry>>([]);
            await Task.WhenAll(scheduleTask, standingsTask, rosterTask, injuriesTask).ConfigureAwait(false);
            var schedule = scheduleTask.Result
                .Where(e => e.League == team.League &&
                    (e.HomeTeam?.Id == team.Id || e.AwayTeam?.Id == team.Id))
                .OrderBy(e => e.StartTime)
                .ToList();
            var standing = standingsTask.Result.FirstOrDefault(r => r.TeamId == team.Id)
                ?? standingsTask.Result.FirstOrDefault(r =>
                    r.Abbreviation.Equals(team.Abbreviation, StringComparison.OrdinalIgnoreCase));
            var record = schedule
                .Select(e => e.HomeTeam?.Id == team.Id ? e.HomeTeam : e.AwayTeam)
                .SelectMany(t => t?.Records ?? [])
                .FirstOrDefault(r => !string.IsNullOrEmpty(r.Summary))?.Summary;
            var summary = standing is null ? record : FormatStanding(standing);
            var next = schedule.Where(e => e.Status != EventStatus.Finished).OrderBy(e => e.StartTime).FirstOrDefault();
            var last5 = schedule.Where(e => e.Status == EventStatus.Finished).TakeLast(5).Reverse().ToList();
            var roster = rosterTask.Result;
            var injuries = injuriesTask.Result;
            DispatcherQueue.TryEnqueue(() =>
            {
                Spinner.IsActive = false;
                RemoveButton.Visibility = Visibility.Visible;
                Sections.Visibility = Visibility.Visible;
                SeasonText.Text = summary ?? record ?? "Season data is unavailable.";
                if (summary is not null)
                {
                    StandingSummary.Text = summary;
                    StandingSummary.Visibility = Visibility.Visible;
                }
                else
                {
                    StandingSummary.Visibility = Visibility.Collapsed;
                }
                NextGame.ItemsSource = next is null ? new List<EventRow>() : new List<EventRow> { new(next) };
                NextGameEmpty.Visibility = next is null ? Visibility.Visible : Visibility.Collapsed;
                RecentForm.ItemsSource = last5.Select(e => new EventRow(e)).ToList();
                RecentFormEmpty.Visibility = last5.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                Schedule.ItemsSource = schedule.Select(e => new EventRow(e)).ToList();
                ScheduleEmpty.Visibility = schedule.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                Roster.ItemsSource = roster;
                RosterEmpty.Visibility = roster.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                Injuries.ItemsSource = injuries;
                InjuriesEmpty.Visibility = injuries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                ShowSection("Overview");
            });
        }
        catch
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                Spinner.IsActive = false;
                ErrorText.Text = "Team data is unavailable. Check your connection and try again.";
                ErrorText.Visibility = Visibility.Visible;
                RetryButton.Visibility = Visibility.Visible;
            });
        }
    }

    private static string FormatStanding(StandingRow row)
    {
        var record = row.Ties is > 0 ? $"{row.Wins}-{row.Losses}-{row.Ties}" : $"{row.Wins}-{row.Losses}";
        if (!string.IsNullOrEmpty(row.Pct)) record += $" · {row.Pct}";
        if (!string.IsNullOrEmpty(row.Gb)) record += $" · {row.Gb} GB";
        return record;
    }

    private void ShowSection(string section)
    {
        OverviewPanel.Visibility = section == "Overview" ? Visibility.Visible : Visibility.Collapsed;
        GamesPanel.Visibility = section == "Games" ? Visibility.Visible : Visibility.Collapsed;
        RosterPanel.Visibility = section == "Roster" ? Visibility.Visible : Visibility.Collapsed;
        InjuriesPanel.Visibility = section == "Injuries" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Section_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag as string is string section) ShowSection(section);
    }

    private void Game_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is ListView list && list.SelectedItem is EventRow row)
        {
            list.SelectedItem = null;
            Frame.Navigate(typeof(EventDetailPage), row.Event);
        }
    }

    private async void Add_Click(object sender, RoutedEventArgs e)
    {
        if (_team is not null)
        {
            _settings.ToggleFavoriteTeam(_team);
            await LoadAsync(_team).ConfigureAwait(false);
        }
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (_team is not null) _settings.ToggleFavoriteTeam(_team);
        if (Frame.CanGoBack) Frame.GoBack();
        else Frame.Navigate(typeof(MyTeamsPage));
    }

    private async void Retry_Click(object sender, RoutedEventArgs e) =>
        await LoadAsync(_team).ConfigureAwait(false);

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (Frame.CanGoBack) Frame.GoBack();
        else Frame.Navigate(typeof(MyTeamsPage));
    }

    public sealed record EventRow(SportEvent Event)
    {
        public string Name => Event.GameStatusDetail is string d && Event.Status == EventStatus.Finished
            ? $"{Event.Name} · {d}"
            : Event.Name;
        public string League => Event.League;
        public string StatusText => Event.Status switch
        {
            EventStatus.Live => "LIVE",
            EventStatus.Halftime => "HALF",
            EventStatus.Finished => $"FINAL {Event.ScoreAway ?? 0}–{Event.ScoreHome ?? 0}",
            _ => Event.StartTime.LocalDateTime.ToString("g"),
        };
    }
}
