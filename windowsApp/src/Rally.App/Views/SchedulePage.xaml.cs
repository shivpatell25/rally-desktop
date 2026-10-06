using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class SchedulePage : Page
{
    private readonly PageState _state;
    private readonly StackPanel _rows = new() { Spacing = 10 };
    private readonly CalendarDatePicker _date = new() { PlaceholderText = "Date" };
    private readonly ComboBox _sport = new() { Header = "Sport", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _league = new() { Header = "League", HorizontalAlignment = HorizontalAlignment.Stretch };
    private CancellationTokenSource? _query;
    private bool _ready;
    public SchedulePage()
    {
        InitializeComponent(); _state = new(this);
        _sport.ItemsSource = new[] { "All Sports" }.Concat(EspnClient.Leagues.Select(l => l.Sport).Distinct());
        _date.DateChanged += (_, _) => { if (_ready) _ = Refresh(); };
        _sport.SelectionChanged += (_, _) => { if (!_ready) return; Leagues(); _ = Refresh(); };
        _league.SelectionChanged += (_, _) => { if (_ready) _ = Refresh(); };
        Unloaded += (_, _) => _query?.Cancel();
    }
    private void Leagues(string selected = "All Leagues")
    {
        var ready = _ready; _ready = false;
        _league.ItemsSource = new[] { "All Leagues" }.Concat(EspnClient.Leagues.Where(l => _sport.SelectedItem as string == "All Sports" || l.Sport == _sport.SelectedItem as string).Select(l => l.League));
        _league.SelectedItem = selected; if (_league.SelectedIndex < 0) _league.SelectedIndex = 0; _ready = ready;
    }
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate(); _ready = false; _date.Date = _state.Recall("date", DateTimeOffset.Now);
        _sport.SelectedItem = _state.Recall("sport", "All Sports"); Leagues(_state.Recall("league", "All Leagues")); _ready = true;
        _state.Root.Children.Clear(); _state.Root.Children.Add(RallyUi.Scroll(RallyUi.Column(RallyUi.Heading("Schedule"), RallyUi.Flow(_date, _sport, _league, RallyUi.Button("Today", () => _date.Date = DateTimeOffset.Now), RallyUi.Button("Refresh", () => _ = Refresh(true))), _rows))); _ = Refresh();
    }
    private async Task Refresh(bool force = false)
    {
        if (!_ready) return;
        _query?.Cancel(); _query?.Dispose(); _query = CancellationTokenSource.CreateLinkedTokenSource(_state.Token); var ct = _query.Token;
        var date = _date.Date ?? DateTimeOffset.Now; var sport = _sport.SelectedItem as string ?? "All Sports"; var league = _league.SelectedItem as string ?? "All Leagues";
        _state.Remember("date", date); _state.Remember("sport", sport); _state.Remember("league", league);
        _rows.Children.Clear(); _rows.Children.Add(RallyUi.Text("Loading schedule…", 13, true));
        try
        {
            var result = await App.Data.ScheduleAsync(date, sport == "All Sports" ? null : sport, league == "All Leagues" ? null : league, force, ct);
            if (ct.IsCancellationRequested) return; _rows.Children.Clear();
            if (result.UnavailableLeagues.Count > 0) _rows.Children.Add(RallyUi.Text($"Some feeds are unavailable: {string.Join(", ", result.UnavailableLeagues)}. Refresh to retry.", 12, true));
            foreach (var ev in result.Games)
            {
                _rows.Children.Add(RallyUi.Tile(HomePage.GuideRow(ev), RallyUi.Matchup(ev), () => PageState.Event(ev), true));
            }
            if (result.Games.Count == 0) _rows.Children.Add(RallyUi.Empty("No games scheduled", "Choose another date, sport or league."));
            App.Window?.RestorePageState(this);
        }
        catch (OperationCanceledException) { }
        catch { if (!ct.IsCancellationRequested) { _rows.Children.Clear(); _rows.Children.Add(RallyUi.Empty("Schedule is unavailable", "Check your connection.", "Retry", () => _ = Refresh(true))); } }
    }
}
