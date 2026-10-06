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
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate(); if (e.Parameter is not FavoriteTeam team) { _state.Root.Children.Add(RallyUi.Empty("Team not found", "Choose a team from Leagues.")); return; }
        var follow = RallyUi.Button(App.Data.Settings.IsFavoriteTeam(team.Id, team.League) ? "✓ Following" : "+ Follow Team"); follow.Click += (_, _) => follow.Content = App.Data.Settings.ToggleFavoriteTeam(team) ? "✓ Following" : "+ Follow Team";
        var body = RallyUi.Column(RallyUi.Flow(RallyUi.Button("‹ Back", () => App.Window?.Back()), RallyUi.Image(team.LogoUrl, 72, 72), RallyUi.Text(team.Name, 28, false, true), follow));
        _state.Root.Children.Clear(); _state.Root.Children.Add(RallyUi.Scroll(body));
        var path = EspnClient.Leagues.FirstOrDefault(l => l.League == team.League);
        async Task Load(string title, Func<CancellationToken, Task<UIElement>> action)
        {
            var slot = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, Content = RallyUi.Text($"Loading {title.ToLowerInvariant()}…", 13, true) }; body.Children.Add(RallyUi.Heading(title)); body.Children.Add(slot);
            async Task Fetch()
            {
                try { var result = await action(_state.Token); if (!_state.Token.IsCancellationRequested) { slot.Content = result; App.Window?.RestorePageState(this); } }
                catch (OperationCanceledException) { }
                catch { if (!_state.Token.IsCancellationRequested) slot.Content = RallyUi.Empty($"{title} couldn't load", "Check your connection.", "Retry", () => _ = Fetch()); }
            }
            await Fetch();
        }
        _ = Load("Games", async ct => { var games = await App.Data.TeamGamesAsync(team, ct); return games.Count > 0 ? PageState.Events(games.OrderBy(g => g.StartTime)) : RallyUi.Empty("No season schedule published", "The next matchups will appear when reported."); });
        if (path.Path is null) return;
        _ = Load("Roster", async ct => { var players = await App.Data.Details.FetchTeamRosterAsync(path.Sport, path.Path, team.Id, ct); var roster = new StackPanel { Spacing = 12 }; foreach (var player in players) roster.Children.Add(RallyUi.Row(RallyUi.Image(player.HeadshotUrl, 44, 44), RallyUi.Column(RallyUi.Text(player.Name, 14, false, true), RallyUi.Text($"{player.Position} · #{player.Jersey}", 12, true)))); if (players.Count == 0) roster.Children.Add(RallyUi.Empty("Roster not published", "Check back when this team's roster is available.")); return roster; });
        _ = Load("Injuries / Availability", async ct => { var entries = await App.Data.Details.FetchTeamInjuriesAsync(path.Sport, path.Path, team.Id, ct); var list = new StackPanel { Spacing = 12 }; foreach (var injury in entries) list.Children.Add(RallyUi.Column(RallyUi.Text($"{injury.PlayerName} · {injury.Status}", 14), RallyUi.Text(injury.Detail ?? "", 12, true))); if (entries.Count == 0) list.Children.Add(RallyUi.Text("No injuries reported by this feed.", 13, true)); return list; });
    }
}
