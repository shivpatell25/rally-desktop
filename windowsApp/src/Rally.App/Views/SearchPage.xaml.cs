using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class SearchPage : Page
{
    private readonly PageState _state;
    private readonly TextBox _query = new() { PlaceholderText = "Search games, teams, channels and sources", FontSize = 20 };
    private readonly StackPanel _results = new() { Spacing = 16 };
    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(300) };
    private CancellationTokenSource? _request;
    public SearchPage()
    {
        InitializeComponent(); _state = new(this); _query.TextChanged += (_, _) => { _debounce.Stop(); _debounce.Start(); };
        _debounce.Tick += (_, _) => { _debounce.Stop(); _ = Search(); }; Unloaded += (_, _) => { _debounce.Stop(); _request?.Cancel(); };
    }
    protected override void OnNavigatedTo(NavigationEventArgs e) { _state.Activate(); _state.Root.Children.Clear(); _state.Root.Children.Add(RallyUi.Scroll(RallyUi.Column(RallyUi.Heading("Search"), _query, _results))); _query.Focus(FocusState.Programmatic); }
    private async Task Search()
    {
        _request?.Cancel(); _request?.Dispose(); _request = CancellationTokenSource.CreateLinkedTokenSource(_state.Token); var ct = _request.Token;
        var query = _query.Text.Trim(); _results.Children.Clear(); if (query.Length < 2) return;
        _results.Children.Add(RallyUi.Text("Searching…", 13, true));
        try
        {
            var games = (await App.Data.GamesAsync(ct: ct)).Where(g => (g.Name + " " + g.League + " " + g.HomeTeam?.Name + " " + g.AwayTeam?.Name).Contains(query, StringComparison.OrdinalIgnoreCase)).Take(18).ToList();
            if (ct.IsCancellationRequested) return; _results.Children.Clear(); if (games.Count > 0) { _results.Children.Add(RallyUi.Heading("Games")); _results.Children.Add(PageState.Events(games, false)); }
            var teams = games.SelectMany(g => new[] { g.HomeTeam, g.AwayTeam }).OfType<Team>().Where(t => t.Name.Contains(query, StringComparison.OrdinalIgnoreCase)).DistinctBy(t => t.Id).Take(6);
            foreach (var team in teams) { var league = games.First(g => g.HomeTeam?.Id == team.Id || g.AwayTeam?.Id == team.Id).League; _results.Children.Add(RallyUi.Tile(RallyUi.Row(RallyUi.Image(team.LogoUrl, 32, 32), RallyUi.Text(team.Name, 15)), team.Name, () => PageState.Go(typeof(TeamHubPage), new FavoriteTeam(team.Id, league, team.Name, team.Abbreviation, team.LogoUrl)))); }
            List<IptvChannel> channels; try { channels = (await App.Data.ChannelsAsync(ct: ct)).Where(c => (c.Name + " " + c.Guide?.Now?.Title).Contains(query, StringComparison.OrdinalIgnoreCase)).Take(25).ToList(); } catch (OperationCanceledException) { throw; } catch { channels = []; }
            if (ct.IsCancellationRequested) return;
            if (channels.Count > 0) _results.Children.Add(RallyUi.Heading("Channels"));
            foreach (var channel in channels) _results.Children.Add(RallyUi.Button(channel.Name, () => PageState.Go(typeof(PlayerPage), channel)));
            var options = await Task.WhenAll(App.Data.Settings.StremioAddonUrls.Select(async addon => { try { return await App.Data.Addons.SearchAsync(query, addon, ct); } catch (OperationCanceledException) { throw; } catch { return new List<StremioStreamOption>(); } }));
            if (ct.IsCancellationRequested) return;
            var candidates = options.SelectMany(x => x).Where(o => o.IsDirectPlayable).DistinctBy(o => o.StreamUrl).Select(o => new PlayCandidate(Guid.NewGuid().ToString(), o.Title, o.StreamUrl, o.Headers, PlayKind.Stremio, true, 0, AddonName: o.AddonName)).ToList();
            if (candidates.Count > 0) { _results.Children.Add(RallyUi.Heading("Streaming Sources")); _results.Children.Add(GamePanels.Sources(candidates, c => PageState.Go(typeof(PlayerPage), c))); }
            if (_results.Children.Count == 0) _results.Children.Add(RallyUi.Empty("No results", "Try a team, matchup, league, or channel name."));
        }
        catch (OperationCanceledException) { }
        catch { if (!ct.IsCancellationRequested) _results.Children.Add(RallyUi.Empty("Search couldn't finish", "Check your connection.", "Retry", () => _ = Search())); }
    }
}
