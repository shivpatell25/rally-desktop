using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;

namespace Rally.App.Views;

public sealed partial class GameViewPage : Page
{
    private readonly PageState _state;
    private SportEvent? _event;
    private GameDetail _detail = GameDetail.Empty;
    private readonly ContentControl _panel = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Top };
    private readonly Grid _moments = RallyUi.Columns(4, 10);
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private DateTimeOffset _lastRefresh;
    private bool _refreshing, _other;
    private int _sourceCount;
    private int _momentsGeneration;
    private readonly ContentControl _score = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Dictionary<string, Button> _tabs = [];
    private string _selected = "Stats";
    public GameViewPage()
    {
        InitializeComponent(); _state = new(this);
        _timer.Tick += (_, _) => { App.Playback.Tick(); if (!_refreshing && DateTimeOffset.UtcNow - _lastRefresh > TimeSpan.FromSeconds(40)) _ = RefreshGame(); }; Loaded += (_, _) => { _timer.Start(); App.Playback.Changed += SourcesReady; }; Unloaded += (_, _) => { _timer.Stop(); App.Playback.Changed -= SourcesReady; };
    }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        _event = e.Parameter is Services.PlaybackRequest requested ? requested.Game : e.Parameter as SportEvent ?? App.Playback.Event;
        if (_event is null) { App.Window?.NavigateTo("home"); return; }
        Build(); _lastRefresh = DateTimeOffset.UtcNow;
        var play = App.Playback.OpenAsync(e.Parameter is Services.PlaybackRequest ? e.Parameter : _event, _state.Token);
        try { _detail = await App.Data.DetailAsync(_event, ct: _state.Token); RenderPanel(); RenderMoments(false); await play; }
        catch (OperationCanceledException) { }
        catch { if (!_state.Token.IsCancellationRequested) { _detail = GameDetail.Empty; RenderPanel(); RenderMoments(false); } await play; }
    }
    private void SourcesReady() { if (_selected == "Sources" && _sourceCount != App.Playback.Candidates.Count) { _sourceCount = App.Playback.Candidates.Count; RenderPanel(); } }
    private async Task RefreshGame()
    {
        if (_event is null || _state.Token.IsCancellationRequested) return;
        _refreshing = true; _lastRefresh = DateTimeOffset.UtcNow;
        try { var games = await App.Data.GamesAsync(ct: _state.Token); var latest = games.FirstOrDefault(g => g.Id == _event.Id && g.League == _event.League); if (latest is not null) _event = latest; var detail = await App.Data.DetailAsync(_event, ct: _state.Token); if (_state.Token.IsCancellationRequested) return; _detail = detail; _score.Content = GamePanels.ScoreBug(_event); RenderPanel(); RenderMoments(_other); }
        catch (OperationCanceledException) { } catch { } finally { _refreshing = false; }
    }
    private void Build()
    {
        _state.Root.Children.Clear();
        var root = RallyUi.Columns(2, 20); root.ColumnDefinitions[0].Width = new GridLength(2.12, GridUnitType.Star);
        var left = new Grid { RowSpacing = 10 }; foreach (var _ in Enumerable.Range(0, 4)) left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _score.Content = GamePanels.ScoreBug(_event!); RallyUi.Put(left, _score, 0, 0);
        var video = new VideoSurface(App.Playback);
        var playerTarget = new Button { Content = video, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var key in new[] { "ButtonBackgroundPointerOver", "ButtonBackgroundPressed", "ButtonBackground" }) playerTarget.Resources[key] = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(playerTarget, "Video player — pause or resume"); playerTarget.Click += (_, _) => App.Playback.TogglePause(); RallyUi.Put(left, playerTarget, 0, 1);
        left.SizeChanged += (_, args) => { var available = Math.Max(160, _state.Root.ActualHeight - 310); video.Height = Math.Min(args.NewSize.Width * 9 / 16, available); };
        RallyUi.Put(left, new PlaybackControls(App.Playback, false), 0, 2);
        var toggles = RallyUi.Row(RallyUi.Button("Key Moments", () => RenderMoments(false)), RallyUi.Button("Other Live Games", () => RenderMoments(true)));
        var momentsSection = RallyUi.Column(toggles, _moments); momentsSection.Spacing = 10; RallyUi.Put(left, momentsSection, 0, 3); RallyUi.Put(root, left, 0);
        var right = new Grid { RowSpacing = 14 }; right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid(); header.Children.Add(RallyUi.Button("‹ Back", () => App.Window?.Back())); var mark = RallyUi.Asset("rally_mark_ui.png", 32, 32); mark.HorizontalAlignment = HorizontalAlignment.Right; header.Children.Add(mark);
        var nav = RallyUi.Columns(4, 4); _tabs.Clear(); var index = 0;
        foreach (var title in new[] { "Stats", "Plays", "Players", "Sources" }) { var button = RallyUi.Button(title, () => { _selected = title; RenderPanel(); }); button.FontSize = 11; button.Padding = new Thickness(6, 8, 6, 8); _tabs[title] = button; RallyUi.Put(nav, button, index++); }
        RallyUi.Put(right, RallyUi.Column(header, nav), 0); RallyUi.Put(right, RallyUi.Panel(_panel), 0, 1);
        RallyUi.Put(root, right, 1); _state.Root.Children.Add(root); RenderPanel();
    }
    private void RenderPanel()
    {
        if (_event is null || _state.Token.IsCancellationRequested) return;
        foreach (var tab in _tabs) tab.Value.Background = tab.Key == _selected ? new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(38, 225, 234, 242)) : RallyUi.Surface;
        _panel.Content = _selected switch { "Stats" => GamePanels.Stats(_event, _detail), "Plays" => RallyUi.Scroll(GamePanels.Plays(_detail.Plays)), "Players" => RallyUi.Scroll(GamePanels.Players(_detail)), _ => RallyUi.Scroll(GamePanels.Sources(App.Playback.Candidates, c => _ = App.Playback.PlayAsync(c, renew: true))) };
    }
    private async void RenderMoments(bool other)
    {
        var generation = ++_momentsGeneration;
        var token = _state.Token;
        if (token.IsCancellationRequested) return;
        _other = other; _moments.Children.Clear();
        if (other)
        {
            try
            {
                var games = await App.Data.GamesAsync(ct: token);
                if (token.IsCancellationRequested || generation != _momentsGeneration) return;
                foreach (var game in games.Where(ev => ev.Status is EventStatus.Live or EventStatus.Halftime).Where(ev => ev.Id != _event?.Id || ev.League != _event?.League).Take(4)) { var button = RallyUi.EventCard(game, () => PageState.Watch(game)); RallyUi.Put(_moments, button, _moments.Children.Count); }
            }
            catch (OperationCanceledException) { }
            catch { if (!token.IsCancellationRequested && generation == _momentsGeneration) _moments.Children.Add(RallyUi.Text("Live games couldn't load. Try again.", 12, true)); }
            return;
        }
        var clipIndex = 0; foreach (var clip in _detail.Clips.Take(4)) { var card = HomePage.ClipCard(clip, true); RallyUi.Put(_moments, card, clipIndex++); }
        if (_detail.Clips.Count == 0) foreach (var play in _detail.KeyMoments.Take(4))
        {
            var text = RallyUi.Text(play.Text, 11); text.MaxLines = 3; text.MaxWidth = 180;
            RallyUi.Put(_moments, RallyUi.Panel(RallyUi.Column(RallyUi.Text($"{play.Clock} · Scoring play", 10, true), text), new Thickness(10)), _moments.Children.Count);
        }
        if (_moments.Children.Count == 0) _moments.Children.Add(RallyUi.Text("Key moments will appear when available.", 12, true));
    }
}
