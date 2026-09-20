using Microsoft.UI.Xaml.Controls;
using Rally.Core;

namespace Rally.App.Views;

public sealed partial class HomePage : Page
{
    private readonly EspnClient _espn = new(new HttpClient());

    public HomePage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        Spinner.IsActive = true;
        try { Events.ItemsSource = (await _espn.FetchAllAsync()).Select(e => new EventRow(e)).ToList(); }
        catch { /* offline: empty list, retry on revisit */ }
        finally { Spinner.IsActive = false; }
    }

    private void Events_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Events.SelectedItem is EventRow row)
        {
            Events.SelectedItem = null;
            Frame.Navigate(typeof(PlayerPage), row.Event);
        }
    }

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
