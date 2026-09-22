using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Services;
using Rally.Core;

namespace Rally.App.Views;

public sealed partial class HomePage : Page
{
    private readonly EspnClient _espn = new(new HttpClient());
    private readonly SettingsStore _settings = new();
    private readonly AppNotifications _notifications;

    public HomePage()
    {
        InitializeComponent();
        _notifications = new AppNotifications(_settings);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await RefreshAsync().ConfigureAwait(false);
    }

    private async void Retry_Click(object sender, RoutedEventArgs e) => await RefreshAsync().ConfigureAwait(false);

    private async Task RefreshAsync()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = true;
            RetryButton.Visibility = Visibility.Collapsed;
            ErrorText.Visibility = Visibility.Collapsed;
        });
        List<SportEvent> events;
        try
        {
            events = await _espn.FetchAllAsync().ConfigureAwait(false);
            await _notifications.CheckAndNotifyAsync(events).ConfigureAwait(false);
        }
        catch
        {
            // Offline: keep the page alive with an inline error + retry.
            DispatcherQueue.TryEnqueue(() =>
            {
                Spinner.IsActive = false;
                ErrorText.Text = "Couldn't load scores. Check your connection and retry.";
                ErrorText.Visibility = Visibility.Visible;
                RetryButton.Visibility = Visibility.Visible;
            });
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            Spinner.IsActive = false;
            BuildSections(events);
        });
    }

    private void BuildSections(List<SportEvent> events)
    {
        SectionsHost.Children.Clear();
        var live = events
            .Where(e => e.Status is EventStatus.Live or EventStatus.Halftime)
            .OrderBy(e => e.StartTime)
            .ToList();
        if (live.Count > 0)
            SectionsHost.Children.Add(BuildSection("LIVE NOW", live));

        // Upcoming (plus finals) grouped by league in the user's By Sport order.
        var rest = events.Where(e => e.Status is not (EventStatus.Live or EventStatus.Halftime)).ToList();
        var order = _settings.SportsOrder;
        var orderedLeagues = order
            .Where(l => rest.Any(e => e.League == l))
            .Concat(rest.Select(e => e.League).Distinct().Where(l => !order.Contains(l)))
            .ToList();
        foreach (var league in orderedLeagues)
        {
            var rows = rest.Where(e => e.League == league).OrderBy(e => e.StartTime).ToList();
            if (rows.Count > 0)
                SectionsHost.Children.Add(BuildSection(league.ToUpperInvariant(), rows));
        }

        if (SectionsHost.Children.Count == 0)
        {
            ErrorText.Text = "No games right now. Pull to retry later.";
            ErrorText.Visibility = Visibility.Visible;
        }
    }

    private StackPanel BuildSection(string title, List<SportEvent> rows)
    {
        var section = new StackPanel { Spacing = 8 };
        section.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
        });
        foreach (var ev in rows)
            section.Children.Add(BuildRow(ev));
        return section;
    }

    private Border BuildRow(SportEvent ev)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var content = new Button { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
        var lines = new StackPanel { Spacing = 2 };
        lines.Children.Add(new TextBlock
        {
            Text = RowTitle(ev),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        lines.Children.Add(new TextBlock
        {
            Text = $"{ev.League} · {StatusText(ev)}",
            FontSize = 12,
            Opacity = 0.7,
        });
        content.Content = lines;
        content.Tag = ev;
        content.Click += Row_Click;
        Grid.SetColumn(content, 0);
        grid.Children.Add(content);

        // Row star toggles the home team to stay simple (both teams are star-able in detail).
        if (ev.HomeTeam is not null)
        {
            var home = ev.HomeTeam;
            var star = new Button { Content = StarGlyph(ev.League, home.Id), Tag = (ev, home) };
            star.Click += Star_Click;
            Grid.SetColumn(star, 1);
            grid.Children.Add(star);
        }

        return new Border
        {
            Background = (Brush)Application.Current.Resources["RallySurface"],
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8),
            Child = grid,
        };
    }

    private void Row_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: SportEvent ev })
            Frame.Navigate(typeof(EventDetailPage), ev);
    }

    private void Star_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button star || star.Tag is not (SportEvent ev, Team home)) return;
        _settings.ToggleFavoriteTeam(new FavoriteTeam(home.Id, ev.League, home.Name, home.Abbreviation, home.LogoUrl));
        star.Content = StarGlyph(ev.League, home.Id);
    }

    private string StarGlyph(string league, string teamId) =>
        _settings.IsFavoriteTeam(teamId, league) ? "★" : "☆";

    private static string RowTitle(SportEvent ev)
    {
        if (ev.AwayTeam is not null && ev.HomeTeam is not null)
        {
            var score = ev.Status is EventStatus.Live or EventStatus.Halftime or EventStatus.Finished
                ? $"  {ev.ScoreAway?.ToString() ?? "–"} – {ev.ScoreHome?.ToString() ?? "–"}"
                : "";
            return $"{ev.AwayTeam.Abbreviation} @ {ev.HomeTeam.Abbreviation}{score}";
        }
        return ev.Name;
    }

    private static string StatusText(SportEvent ev) => ev.Status switch
    {
        EventStatus.Live => "LIVE",
        EventStatus.Halftime => "HALF",
        EventStatus.Finished => "FINAL",
        EventStatus.Delayed => "DELAYED",
        EventStatus.Canceled => "CANCELED",
        _ => ev.StartTime.LocalDateTime.ToString("g"),
    };
}
