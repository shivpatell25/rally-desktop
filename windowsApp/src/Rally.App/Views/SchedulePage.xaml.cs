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
    private readonly CalendarDatePicker _date = new() { Date = DateTimeOffset.Now, PlaceholderText = "Date" };
    private readonly ComboBox _league = new() { Width = 170 };
    private CancellationTokenSource? _query;
    public SchedulePage() { InitializeComponent(); _state = new(this); _league.ItemsSource = new[] { "All Sports" }.Concat(EspnClient.Leagues.Select(l => l.League)); _league.SelectedIndex = 0; _date.DateChanged += (_, _) => _ = Refresh(); _league.SelectionChanged += (_, _) => _ = Refresh(); }
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        var body = RallyUi.Column(RallyUi.Heading("Schedule"), RallyUi.Row(_date, _league, RallyUi.Button("Today", () => _date.Date = DateTimeOffset.Now)), _rows);
        _state.Root.Children.Clear(); _state.Root.Children.Add(RallyUi.Scroll(body)); _ = Refresh();
    }
    private async Task Refresh()
    {
        if (_state.Root.Children.Count == 0) return;
        _query?.Cancel(); _query?.Dispose(); _query = CancellationTokenSource.CreateLinkedTokenSource(_state.Token); var ct = _query.Token;
        _rows.Children.Clear(); _rows.Children.Add(RallyUi.Text("Loading schedule…", 13, true));
        var selected = _league.SelectedItem as string ?? "All Sports";
        try
        {
            var date = (_date.Date ?? DateTimeOffset.Now).ToString("yyyyMMdd");
            var results = await Task.WhenAll(EspnClient.Leagues.Where(l => selected == "All Sports" || l.League == selected).Select(async league =>
            { try { return await App.Data.Espn.FetchScoreboardAsync(league.Sport, league.Path, league.League, dates: date, ct: ct); } catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; } catch { return new List<SportEvent>(); } }));
            if (ct.IsCancellationRequested) return; _rows.Children.Clear();
            foreach (var ev in results.SelectMany(x => x).OrderBy(e => e.StartTime))
            { var button = RallyUi.Tile(HomePage.GuideRow(ev), RallyUi.Matchup(ev), () => PageState.Event(ev), true); _rows.Children.Add(button); }
            if (_rows.Children.Count == 0) _rows.Children.Add(RallyUi.Empty("No games scheduled", "Choose another date or sport."));
        }
        catch (OperationCanceledException) { }
        catch { _rows.Children.Clear(); _rows.Children.Add(RallyUi.Empty("Schedule is unavailable", "Check your connection.", "Retry", () => _ = Refresh())); }
    }
}
