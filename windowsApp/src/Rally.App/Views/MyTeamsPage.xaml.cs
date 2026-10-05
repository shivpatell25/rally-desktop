using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class MyTeamsPage : Page
{
    private readonly PageState _state;
    public MyTeamsPage() { InitializeComponent(); _state = new(this); }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        await _state.Load(async ct =>
        {
            var body = RallyUi.Column(RallyUi.Heading("My Rally")); var favorites = App.Data.Settings.FavoriteTeamProfiles;
            var teams = RallyUi.Columns(4, 16); teams.RowSpacing = 16; var i = 0;
            foreach (var team in favorites) { if (i % 4 == 0) teams.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); var card = RallyUi.Tile(RallyUi.Column(RallyUi.Image(team.LogoUrl, 58, 58), RallyUi.Text(team.Name, 14, false, true)), team.Name, () => PageState.Go(typeof(TeamHubPage), team), true); card.Padding = new Thickness(18); RallyUi.Put(teams, card, i % 4, i / 4); i++; }
            if (i == 0) body.Children.Add(RallyUi.Empty("Follow your teams", "Find a team in Leagues and choose Follow Team.", "Browse Leagues", () => App.Window?.NavigateTo("leagues"))); else body.Children.Add(teams);
            var games = (await App.Data.GamesAsync(ct: ct)).Where(g => favorites.Any(t => t.League == g.League && (t.Id == g.HomeTeam?.Id || t.Id == g.AwayTeam?.Id))).ToList();
            body.Children.Add(RallyUi.Heading("Your Games")); body.Children.Add(games.Count > 0 ? PageState.Events(games) : RallyUi.Empty("No team games today", "Your followed teams’ games will appear here."));
            var saved = App.Data.Settings.SavedEvents; if (saved.Count > 0) { body.Children.Add(RallyUi.Heading("Saved Games")); body.Children.Add(PageState.Events(saved)); }
            return RallyUi.Scroll(body);
        });
    }
}
