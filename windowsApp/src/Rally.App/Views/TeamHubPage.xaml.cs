using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class TeamHubPage : Page
{
    private readonly PageState _state;
    public TeamHubPage() { InitializeComponent(); _state = new(this); }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        if (e.Parameter is not FavoriteTeam team) return;
        await _state.Load(async ct =>
        {
            var path = EspnClient.Leagues.FirstOrDefault(l => l.League == team.League);
            var games = (await App.Data.GamesAsync(ct: ct)).Where(g => g.League == team.League && (g.HomeTeam?.Id == team.Id || g.AwayTeam?.Id == team.Id)).ToList();
            var follow = RallyUi.Button(App.Data.Settings.IsFavoriteTeam(team.Id, team.League) ? "✓ Following" : "+ Follow Team"); follow.Click += (_, _) => follow.Content = App.Data.Settings.ToggleFavoriteTeam(team) ? "✓ Following" : "+ Follow Team";
            var body = RallyUi.Column(RallyUi.Row(RallyUi.Button("‹ Back", () => App.Window?.Back()), RallyUi.Image(team.LogoUrl, 72, 72), RallyUi.Text(team.Name, 28, false, true), follow), RallyUi.Heading("Games"), games.Count > 0 ? PageState.Events(games, false) : RallyUi.Empty("No games today", "This team’s next game will appear here."), RallyUi.Heading("Roster"));
            if (path.Path is not null) foreach (var player in await App.Data.Details.FetchTeamRosterAsync(path.Sport, path.Path, team.Id, ct)) body.Children.Add(RallyUi.Row(RallyUi.Image(player.HeadshotUrl, 44, 44), RallyUi.Column(RallyUi.Text(player.Name, 14, false, true), RallyUi.Text($"{player.Position} · #{player.Jersey}", 12, true))));
            return RallyUi.Scroll(body);
        });
    }
}
