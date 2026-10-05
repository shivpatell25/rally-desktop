using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class EventDetailPage : Page
{
    private readonly PageState _state;
    private SportEvent? _event;
    private GameDetail _detail = GameDetail.Empty;
    private readonly ContentControl _content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Dictionary<string, Button> _tabs = [];
    private string _selected = "Overview";
    public EventDetailPage() { InitializeComponent(); _state = new(this); }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        _event = e.Parameter as SportEvent; if (_event is null) return;
        await _state.Load(async ct =>
        {
            _detail = await App.Data.DetailAsync(_event, ct: ct);
            var save = RallyUi.Button(App.Data.Settings.IsSavedEvent(_event) ? "✓ In My Rally" : "+ Add to My Rally"); save.Click += (_, _) => save.Content = App.Data.Settings.ToggleSavedEvent(_event) ? "✓ In My Rally" : "+ Add to My Rally";
            var header = RallyUi.Row(RallyUi.Button("‹ Back", () => App.Window?.Back()));
            var hero = RallyUi.Hero(_event, () => PageState.Watch(_event), () => { save.Content = App.Data.Settings.ToggleSavedEvent(_event) ? "✓ In My Rally" : "+ Add to My Rally"; }, _detail.Context?.VenueImageUrl);
            if (hero.Children.LastOrDefault() is StackPanel heroBody && heroBody.Children.LastOrDefault() is StackPanel actions && actions.Children.LastOrDefault() is Button secondary) { actions.Children.Remove(secondary); actions.Children.Add(save); }
            var nav = RallyUi.Row(); _tabs.Clear();
            foreach (var title in new[] { "Overview", "Stats", "Players", "Plays", "Sources" }) { var button = RallyUi.Button(title, () => { _selected = title; _ = Render(); }); _tabs[title] = button; nav.Children.Add(button); }
            var body = RallyUi.Column(header, hero, nav, _content); body.Spacing = 18; await Render(); return RallyUi.Scroll(body);
        });
    }
    private async Task Render()
    {
        if (_event is null) return;
        foreach (var tab in _tabs) tab.Value.Background = tab.Key == _selected ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(38, 225, 234, 242)) : RallyUi.Surface;
        if (_selected == "Sources")
        {
            _content.Content = RallyUi.Text("Finding sources…", 14, true);
            try { var sources = await App.Data.SourcesAsync(_event, _state.Token); if (!_state.Token.IsCancellationRequested && _selected == "Sources") _content.Content = GamePanels.Sources(sources, c => PageState.Go(typeof(GameViewPage), new Services.PlaybackRequest(_event, c))); } catch (OperationCanceledException) { } catch { _content.Content = RallyUi.Empty("Sources are unavailable", "Check your connection and source settings."); } return;
        }
        if (_selected == "Stats") { _content.Content = GamePanels.Stats(_event, _detail, false); return; }
        if (_selected == "Players") { _content.Content = GamePanels.Players(_detail); return; }
        if (_selected == "Plays") { _content.Content = GamePanels.Plays(_detail.Plays); return; }
        var grid = RallyUi.Columns(3, 16);
        var info = RallyUi.Column(RallyUi.Text("Game Info", 19, false, true), RallyUi.Text(_detail.Context?.Venue ?? _event.Venue ?? "Venue to be confirmed", 15),
            RallyUi.Text(_detail.Context?.Location ?? "", 13, true), RallyUi.Text(_event.StartTime.LocalDateTime.ToString("ddd, MMM d · h:mm tt"), 15), RallyUi.Text(string.Join(" · ", _detail.Broadcasts.Count > 0 ? _detail.Broadcasts : _event.Broadcasts ?? []), 13, true), RallyUi.Text(_detail.Context?.Weather ?? "", 13, true));
        var form = RallyUi.Column(RallyUi.Text("Team Form", 19, false, true));
        foreach (var team in new[] { _event.AwayTeam, _event.HomeTeam }) { form.Children.Add(RallyUi.Row(RallyUi.Image(team?.LogoUrl, 62, 52), RallyUi.Column(RallyUi.Text(team?.Name ?? "Team", 15, false, true), RallyUi.Text(team?.Records?.FirstOrDefault()?.Summary ?? "Record unavailable", 13, true)))); }
        if (_detail.Context?.HomeWinProbability is double probability) form.Children.Add(RallyUi.Column(RallyUi.Text("Win Probability", 14, false, true), RallyUi.Text($"{_event.AwayTeam?.Abbreviation} {1 - probability:P0}  ·  {_event.HomeTeam?.Abbreviation} {probability:P0}", 14), RallyUi.Text(_detail.Context.PredictionLabel ?? "ESPN", 11, true)));
        var players = RallyUi.Column(RallyUi.Text("Player Stats", 19, false, true));
        foreach (var player in GamePlayers.Merge(_detail.PlayerTables).Take(4)) players.Children.Add(RallyUi.Row(RallyUi.Image(player.HeadshotUrl, 40, 40), RallyUi.Column(RallyUi.Text(player.Name, 13, false, true), RallyUi.Text(string.Join(" · ", player.Stats.Take(2).Select(s => $"{s.Key}: {s.Value}")), 11, true))));
        if (players.Children.Count == 1) players.Children.Add(RallyUi.Text("Player stats appear when the game is underway.", 13, true));
        players.Children.Add(RallyUi.Button("See All Players ›", () => { _selected = "Players"; _ = Render(); }));
        RallyUi.Put(grid, RallyUi.Panel(info), 0); RallyUi.Put(grid, RallyUi.Panel(form), 1); RallyUi.Put(grid, RallyUi.Panel(players), 2); _content.Content = grid;
    }
}
