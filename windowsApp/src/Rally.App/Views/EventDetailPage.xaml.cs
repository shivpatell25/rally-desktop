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
    private readonly TextBlock _notice = RallyUi.Text("Loading game data…", 13, true);
    private readonly ContentControl _hero = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly DispatcherTimer _refresh = new() { Interval = TimeSpan.FromSeconds(40) };
    private int _renderGeneration;
    private bool _loading;
    private Button? _save;
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate(); _event = e.Parameter as SportEvent;
        if (_event is null) { _state.Root.Children.Add(RallyUi.Empty("Game not found", "Open a game from Schedule.", "Schedule", () => App.Window?.NavigateTo("schedule"))); return; }
        _selected = _state.Recall("tab", "Overview");
        var nav = new List<UIElement>(); _tabs.Clear();
        foreach (var title in new[] { "Overview", "Stats", "Lineups", "Players", "Plays", "Sources", "Highlights" })
        { var button = RallyUi.Button(title, () => { _selected = title; _state.Remember("tab", title); _ = Render(); }); _tabs[title] = button; nav.Add(button); }
        var body = RallyUi.Column(RallyUi.Flow(RallyUi.Button("‹ Back", () => App.Window?.Back()), RallyUi.Button("Refresh Game", () => _ = Refresh(true))), _hero, _notice, RallyUi.Flow(nav.ToArray()), _content);
        _state.Root.Children.Clear(); _state.Root.Children.Add(RallyUi.Scroll(body)); UpdateHero(); _ = Refresh();
        _refresh.Tick += (_, _) => { if (_event?.Status is EventStatus.Live or EventStatus.Halftime) _ = Refresh(); };
        Loaded += (_, _) => { _refresh.Start(); App.Data.Settings.Changed += SettingsChanged; };
        Unloaded += (_, _) => { _refresh.Stop(); App.Data.Settings.Changed -= SettingsChanged; };
    }
    private void SettingsChanged(string key) { if (key != "saved_events") return; DispatcherQueue.TryEnqueue(() => { if (!_state.Token.IsCancellationRequested && _save is not null && _event is not null) _save.Content = App.Data.Settings.IsSavedEvent(_event) ? "✓ In My Rally" : "+ Add to My Rally"; }); }
    private void UpdateHero()
    {
        if (_event is null) return;
        using var interaction = _state.PreserveInteraction();
        _save = RallyUi.Button(App.Data.Settings.IsSavedEvent(_event) ? "✓ In My Rally" : "+ Add to My Rally", () => App.Data.Settings.ToggleSavedEvent(_event));
        var hero = RallyUi.Hero(_event, () => PageState.Watch(_event), () => App.Data.Settings.ToggleSavedEvent(_event), _detail.Context?.VenueImageUrl);
        if (hero.Children.LastOrDefault() is StackPanel panel && panel.Children.LastOrDefault() is StackPanel actions && actions.Children.LastOrDefault() is Button secondary) { actions.Children.Remove(secondary); actions.Children.Add(_save); }
        _hero.Content = hero;
    }
    private async Task Refresh(bool force = false)
    {
        if (_loading || _event is null || _state.Token.IsCancellationRequested) return; _loading = true;
        try
        {
            List<SportEvent> games; try { games = await App.Data.GamesAsync(force, _state.Token); } catch (HttpRequestException) { games = []; } if (_state.Token.IsCancellationRequested) return;
            _event = games.FirstOrDefault(g => g.Id == _event.Id && g.League == _event.League) ?? _event;
            _detail = await App.Data.DetailAsync(_event, force, _state.Token); if (_state.Token.IsCancellationRequested) return;
            _notice.Text = ""; UpdateHero(); await Render(); App.Window?.RestorePageState(this);
        }
        catch (OperationCanceledException) { }
        catch { if (!_state.Token.IsCancellationRequested) { _notice.Text = "Detailed game data couldn't load. Refresh to retry; the matchup and watch actions remain available."; await Render(); } }
        finally { _loading = false; }
    }
    private async Task Render()
    {
        if (_event is null || _state.Token.IsCancellationRequested) return;
        var generation = ++_renderGeneration;
        foreach (var tab in _tabs) tab.Value.Background = tab.Key == _selected ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(38, 225, 234, 242)) : RallyUi.Surface;
        if (_selected == "Sources")
        {
            _content.Content = RallyUi.Text("Finding sources…", 14, true);
            try { var sources = await App.Data.SourcesAsync(_event, _state.Token); if (!_state.Token.IsCancellationRequested && _selected == "Sources" && generation == _renderGeneration) _content.Content = GamePanels.Sources(sources, c => PageState.Go(typeof(GameViewPage), new Services.PlaybackRequest(_event, c))); } catch (OperationCanceledException) { } catch { if (!_state.Token.IsCancellationRequested && generation == _renderGeneration) _content.Content = RallyUi.Empty("Sources are unavailable", "Check your connection and source settings.", "Retry", () => _ = Render()); } return;
        }
        if (_selected == "Stats") { _content.Content = GamePanels.Stats(_event, _detail, false); return; }
        if (_selected == "Players") { _content.Content = GamePanels.Players(_detail); return; }
        if (_selected == "Plays") { _content.Content = GamePanels.Plays(_detail.Plays); return; }
        if (_selected == "Lineups") { _content.Content = GamePanels.Lineups(_detail); return; }
        if (_selected == "Highlights")
        {
            _content.Content = _detail.Clips.Count > 0 ? RallyUi.Flow(_detail.Clips.Select(c => (UIElement)HomePage.ClipCard(c, false)).ToArray()) : RallyUi.Empty("No highlights published", "Clips will appear here when available."); return;
        }

        var info = RallyUi.Column(RallyUi.Text("Game Info", 19, false, true), RallyUi.Text(_detail.Context?.Venue ?? _event.Venue ?? "Venue to be confirmed", 15),
            RallyUi.Text(_detail.Context?.Location ?? "", 13, true), RallyUi.Text(_event.StartTime.LocalDateTime.ToString("ddd, MMM d · h:mm tt"), 15), RallyUi.Text(string.Join(" · ", _detail.Broadcasts.Count > 0 ? _detail.Broadcasts : _event.Broadcasts ?? []), 13, true), RallyUi.Text(_detail.Context?.Weather ?? "", 13, true));
        var form = RallyUi.Column(RallyUi.Text("Team Form", 19, false, true));
        foreach (var team in new[] { _event.AwayTeam, _event.HomeTeam }.OfType<Team>())
        {
            var record = RallyUi.Tile(RallyUi.Row(RallyUi.Image(team.LogoUrl, 62, 52), RallyUi.Column(RallyUi.Text(team.Name, 15, false, true), RallyUi.Text(team.Records?.FirstOrDefault()?.Summary ?? "Record unavailable", 13, true))), team.Name, () => PageState.Go(typeof(TeamHubPage), new FavoriteTeam(team.Id, _event.League, team.Name, team.Abbreviation, team.LogoUrl))); form.Children.Add(record);
            foreach (var game in _detail.TeamForm.Where(g => g.TeamId == team.Id).OrderByDescending(g => g.Date).Take(5)) form.Children.Add(RallyUi.Row(RallyUi.Image(game.OpponentLogo, 24, 24), RallyUi.Text($"{game.Result} · {game.Opponent} · {game.Score}", 12, true)));
        }
        if (_detail.Context?.HomeWinProbability is double probability) form.Children.Add(RallyUi.Column(RallyUi.Text("Win Probability", 14, false, true), RallyUi.Text($"{_event.AwayTeam?.Abbreviation} {1 - probability:P0}  ·  {_event.HomeTeam?.Abbreviation} {probability:P0}", 14), RallyUi.Text(_detail.Context.PredictionLabel ?? "ESPN", 11, true)));
        var players = RallyUi.Column(RallyUi.Text("Player Stats", 19, false, true));
        foreach (var player in GamePlayers.Merge(_detail.PlayerTables).Take(4)) players.Children.Add(RallyUi.Row(RallyUi.Image(player.HeadshotUrl, 40, 40), RallyUi.Column(RallyUi.Text(player.Name, 13, false, true), RallyUi.Text(string.Join(" · ", player.Stats.Take(2).Select(s => $"{s.Key}: {s.Value}")), 11, true))));
        if (players.Children.Count == 1) players.Children.Add(RallyUi.Text("Player stats appear when the game is underway.", 13, true));
        players.Children.Add(RallyUi.Button("See All Players ›", () => { _selected = "Players"; _ = Render(); }));
        var injuries = RallyUi.Column(RallyUi.Text("Injuries / Availability", 19, false, true), RallyUi.Text("Loading availability…", 13, true));
        var overview = RallyUi.Column(RallyUi.Flow(RallyUi.Panel(info), RallyUi.Panel(form), RallyUi.Panel(players)), RallyUi.Panel(injuries)); _content.Content = overview;
        var path = EspnClient.Leagues.FirstOrDefault(l => l.League == _event.League);
        if (path.Path is null) { injuries.Children.RemoveAt(1); injuries.Children.Add(RallyUi.Text("Availability is not published for this competition.", 13, true)); return; }
        var results = await Task.WhenAll(new[] { _event.AwayTeam, _event.HomeTeam }.OfType<Team>().Select(async team =>
        {
            try { return (Team: team, Entries: _detail.Injuries.TryGetValue(team.Id, out var reported) ? reported : await App.Data.Details.FetchTeamInjuriesAsync(path.Sport, path.Path, team.Id, _state.Token), Failed: false); }
            catch (OperationCanceledException) { return (Team: team, Entries: new List<InjuryEntry>(), Failed: true); }
            catch { return (Team: team, Entries: new List<InjuryEntry>(), Failed: true); }
        }));
        if (_state.Token.IsCancellationRequested || generation != _renderGeneration) return; injuries.Children.RemoveAt(1);
        foreach (var result in results)
        {
            injuries.Children.Add(RallyUi.Text(result.Team.Name, 14, false, true));
            foreach (var entry in result.Entries) injuries.Children.Add(RallyUi.Column(RallyUi.Text($"{entry.PlayerName} · {entry.Status}", 13), RallyUi.Text(entry.Detail ?? "", 12, true)));
            if (result.Entries.Count == 0) injuries.Children.Add(RallyUi.Text(result.Failed ? "Availability couldn't load. Refresh to retry." : "No injuries reported by this feed.", 12, true));
        }
    }
}
