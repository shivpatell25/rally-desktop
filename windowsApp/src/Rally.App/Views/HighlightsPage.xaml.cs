using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

// Recent ESPN highlight clips, event-linked. Mirrors HighlightsScreen +
// HighlightsViewModel: recent finished/live events, live-first, take 18;
// per-event FetchSummaryAsync with concurrency 3 (SemaphoreSlim), clips
// distinct by id. Clicking a clip passes its StreamUrl string to PlayerPage
// (PlayerPage plays a string param directly as a Stremio-kind one-off — the
// same branch addon search results use; clips without a stream fall back to
// EventDetailPage). The per-row "View event" button navigates to
// EventDetailPage with the SportEvent.
// Thumbnail binds the raw URL string: WinUI converts it to a BitmapImage and
// a failed load simply renders blank, so no image load can crash the page.
public sealed partial class HighlightsPage : Page
{
    private readonly HttpClient _http = new();
    private readonly EspnClient _espn;
    private readonly EspnDetail _detail;

    public HighlightsPage()
    {
        InitializeComponent();
        _espn = new EspnClient(_http);
        _detail = new EspnDetail(_http);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e) => await LoadAsync().ConfigureAwait(false);

    private async void Retry_Click(object sender, RoutedEventArgs e) => await LoadAsync().ConfigureAwait(false);

    private async Task LoadAsync()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = true;
            ErrorText.Visibility = Visibility.Collapsed;
            RetryButton.Visibility = Visibility.Collapsed;
            EmptyText.Visibility = Visibility.Collapsed;
        });
        try
        {
            var events = await _espn.FetchAllAsync().ConfigureAwait(false);
            var seeds = events.OrderBy(Rank).ThenByDescending(e => e.StartTime).Take(18).ToList();
            using var gate = new SemaphoreSlim(3);
            var tasks = seeds.Select(async ev =>
            {
                await gate.WaitAsync().ConfigureAwait(false);
                try { return (Event: ev, Detail: await FetchClipsAsync(ev).ConfigureAwait(false)); }
                finally { gate.Release(); }
            });
            var pairs = await Task.WhenAll(tasks).ConfigureAwait(false);
            var seen = new HashSet<string>();
            var rows = pairs
                .SelectMany(p => p.Detail.Clips.Select(c => new ClipRow(c, p.Event)))
                .Where(r => seen.Add(r.Clip.Id))
                .ToList();
            DispatcherQueue.TryEnqueue(() =>
            {
                Spinner.IsActive = false;
                Clips.ItemsSource = rows;
                EmptyText.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            });
        }
        catch
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                Spinner.IsActive = false;
                ErrorText.Text = "Highlights are unavailable. Check your connection and try again.";
                ErrorText.Visibility = Visibility.Visible;
                RetryButton.Visibility = Visibility.Visible;
            });
        }
    }

    private static int Rank(SportEvent e) => e.Status switch
    {
        EventStatus.Live => 0,
        EventStatus.Halftime => 0,
        EventStatus.Finished => 1,
        _ => 2,
    };

    private async Task<GameDetail> FetchClipsAsync(SportEvent ev)
    {
        try
        {
            var map = EspnClient.Leagues.FirstOrDefault(l =>
                l.League.Equals(ev.League, StringComparison.OrdinalIgnoreCase));
            if (map.League is null) return GameDetail.Empty;
            return await _detail.FetchSummaryAsync(map.Sport, map.Path, ev.Id,
                ev.AwayTeam?.Abbreviation, ev.HomeTeam?.Abbreviation).ConfigureAwait(false);
        }
        catch { return GameDetail.Empty; }
    }

    private void Clips_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Clips.SelectedItem is ClipRow row)
        {
            Clips.SelectedItem = null;
            if (!string.IsNullOrEmpty(row.Clip.StreamUrl))
                Frame.Navigate(typeof(PlayerPage), row.Clip.StreamUrl);
            else
                Frame.Navigate(typeof(EventDetailPage), row.Event);
        }
    }

    private void EventButton_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is SportEvent ev)
            Frame.Navigate(typeof(EventDetailPage), ev);
    }

    public sealed record ClipRow(HighlightClip Clip, SportEvent Event)
    {
        public string Title => Clip.Title;
        public string EventName => Event.Name;
        public string League => Event.League.ToUpperInvariant();
        public string? ThumbnailUrl => Clip.ThumbnailUrl;
        public string DurationText => Clip.DurationSeconds is int s ? $"{s / 60}:{s % 60:00}" : "";
    }
}
