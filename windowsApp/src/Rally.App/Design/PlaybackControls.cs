using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Services;

namespace Rally.App.Design;

public sealed class PlaybackControls : Grid
{
    private readonly PlaybackSession _session;
    private readonly List<Button> _buttons = [];
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private int _layoutMask = -1, _layoutColumns;
    public PlaybackControls(PlaybackSession session, bool fullscreen)
    {
        _session = session; ColumnSpacing = RowSpacing = 6;
        var actions = new (string Label, Action Run)[]
        {
            ("Pause", () => session.TogglePause()),
            (fullscreen ? "Game View" : "Fullscreen", () => {
                if (fullscreen) { App.Window?.SetCompactOverlay(false); App.Window?.SetFullscreen(false); if (session.Event is not null) PageState.Go(typeof(Views.GameViewPage), session.Event); else App.Window?.Back(); }
                else { PageState.Go(typeof(Views.PlayerPage), session.Event is not null ? session.Event : session.Current); App.Window?.SetFullscreen(true); }
            }),
            ("Watch from Start", () => session.Restart()), ("Jump to Live", () => session.GoLive()),
            ("Quality", () => _ = Quality()), ("Audio", () => _ = Tracks(false)),
            ("Captions", () => _ = Tracks(true)), ("Pick Source", () => _ = Sources()),
            ("Multiview", () => PageState.Go(typeof(Views.MultiViewPage), session.Current is { } current ? session.Event is { } game ? new PlaybackRequest(game, current) : (object)current : session.Event)),
            ("Picture-in-Picture", () => { if (!fullscreen) PageState.Go(typeof(Views.PlayerPage), session.Event is not null ? session.Event : session.Current); App.Window?.SetCompactOverlay(App.Window?.IsCompactOverlay != true); })
        };
        foreach (var action in actions)
        {
            var button = RallyUi.Button(action.Label, action.Run, _buttons.Count == 0); button.FontSize = 11; button.Padding = new Thickness(6, 8, 6, 8); button.MinHeight = 34; button.HorizontalAlignment = HorizontalAlignment.Stretch;
            _buttons.Add(button); Children.Add(button);
        }
        ToolTipService.SetToolTip(_buttons[2], "Starts at the earliest position published by this source. Live rewind is available only when the provider supplies it.");
        _timer.Tick += (_, _) => Update(); SizeChanged += (_, _) => Update(); Loaded += (_, _) => { session.Changed += Update; _timer.Start(); Update(); Layout(); }; Unloaded += (_, _) => { session.Changed -= Update; _timer.Stop(); };
    }
    private void Layout()
    {
        var compact = App.Window?.IsCompactOverlay == true;
        _buttons[1].Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        var visible = _buttons.Where(b => b.Visibility == Visibility.Visible).ToList();
        var columns = compact ? 2 : ActualWidth < 500 ? 3 : ActualWidth < 780 ? 4 : 5;
        var mask = _buttons.Select((b, i) => b.Visibility == Visibility.Visible ? 1 << i : 0).Sum();
        if (_layoutColumns == columns && _layoutMask == mask) return; _layoutColumns = columns; _layoutMask = mask;
        ColumnDefinitions.Clear(); RowDefinitions.Clear();
        for (var i = 0; i < columns; i++) ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < visible.Count; i++) { if (i % columns == 0) RowDefinitions.Add(new() { Height = GridLength.Auto }); Grid.SetColumn(visible[i], i % columns); Grid.SetRow(visible[i], i / columns); }
    }
    private void Update()
    {
        _buttons[0].Content = _session.IsPlaying ? "Pause" : "Play"; _buttons[0].IsEnabled = !_session.Loading && _session.Player is not null;
        _buttons[2].IsEnabled = _session.Timeline.CanSeek; _buttons[3].Visibility = _session.IsLive ? Visibility.Visible : Visibility.Collapsed;
        _buttons[3].IsEnabled = _session.Timeline.CanSeek && !_session.Timeline.AtLiveEdge;
        _buttons[4].Content = $"Quality · {_session.QualityLabel}";
        _buttons[4].IsEnabled = !_session.Loading; _buttons[5].IsEnabled = _buttons[6].IsEnabled = !_session.Loading && _session.Player is not null;
        var compact = App.Window?.IsCompactOverlay == true;
        _buttons[9].Content = compact ? "Return to Window" : "Picture-in-Picture";
        foreach (var index in new[] { 2, 4, 5, 6, 7, 8 }) _buttons[index].Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        Layout();
    }
    private async Task Quality()
    {
        var panel = new StackPanel { Spacing = 10 }; var dialog = NewDialog("Quality");
        void Choice(string label, int height) { panel.Children.Add(RallyUi.Button((_session.QualityLabel == label ? "✓ " : "") + label, () => { dialog.Hide(); _ = _session.SelectQualityAsync(height); })); }
        Choice("Auto", 0); foreach (var quality in _session.Qualities) Choice($"{quality.Height}p", quality.Height);
        if (_session.Qualities.Count == 0) panel.Children.Add(RallyUi.Text("This source does not publish selectable video qualities. Choose another source for a different quality.", 13, true));
        dialog.Content = panel; await RallyUi.ShowDialog(dialog);
    }
    private ContentDialog NewDialog(string title) => new() { XamlRoot = XamlRoot, Title = title, CloseButtonText = "Done", RequestedTheme = ElementTheme.Dark };
    private async Task Tracks(bool captions)
    {
        var panel = new StackPanel { Spacing = 10 }; var player = _session.Player; var dialog = NewDialog(captions ? "Captions" : "Audio");
        var selected = captions ? player?.Spu : player?.AudioTrack;
        var tracks = _session.Loading ? null : captions ? player?.SpuDescription : player?.AudioTrackDescription;
        if (tracks is not null) foreach (var track in tracks) { var id = track.Id; var name = track.Name; panel.Children.Add(RallyUi.Button((selected == id ? "✓ " : "") + name, () => { _session.SelectTrack(captions, id, name); dialog.Hide(); })); }
        if (panel.Children.Count == 0) panel.Children.Add(RallyUi.Text(captions ? "This source has no caption tracks." : "This source has no alternate audio tracks.", 13, true));
        if (!captions)
        {
            var volume = new Slider { Minimum = 0, Maximum = 100, Value = player?.Volume ?? 100, Width = 250 }; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(volume, "Volume");
            volume.ValueChanged += (_, e) => { if (_session.Player is not null) _session.Player.Volume = (int)e.NewValue; };
            var mute = new ToggleSwitch { Header = "Mute", IsOn = player?.Mute == true }; mute.Toggled += (_, _) => _session.SetMuted(mute.IsOn);
            panel.Children.Add(RallyUi.Text("Volume", 13)); panel.Children.Add(volume); panel.Children.Add(mute);
        }
        dialog.Content = panel; await RallyUi.ShowDialog(dialog);
    }
    public Task Sources() => ShowSources(this, _session);
    public static async Task ShowSources(FrameworkElement owner, PlaybackSession session)
    {
        try
        {
            await session.RefreshSourcesAsync(); if (owner.XamlRoot is null) return;
            var dialog = new ContentDialog { XamlRoot = owner.XamlRoot, Title = "Pick Source", CloseButtonText = "Done", RequestedTheme = ElementTheme.Dark };
            dialog.Content = new ScrollViewer { MaxHeight = 420, Content = RallyUi.Column(GamePanels.Sources(session.Candidates, candidate => { dialog.Hide(); _ = session.PlayAsync(candidate, renew: true); }), RallyUi.Button("Retry current source", () => { dialog.Hide(); _ = session.RetryAsync(); })) };
            await RallyUi.ShowDialog(dialog);
        }
        catch { if (owner.XamlRoot is not null) await RallyUi.Dialog(owner, "Sources unavailable", RallyUi.Text("Check your connection and retry playback, or open Sources in Settings.", 13, true)); }
    }
}
