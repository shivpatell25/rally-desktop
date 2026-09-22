using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

// 1:1 with Android WatchlistScreen + WatchlistViewModel and macOS TvMyTeams:
// FOLLOWING cards from FavoriteTeamProfiles, GAMES FOR YOU from FetchAllAsync
// filtered to favorite team ids and sorted by start time.
public sealed partial class MyTeamsPage : Page
{
    private readonly SettingsStore _settings = new();
    private readonly EspnClient _espn = new(new HttpClient());

    public MyTeamsPage()
    {
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await RefreshAsync().ConfigureAwait(false);
    }

    private async Task RefreshAsync()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = true;
            ErrorText.Visibility = Visibility.Collapsed;
        });
        try
        {
            var teams = _settings.FavoriteTeamProfiles;
            var ids = teams.Select(t => t.Id).ToHashSet();
            var events = await _espn.FetchAllAsync().ConfigureAwait(false);
            var mine = events
                .Where(e => (e.HomeTeam?.Id is string h && ids.Contains(h))
                    || (e.AwayTeam?.Id is string a && ids.Contains(a)))
                .OrderBy(e => e.StartTime)
                .ToList();
            DispatcherQueue.TryEnqueue(() =>
            {
                Teams.ItemsSource = teams;
                var hasTeams = teams.Count > 0;
                FollowingTitle.Visibility = hasTeams ? Visibility.Visible : Visibility.Collapsed;
                Teams.Visibility = hasTeams ? Visibility.Visible : Visibility.Collapsed;
                TeamsEmpty.Visibility = hasTeams ? Visibility.Collapsed : Visibility.Visible;
                GamesTitle.Visibility = hasTeams ? Visibility.Visible : Visibility.Collapsed;
                Games.ItemsSource = mine.Select(e => new EventRow(e)).ToList();
                GamesEmpty.Visibility = hasTeams && mine.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            });
        }
        catch
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                ErrorText.Text = "Couldn't load your teams. Check your connection and try again.";
                ErrorText.Visibility = Visibility.Visible;
            });
        }
        finally
        {
            DispatcherQueue.TryEnqueue(() => Spinner.IsActive = false);
        }
    }

    private void Teams_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Teams.SelectedItem is FavoriteTeam team)
        {
            Teams.SelectedItem = null;
            Frame.Navigate(typeof(TeamHubPage), team);
        }
    }

    private void Games_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Games.SelectedItem is EventRow row)
        {
            Games.SelectedItem = null;
            Frame.Navigate(typeof(EventDetailPage), row.Event);
        }
    }

    private void RemoveTeam_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.DataContext is FavoriteTeam team)
        {
            _settings.ToggleFavoriteTeam(team);
            _ = RefreshAsync();
        }
    }

    private void ChooseTeams_Click(object sender, RoutedEventArgs e) =>
        Frame.Navigate(typeof(SettingsPage));

    public sealed record EventRow(SportEvent Event)
    {
        public string Name => Event.Name;
        public string League => Event.League;
        public string StatusText => Event.Status switch
        {
            EventStatus.Live => "LIVE",
            EventStatus.Halftime => "HALF",
            EventStatus.Finished => "FINAL",
            _ => Event.StartTime.LocalDateTime.ToString("g"),
        };
    }
}
