using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class MyTeamsPage : Page
{
    private readonly PageState _state;
    private List<SportEvent> _games = [];
    private bool _failed;
    public MyTeamsPage()
    {
        InitializeComponent(); _state = new(this);
        Loaded += (_, _) => App.Data.Settings.Changed += Changed;
        Unloaded += (_, _) => App.Data.Settings.Changed -= Changed;
    }
    private void Changed(string key) { if (key is not ("saved_events" or "favorite_team_profiles_v2")) return; DispatcherQueue.TryEnqueue(() => { if (!_state.Token.IsCancellationRequested) Render(true); }); }
    protected override void OnNavigatedTo(NavigationEventArgs e) { _state.Activate(); Render(); _ = Refresh(); }
    private async Task Refresh()
    {
        try { _games = await App.Data.GamesAsync(ct: _state.Token); _failed = false; }
        catch (OperationCanceledException) { return; } catch { _failed = true; }
        if (!_state.Token.IsCancellationRequested) Render();
    }
    private void Render(bool preserveScroll = false)
    {
        var offset = preserveScroll ? (_state.Root.Children.OfType<ScrollViewer>().FirstOrDefault()?.VerticalOffset ?? 0) : 0;
        var body = RallyUi.Column(RallyUi.Heading("My Rally")); var favorites = App.Data.Settings.FavoriteTeamProfiles;
        var cards = favorites.Select(team => (UIElement)RallyUi.Panel(RallyUi.Column(RallyUi.Tile(RallyUi.Column(RallyUi.Image(team.LogoUrl, 58, 58), RallyUi.Text(team.Name, 14, false, true)), team.Name, () => PageState.Go(typeof(TeamHubPage), team)), RallyUi.Button("Unfollow", () => App.Data.Settings.ToggleFavoriteTeam(team))))).ToArray();
        body.Children.Add(cards.Length > 0 ? RallyUi.Flow(cards) : RallyUi.Empty("Follow your teams", "Find a team in Leagues and choose Follow Team.", "Browse Leagues", () => App.Window?.NavigateTo("leagues")));
        var games = _games.Where(g => favorites.Any(t => t.League == g.League && (t.Id == g.HomeTeam?.Id || t.Id == g.AwayTeam?.Id))).ToList();
        body.Children.Add(RallyUi.Heading("Your Games"));
        body.Children.Add(_failed ? RallyUi.Empty("Today's games couldn't load", "Your saved games and teams are available below.", "Retry", () => _ = Refresh()) : games.Count > 0 ? PageState.Events(games) : RallyUi.Empty("No team games today", "Your followed teams’ games will appear here."));
        body.Children.Add(RallyUi.Heading("Saved Games"));
        var saved = App.Data.Settings.SavedEvents;
        foreach (var previous in saved)
        {
            var ev = _games.FirstOrDefault(g => g.League == previous.League && g.Id == previous.Id) ?? previous;
            body.Children.Add(RallyUi.Panel(RallyUi.Column(RallyUi.Tile(HomePage.GuideRow(ev), RallyUi.Matchup(ev), () => PageState.Event(ev)), RallyUi.Button("Remove Saved Game", () => App.Data.Settings.ToggleSavedEvent(ev)))));
        }
        if (saved.Count == 0) body.Children.Add(RallyUi.Empty("No saved games", "Add a game to My Rally from its details or Schedule."));
        _state.Root.Children.Clear(); var scroll = RallyUi.Scroll(body); _state.Root.Children.Add(scroll); if (preserveScroll) scroll.Loaded += (_, _) => scroll.ChangeView(null, offset, null, true); else App.Window?.RestorePageState(this);
    }
}
