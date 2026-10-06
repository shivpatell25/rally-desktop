using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.App.Services;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class MultiViewPage : Page
{
    private sealed record Tile(PlaybackSession Session, SportEvent? Game, string Name, Grid Surface);
    private readonly PageState _state;
    private readonly List<Tile> _tiles = [];
    private readonly Grid _streams = new() { ColumnSpacing = 8, RowSpacing = 8 };
    private readonly StackPanel _toolbar = new() { Orientation = Orientation.Horizontal, Spacing = 10 };
    private readonly ContentControl _stats = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Border _statsHost;
    private bool _showStats, _immersive, _adding;
    private int _audio;
    private DateTimeOffset _statsAt;
    private bool _statsLoading;
    private int _statsGeneration;
    private bool _redZoneLoading, _redZoneSeeded;
    private DateTimeOffset _redZoneAt;
    private readonly HashSet<string> _redZonePlays = [];
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
#if DEBUG
    internal object SnapshotForQa() => new { stats = _showStats, immersive = _immersive,
        streams = _tiles.Select(t => new { t.Name, game = t.Game is null ? null : $"{t.Game.League}:{t.Game.Id}", playing = t.Session.IsPlaying,
            videoReady = t.Session.HasVideoFrames,
            muted = t.Session.Player?.Mute, diagnostics = t.Session.Diagnostics() }).ToArray() };
    internal async Task WaitForVideoForQa()
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(25);
        while (_tiles.Any(t => !t.Session.IsPlaying || !t.Session.HasVideoFrames) && DateTimeOffset.UtcNow < deadline) await Task.Delay(200);
        if (_tiles.Count == 0 || _tiles.Any(t => !t.Session.IsPlaying || !t.Session.HasVideoFrames)) throw new TimeoutException("Every multiview stream must display a video frame.");
        if (App.Playback.Player is not null) throw new InvalidOperationException("The main decoder remained allocated in multiview.");
    }
    internal Task RetryForQa(int index) => _tiles[index].Session.RetryAsync();
    internal void FocusForQa(int index, bool selectAudio)
    {
        var footer = (Grid)_tiles[index].Surface.Children[1]; var button = footer.Children.OfType<Button>().First();
        button.Focus(FocusState.Keyboard);
        if (selectAudio) { var peer = new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button); ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke(); }
    }
    internal async Task AddForQa(int count)
    {
        var games = await App.Data.GamesAsync();
        while (_tiles.Count < Math.Min(4, count)) { var game = games[_tiles.Count % games.Count]; var source = (await App.Data.SourcesAsync(game, _state.Token)).First(); await Add(source, game); }
    }
