using Microsoft.UI.Xaml.Controls;
using Rally.Core;

namespace Rally.App.Views;

// Leagues directory. Mirrors Android LeaguesScreen + macOS TvLeaguesHome:
// one card per EspnClient.Leagues with live/upcoming counts, routing into
// LeagueCenterPage(league string).
public sealed partial class LeaguesPage : Page
{
    private readonly EspnClient _espn = new(new HttpClient());

    public LeaguesPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await RefreshAsync().ConfigureAwait(false);
    }

    private async Task RefreshAsync()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = true;
            ErrorText.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
        });
        try
        {
            // Per-league guarded fetch: one league failing (offline) shows zero, page still loads.
            var tasks = EspnClient.Leagues.Select(async l =>
            {
                List<SportEvent> events;
                try { events = await _espn.FetchScoreboardAsync(l.Sport, l.Path, l.League).ConfigureAwait(false); }
                catch { events = []; }
                var live = events.Count(e => e.Status is EventStatus.Live or EventStatus.Halftime);
                return new LeagueRow(l.League, live, events.Count);
            });
            var rows = await Task.WhenAll(tasks).ConfigureAwait(false);
            DispatcherQueue.TryEnqueue(() => Leagues.ItemsSource = rows.ToList());
        }
        catch
        {
            // Offline: inline error text, no crash.
            DispatcherQueue.TryEnqueue(() =>
            {
                ErrorText.Text = "League data is unavailable";
                ErrorText.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
            });
        }
        finally
        {
            DispatcherQueue.TryEnqueue(() => Spinner.IsActive = false);
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

    public sealed record LeagueRow(string League, int LiveCount, int TotalCount)
    {
        public string DisplayName => League;
        public string LiveBadge => LiveCount > 0 ? "● LIVE" : "";
        public string Summary => TotalCount == 0 ? "OPEN LEAGUE CENTER" : $"{TotalCount} GAMES";
    }
}
