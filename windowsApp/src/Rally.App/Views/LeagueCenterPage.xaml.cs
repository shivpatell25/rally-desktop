using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class LeagueCenterPage : Page
{
    private readonly PageState _state;
    private readonly ContentControl _content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private string _league = "NFL";
    public LeagueCenterPage() { InitializeComponent(); _state = new(this); }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        _league = e.Parameter as string ?? "NFL";
        var body = RallyUi.Column(RallyUi.Row(RallyUi.Button("‹ Leagues", () => App.Window?.NavigateTo("leagues")), RallyUi.SportMark(_league), RallyUi.Text(_league, 26, false, true)),
            RallyUi.Row(RallyUi.Button("Games", () => _ = Load("Games")), RallyUi.Button("Standings", () => _ = Load("Standings")), RallyUi.Button("Teams", () => _ = Load("Teams")), RallyUi.Button("Postseason", () => _ = Load("Postseason")), RallyUi.Button("Channels", () => _ = Load("Channels"))), _content);
        _state.Root.Children.Clear(); _state.Root.Children.Add(RallyUi.Scroll(body)); await Load("Games");
    }
    private static Grid StandingColumns(UIElement team, string wins, string losses, string percentage)
    {
        var grid = RallyUi.Columns(4, 12); grid.ColumnDefinitions[0].Width = new GridLength(1, GridUnitType.Star);
        grid.ColumnDefinitions[1].Width = grid.ColumnDefinitions[2].Width = new GridLength(50);
        grid.ColumnDefinitions[3].Width = new GridLength(100);
        RallyUi.Put(grid, team, 0); RallyUi.Put(grid, RallyUi.Text(wins, 13, true), 1);
        RallyUi.Put(grid, RallyUi.Text(losses, 13, true), 2); RallyUi.Put(grid, RallyUi.Text(percentage, 13, true), 3);
        return grid;
    }
    private async Task Load(string tab)
    {
        _content.Content = RallyUi.Text("Loading…", 13, true);
        try
        {
            var leagues = EspnClient.Leagues.Where(l => l.League == _league || _league == "Soccer" && l.Sport == "soccer").ToList();
            if (tab == "Games") { var games = (await App.Data.GamesAsync(ct: _state.Token)).Where(g => leagues.Any(l => l.League == g.League)); _content.Content = games.Any() ? PageState.Events(games, false) : RallyUi.Empty("No games today", "Browse Schedule to see the next matchups.", "Schedule", () => App.Window?.NavigateTo("schedule")); return; }
            var sections = new StackPanel { Spacing = 18 };
            if (tab == "Channels")
            {
                var channels = await App.Data.ChannelsAsync(ct: _state.Token);
                var matching = channels.Where(c => c.Name.Contains(_league, StringComparison.OrdinalIgnoreCase) || _league == "Soccer" && new[] { "soccer", "football", "premier", "liga", "champions", "beIN" }.Any(k => c.Name.Contains(k, StringComparison.OrdinalIgnoreCase))).ToList();
                foreach (var channel in matching) sections.Children.Add(RallyUi.Tile(RallyUi.Row(RallyUi.Image(channel.LogoUrl, 42, 42), RallyUi.Text(channel.Name, 15, false, true), RallyUi.Text(channel.Guide?.Now?.Title ?? channel.Category, 12, true)), channel.Name, () => PageState.Go(typeof(PlayerPage), channel), true));
                if (matching.Count == 0) sections.Children.Add(RallyUi.Empty("No matching channels", "Connect a provider to find this league’s channels.", "Streaming Settings", () => App.Window?.NavigateTo("settings")));
                _content.Content = sections; return;
            }
            if (tab == "Postseason")
            {
                var games = (await App.Data.GamesAsync(ct: _state.Token)).Where(g => leagues.Any(l => l.League == g.League) && LeagueHub.IsPostseason(g)).ToList();
                if (games.Count > 0) { _content.Content = PageState.Events(games); return; }
                sections.Children.Add(RallyUi.Text("Playoff Picture", 20, false, true)); sections.Children.Add(RallyUi.Text("Current standings order. Qualification and seeding may change.", 12, true));
            }
            foreach (var league in leagues)
            {
                if (tab == "Teams")
                {
                    var teams = await App.Data.Details.FetchTeamsAsync(league.Sport, league.Path, _state.Token);
                    var grid = RallyUi.Columns(4, 14); grid.RowSpacing = 14; var i = 0;
                    foreach (var team in teams) { if (i % 4 == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); var card = RallyUi.Tile(RallyUi.Column(RallyUi.Image(team.LogoUrl, 58, 58), RallyUi.Text(team.Name, 13, false, true)), team.Name, () => PageState.Go(typeof(TeamHubPage), new FavoriteTeam(team.Id, league.League, team.Name, team.Abbreviation, team.LogoUrl)), true); card.Padding = new Thickness(16); RallyUi.Put(grid, card, i % 4, i / 4); i++; } sections.Children.Add(grid);
                }
                else
                {
                    var rows = await App.Data.Details.FetchStandingsAsync(league.Sport, league.Path, _state.Token);
                    if (leagues.Count > 1) sections.Children.Add(RallyUi.Heading(league.League));
                    sections.Children.Add(StandingColumns(RallyUi.Text("TEAM", 12, true, true), "W", "L", "PCT / GB"));
                    foreach (var row in tab == "Postseason" ? rows.Take(LeagueHub.Cutoff(_league)) : rows) sections.Children.Add(RallyUi.Tile(StandingColumns(RallyUi.Row(RallyUi.Image(row.LogoUrl, 32, 32), RallyUi.Text(row.TeamName, 15, false, true)), row.Wins.ToString(), row.Losses.ToString(), $"{row.Pct} {row.Gb}".Trim()), row.TeamName, () => PageState.Go(typeof(TeamHubPage), new FavoriteTeam(row.TeamId, league.League, row.TeamName, row.Abbreviation, row.LogoUrl))));
                    if (rows.Count == 0) sections.Children.Add(RallyUi.Empty("Standings aren't available", "This sport may not publish team standings."));
                }
            }
            _content.Content = sections;
        }
        catch (OperationCanceledException) { }
        catch { _content.Content = RallyUi.Empty("Couldn't load league data", "Check your connection.", "Retry", () => _ = Load(tab)); }
    }
}