#endif
    public MultiViewPage()
    {
        InitializeComponent(); _state = new(this); _statsHost = RallyUi.Panel(_stats);
        _toolbar.Children.Add(RallyUi.Button("‹ Back", () => App.Window?.Back())); _toolbar.Children.Add(RallyUi.Button("Add Stream", () => _ = AddStream()));
        _toolbar.Children.Add(RallyUi.Button("Add / Remove Stats", () => { if (!_showStats && _tiles.Count >= 4) { _ = RallyUi.Dialog(this, "Multiview", RallyUi.Text("Remove a stream to make room for player stats.", 14)); return; } _showStats = !_showStats; Layout(); if (_showStats) _ = RefreshStats(); }));
        _toolbar.Children.Add(RallyUi.Button("Immersive", () => { _immersive = !_immersive; App.Window?.SetFullscreen(_immersive); Layout(); }));
        var follow = new ToggleSwitch { Header = "Focused Audio", IsOn = App.Data.Settings.FollowFocusedAudio }; follow.Toggled += (_, _) => App.Data.Settings.FollowFocusedAudio = follow.IsOn; _toolbar.Children.Add(follow);
        var root = new Grid { RowSpacing = 12 }; root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var tools = _toolbar.Children.ToArray(); _toolbar.Children.Clear(); RallyUi.Put(root, RallyUi.Flow(tools), 0); RallyUi.Put(root, _streams, 0, 1); _state.Root.Children.Add(root);
        _timer.Tick += (_, _) => { foreach (var tile in _tiles) tile.Session.Tick(); if (_showStats && !_statsLoading && DateTimeOffset.UtcNow - _statsAt > TimeSpan.FromSeconds(40)) _ = RefreshStats(); if (!_redZoneLoading && App.Data.Settings.RedZoneAlertsEnabled && DateTimeOffset.UtcNow - _redZoneAt > TimeSpan.FromSeconds(40)) _ = RefreshRedZone(); }; Loaded += (_, _) => _timer.Start();
        Unloaded += async (_, _) => { _timer.Stop(); foreach (var tile in _tiles.ToArray()) await tile.Session.DisposeAsync(); _tiles.Clear(); if (_immersive) App.Window?.SetFullscreen(false); };
    }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        await App.Playback.SuspendAsync();
        try
        {
            if (e.Parameter is PlaybackRequest selected) await Add(selected.Source, selected.Game);
            else if (e.Parameter is PlayCandidate selectedSource) await Add(selectedSource, null);
            else if (e.Parameter is IptvChannel selectedChannel) await Add(StreamResolver.ChannelCandidates([selectedChannel])[0], null);
            else if (e.Parameter is SportEvent ev) { var candidates = await App.Data.SourcesAsync(ev, _state.Token); _state.Token.ThrowIfCancellationRequested(); if (candidates.FirstOrDefault() is PlayCandidate source) await Add(source, ev); }
            if (!_state.Token.IsCancellationRequested) Layout();
        }
        catch (OperationCanceledException) { }
        catch { if (!_state.Token.IsCancellationRequested) Layout(); }
    }
    private async Task AddStream()
    {
        if (_adding) return;
        if (_tiles.Count + (_showStats ? 1 : 0) >= 4) { await RallyUi.Dialog(this, "Multiview", RallyUi.Text("Remove a tile before adding another. Multiview supports four tiles including stats.", 14)); return; }
        _adding = true;
        try
        {
            var games = (await App.Data.GamesAsync(ct: _state.Token)).Where(g => g.Status is EventStatus.Live or EventStatus.Halftime).ToList();
            List<IptvChannel> channels; try { channels = await App.Data.ChannelsAsync(ct: _state.Token); } catch { channels = []; }
            var choices = games.Select(g => (Name: RallyUi.Matchup(g), Item: (object)g)).Concat(channels.Select(c => (Name: c.Name, Item: (object)c))).ToList();
            var list = new ListView { ItemsSource = choices.Select(c => c.Name).ToList(), SelectionMode = ListViewSelectionMode.Single, MaxHeight = 380, MinWidth = 0 };
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Add a game or channel", Content = list, PrimaryButtonText = "Choose", CloseButtonText = "Cancel", RequestedTheme = ElementTheme.Dark };
            if (await RallyUi.ShowDialog(dialog) != ContentDialogResult.Primary || list.SelectedIndex < 0) return;
            var choice = choices[list.SelectedIndex].Item;
            if (choice is IptvChannel channel) await Add(StreamResolver.ChannelCandidates([channel])[0], null);
            else if (choice is SportEvent game)
            {
                var sources = await App.Data.SourcesAsync(game, _state.Token);
                if (sources.Count == 0) { await RallyUi.Dialog(this, "No sources found", RallyUi.Text("Check your addon or provider settings for this game.", 14)); return; }
                var sourceList = new ListView { ItemsSource = sources.Select(s => s.Title).ToList(), SelectedIndex = 0, MaxHeight = 340, MinWidth = 0 };
                var picker = new ContentDialog { XamlRoot = XamlRoot, Title = "Choose Source", Content = sourceList, PrimaryButtonText = "Add Stream", CloseButtonText = "Cancel", RequestedTheme = ElementTheme.Dark };
                if (await RallyUi.ShowDialog(picker) == ContentDialogResult.Primary && sourceList.SelectedIndex >= 0) await Add(sources[sourceList.SelectedIndex], game);
            }
        }
        catch (OperationCanceledException) { }
        catch { if (!_state.Token.IsCancellationRequested) await RallyUi.Dialog(this, "Couldn't load sources", RallyUi.Text("Check your connection and try again.", 14)); }
        finally { _adding = false; }
    }
    private async Task Add(PlayCandidate source, SportEvent? game)
    {
        var token = _state.Token; token.ThrowIfCancellationRequested(); if (_tiles.Count + (_showStats ? 1 : 0) >= 4) return;
        var session = new PlaybackSession(App.Data); var surface = new Grid(); surface.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); surface.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var video = new VideoSurface(session); RallyUi.Put(surface, video, 0);
        var footer = RallyUi.Columns(6, 8); footer.ColumnDefinitions[0].Width = new GridLength(1, GridUnitType.Star); for (var col = 1; col < 6; col++) footer.ColumnDefinitions[col].Width = GridLength.Auto;
        var title = RallyUi.Text(game is null ? source.Title : RallyUi.Matchup(game), 12, false, true); title.MaxLines = 1; title.TextWrapping = TextWrapping.NoWrap; RallyUi.Put(footer, title, 0);
        var actions = new[] { RallyUi.Button("Audio", () => RouteAudio(_tiles.FindIndex(t => t.Session == session))), RallyUi.Button("Pause", () => session.TogglePause()), RallyUi.Button("Source", () => _ = PickSource(session)), RallyUi.Button("Retry", () => _ = session.RetryAsync()), RallyUi.Button("Remove", async () => { var tile = _tiles.FirstOrDefault(t => t.Session == session); if (tile is null) return; var listening = _tiles.ElementAtOrDefault(_audio)?.Session; _tiles.Remove(tile); await session.DisposeAsync(); _audio = Math.Max(0, _tiles.FindIndex(t => t.Session == listening)); Layout(); RouteAudio(_audio); if (_showStats) await RefreshStats(); }) }; for (var col = 0; col < actions.Length; col++) RallyUi.Put(footer, actions[col], col + 1);
        session.Changed += () => { RouteAudio(_audio); actions[1].Content = session.IsPlaying ? "Pause" : "Play"; };
        foreach (var button in footer.Children.OfType<Button>()) { button.FontSize = 10; button.Padding = new Thickness(8, 6, 8, 6); button.MinHeight = 28; }
        footer.SizeChanged += (_, e) =>
        {
            var compact = e.NewSize.Width < 620;
            footer.RowDefinitions.Clear(); footer.RowDefinitions.Add(new() { Height = GridLength.Auto }); if (compact) footer.RowDefinitions.Add(new() { Height = GridLength.Auto });
            Grid.SetColumnSpan(title, compact ? 6 : 1);
            for (var i = 0; i < actions.Length; i++) { Grid.SetRow(actions[i], compact ? 1 : 0); Grid.SetColumn(actions[i], compact ? i : i + 1); }
            for (var i = 0; i < footer.ColumnDefinitions.Count; i++) footer.ColumnDefinitions[i].Width = compact ? new GridLength(1, GridUnitType.Star) : i == 0 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
        };
        surface.GotFocus += (_, _) => { if (App.Data.Settings.FollowFocusedAudio) RouteAudio(_tiles.FindIndex(t => t.Session == session)); };
        RallyUi.Put(surface, footer, 0, 1); _tiles.Add(new(session, game, source.Title, surface)); Layout(); RouteAudio(_audio);
        await session.OpenAsync(game is null ? source : new PlaybackRequest(game, source), token); if (token.IsCancellationRequested) return; RouteAudio(_audio); if (_showStats) await RefreshStats();
    }
    private async Task PickSource(PlaybackSession session)
    {
        var token = _state.Token;
        try
        {
            var candidates = session.Event is { } game ? await App.Data.SourcesAsync(game, token, refresh: true) : session.Candidates;
            token.ThrowIfCancellationRequested();
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Pick Source", CloseButtonText = "Cancel", RequestedTheme = ElementTheme.Dark };
            dialog.Content = new ScrollViewer { MaxHeight = 420, MinWidth = 0,
                Content = GamePanels.Sources(candidates, candidate => { dialog.Hide(); _ = session.PlayAsync(candidate, token); }) };
            await RallyUi.ShowDialog(dialog);
        }
        catch (OperationCanceledException) { }
        catch { if (!token.IsCancellationRequested) await RallyUi.Dialog(this, "Couldn't load sources", RallyUi.Text("Try again or retry the current stream.", 13, true)); }
    }
    private void RouteAudio(int index)
    {
        _audio = _tiles.Count == 0 ? 0 : Math.Clamp(index, 0, _tiles.Count - 1);
        for (var i = 0; i < _tiles.Count; i++)
        {
            var tile = _tiles[i]; tile.Session.SetMuted(i != _audio);
            var audio = ((Grid)tile.Surface.Children[1]).Children.OfType<Button>().First();
            audio.Content = i == _audio ? "Audio On" : "Audio"; audio.Background = i == _audio ? RallyUi.White : RallyUi.Surface;
            audio.Foreground = i == _audio ? new Microsoft.UI.Xaml.Media.SolidColorBrush(RallyUi.Ink) : RallyUi.White;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(audio, "Listen to " + (tile.Game is null ? tile.Name : RallyUi.Matchup(tile.Game)));
        }
    }
    private void Layout()
    {
        _streams.Children.Clear(); _streams.ColumnDefinitions.Clear(); _streams.RowDefinitions.Clear();
        var count = _tiles.Count + (_showStats ? 1 : 0); var columns = count > 1 ? 2 : 1; var rows = count > 2 ? 2 : 1;
        for (int i = 0; i < columns; i++) _streams.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (int i = 0; i < rows; i++) _streams.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < _tiles.Count; i++) RallyUi.Put(_streams, _tiles[i].Surface, i % columns, i / columns);
        if (_showStats) RallyUi.Put(_streams, _statsHost, _tiles.Count % columns, _tiles.Count / columns);
        if (count == 0) _streams.Children.Add(RallyUi.Empty("Build your multiview", "Watch up to four streams, or replace a stream with live player stats.", "Add Stream", () => _ = AddStream()));
        _streams.ColumnSpacing = _streams.RowSpacing = _immersive ? 2 : 8; _state.Root.Padding = new Thickness(_immersive ? 10 : 32);
    }
    private async Task RefreshStats()
    {
        var generation = ++_statsGeneration;
        var token = _state.Token;
        _statsLoading = true; _statsAt = DateTimeOffset.UtcNow; if (_stats.Content is null) _stats.Content = RallyUi.Text("Loading player stats…", 13, true);
        try
        {
            var redzone = _tiles.Any(t => t.Name.Contains("redzone", StringComparison.OrdinalIgnoreCase) || t.Name.Contains("red zone", StringComparison.OrdinalIgnoreCase));
            var selected = _tiles.Select(t => t.Game).OfType<SportEvent>().ToArray();
            var games = GamePlayers.MultiViewGames(selected, await App.Data.GamesAsync(ct: token), redzone, DateTimeOffset.Now);
            var body = RallyUi.Column(RallyUi.Text("Multiview Player Stats", 17, false, true));
            foreach (var game in games) { var detail = await App.Data.DetailAsync(game, ct: token); if (token.IsCancellationRequested || generation != _statsGeneration) return; var expander = new Expander { Header = RallyUi.Matchup(game), IsExpanded = games.Count <= 2, Content = GamePanels.Players(detail), HorizontalAlignment = HorizontalAlignment.Stretch }; body.Children.Add(expander); }
            if (games.Count == 0) body.Children.Add(RallyUi.Text("Add a game to view its players. RedZone includes all of today’s NFL games.", 13, true));
            if (!token.IsCancellationRequested && generation == _statsGeneration) _stats.Content = RallyUi.Scroll(body);
        }
        catch (OperationCanceledException) { }
        catch { if (!token.IsCancellationRequested && generation == _statsGeneration) _stats.Content = RallyUi.Text("Player stats couldn't load. Try again.", 13, true); }
        finally { if (generation == _statsGeneration) _statsLoading = false; }
    }
    private async Task RefreshRedZone()
    {
        if (!_tiles.Any(t => t.Name.Contains("redzone", StringComparison.OrdinalIgnoreCase) || t.Name.Contains("red zone", StringComparison.OrdinalIgnoreCase))) { _redZoneSeeded = false; _redZonePlays.Clear(); return; }
        _redZoneLoading = true; _redZoneAt = DateTimeOffset.UtcNow;
        try
        {
            var games = GamePlayers.MultiViewGames([], await App.Data.GamesAsync(ct: _state.Token), true, DateTimeOffset.Now);
            foreach (var game in games)
            {
                var detail = await App.Data.DetailAsync(game, ct: _state.Token);
                foreach (var play in detail.Plays.Where(p => p.Scoring && (p.Text.Contains("touchdown", StringComparison.OrdinalIgnoreCase) || p.Text.Contains(" TD", StringComparison.OrdinalIgnoreCase))))
                    if (_redZonePlays.Add($"{game.League}:{game.Id}:{play.Id}") && _redZoneSeeded)
                        App.Notifications.NotifyRedZoneTouchdown($"{RallyUi.Matchup(game)} · {play.Text}");
            }
            _redZoneSeeded = true;
        }
        catch (OperationCanceledException) { } catch { }
        finally { _redZoneLoading = false; }
    }
}
