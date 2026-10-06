using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class SearchPage : Page
{
    private readonly PageState _state;
    private readonly TextBox _query = new() { PlaceholderText = "Search games, leagues, teams, channels and sources", FontSize = 20 };
    private readonly StackPanel _results = new() { Spacing = 16 };
    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(300) };
    private CancellationTokenSource? _request;
    public SearchPage()
    {
        InitializeComponent(); _state = new(this); _query.TextChanged += (_, _) => { _state.Remember("query", _query.Text); _request?.Cancel(); _debounce.Stop(); _debounce.Start(); };
        _debounce.Tick += (_, _) => { _debounce.Stop(); _ = Search(); }; Unloaded += (_, _) => { _debounce.Stop(); _request?.Cancel(); };
    }
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate(); if (e.NavigationMode != NavigationMode.Back) Loaded += FocusQuery; _query.Text = _state.Recall("query", ""); _state.Root.Children.Clear();
        _state.Root.Children.Add(RallyUi.Scroll(RallyUi.Column(RallyUi.Heading("Search"), _query, _results)));
        if (_query.Text.Length > 1) _ = Search(); else _results.Children.Add(RallyUi.Text("Enter at least two characters to search Rally.", 14, true));
    }
    private void FocusQuery(object sender, RoutedEventArgs e) { Loaded -= FocusQuery; _query.Focus(FocusState.Keyboard); }
    private async Task Search()
    {
        _request?.Cancel(); _request?.Dispose(); _request = CancellationTokenSource.CreateLinkedTokenSource(_state.Token); var ct = _request.Token;
        var query = _query.Text.Trim(); _results.Children.Clear(); if (query.Length < 2) { _results.Children.Add(RallyUi.Text("Enter at least two characters.", 13, true)); return; }
        bool Matches(string text) => text.Contains(query, StringComparison.OrdinalIgnoreCase);
        var found = 0; var failures = 0;
        var progress = RallyUi.Text("Searching Rally…", 13, true); _results.Children.Add(progress);
        void Add(string title, UIElement element, int count) { if (ct.IsCancellationRequested || count == 0) return; found += count; _results.Children.Add(RallyUi.Heading(title)); _results.Children.Add(element); }
        var leagues = EspnClient.Leagues.Where(l => Matches(l.League + " " + l.Sport)).ToList();
        Add("Leagues", RallyUi.Flow(leagues.Select(l => (UIElement)RallyUi.Button(l.League, () => PageState.Go(typeof(LeagueCenterPage), l.League))).ToArray()), leagues.Count);
        async Task Games()
        {
            try { var all = await App.Data.GamesAsync(ct: ct); if (ct.IsCancellationRequested) return; var games = all.Where(g => Matches(g.Name + " " + g.League + " " + g.HomeTeam?.Name + " " + g.AwayTeam?.Name)).Take(30).ToList(); Add("Games", PageState.Events(games), games.Count); }
            catch (OperationCanceledException) { } catch { failures++; }
        }
        async Task Teams()
        {
            var groups = await Task.WhenAll(EspnClient.Leagues.Select(async league =>
            {
                try { var teams = await App.Data.TeamsAsync(league.League, ct); return teams.Where(t => Matches(t.Name + " " + t.Abbreviation)).Select(t => new FavoriteTeam(t.Id, league.League, t.Name, t.Abbreviation, t.LogoUrl)).ToList(); }
                catch (OperationCanceledException) { return []; } catch { failures++; return new List<FavoriteTeam>(); }
            }));
            if (ct.IsCancellationRequested) return;
            var teams = groups.SelectMany(t => t).DistinctBy(t => t.Key).Take(40).ToList();
            Add("Teams", RallyUi.Flow(teams.Select(t => (UIElement)RallyUi.Tile(RallyUi.Column(RallyUi.Image(t.LogoUrl, 40, 40), RallyUi.Text(t.Name, 14, false, true), RallyUi.Text(t.League, 12, true)), t.Name, () => PageState.Go(typeof(TeamHubPage), t), true)).ToArray()), teams.Count);
        }
        async Task Channels()
        {
            try { var channels = (await App.Data.ChannelsAsync(ct: ct)).Where(c => Matches(c.Name + " " + c.Guide?.Now?.Title)).Take(40).ToList(); if (ct.IsCancellationRequested) return; Add("Channels", RallyUi.Flow(channels.Select(c => (UIElement)RallyUi.Button(c.Name, () => PageState.Go(typeof(PlayerPage), c))).ToArray()), channels.Count); }
            catch (OperationCanceledException) { } catch { failures++; }
        }
        async Task Sources()
        {
            var groups = await Task.WhenAll(App.Data.Settings.StremioAddonUrls.Select(async url => { try { return await App.Data.Addons.SearchAsync(query, url, ct); } catch (OperationCanceledException) { return []; } catch { failures++; return new List<StremioStreamOption>(); } }));
            if (ct.IsCancellationRequested) return;
            var options = groups.SelectMany(g => g).Where(o => o.IsDirectPlayable).DistinctBy(o => o.StreamUrl).Select(o => new PlayCandidate(o.StreamUrl, o.Title, o.StreamUrl, o.Headers, PlayKind.Stremio, true, 0, AddonName: o.AddonName)).ToList();
            Add("Sources", GamePanels.Sources(options, c => PageState.Go(typeof(PlayerPage), c)), options.Count);
        }
        await Task.WhenAll(Games(), Teams(), Channels(), Sources()); if (ct.IsCancellationRequested) return;
        _results.Children.Remove(progress);
        if (failures > 0) _results.Children.Add(RallyUi.Empty("Some search feeds are unavailable", "Available results are shown above. Check your connection or provider settings.", "Retry Search", () => _ = Search()));
        if (found == 0 && failures == 0) _results.Children.Add(RallyUi.Empty("No results", "Try another team, matchup, league or channel name."));
        App.Window?.RestorePageState(this);
    }
}
