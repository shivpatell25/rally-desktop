using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Services;

namespace Rally.App.Design;

public sealed class PlaybackControls : Grid
{
    private readonly PlaybackSession _session;
    public PlaybackControls(PlaybackSession session, bool fullscreen)
    {
        _session = session; ColumnSpacing = 8;
        var labels = new[] { "Pause", fullscreen ? "Game View" : "Fullscreen", "Restart", "Multiview", "Audio", "Captions", "Source" };
        var actions = new Action[] { () => session.TogglePause(), () => { if (fullscreen) { App.Window?.SetFullscreen(false); if (session.Event is not null) PageState.Go(typeof(Views.GameViewPage), session.Event); else App.Window?.Back(); } else { PageState.Go(typeof(Views.PlayerPage), session.Event is not null ? session.Event : session.Current); App.Window?.SetFullscreen(true); } },
            () => session.Restart(), () => PageState.Go(typeof(Views.MultiViewPage), session.Current is { } current ? session.Event is { } game ? new PlaybackRequest(game, current) : (object)current : session.Event), () => _ = Tracks(false), () => _ = Tracks(true), () => _ = Sources() };
        for (var i = 0; i < labels.Length; i++)
        {
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var button = RallyUi.Button(labels[i], actions[i], i == 0); button.Padding = new Thickness(6, 10, 6, 10); button.FontSize = 11; button.HorizontalAlignment = HorizontalAlignment.Stretch;
            RallyUi.Put(this, button, i);
        }
        var pause = (Button)Children[0]; Action changed = () => pause.Content = session.IsPlaying ? "Pause" : "Play";
        Loaded += (_, _) => { session.Changed += changed; changed(); }; Unloaded += (_, _) => session.Changed -= changed;
    }
    private async Task Tracks(bool subtitles)
    {
        var panel = new StackPanel { Spacing = 10 }; var tracks = _session.Loading ? null : subtitles ? _session.Player?.SpuDescription : _session.Player?.AudioTrackDescription;
        if (tracks is not null) foreach (var track in tracks)
        {
            var id = track.Id; panel.Children.Add(RallyUi.Button(track.Name, () => { if (subtitles) _session.Player?.SetSpu(id); else _session.Player?.SetAudioTrack(id); }));
        }
        if (panel.Children.Count == 0) panel.Children.Add(RallyUi.Text(subtitles ? "This source has no caption tracks." : "Audio tracks will appear when playback starts.", 13, true));
        if (!subtitles)
        {
            var volume = new Slider { Minimum = 0, Maximum = 100, Value = _session.Loading ? 100 : _session.Player?.Volume ?? 100, Width = 250 };
            volume.ValueChanged += (_, e) => { if (_session.Player is not null) _session.Player.Volume = (int)e.NewValue; }; panel.Children.Add(RallyUi.Text("Volume", 13)); panel.Children.Add(volume);
        }
        await RallyUi.Dialog(this, subtitles ? "Captions" : "Audio", panel);
    }
    private async Task Sources()
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Pick Source", CloseButtonText = "Cancel", RequestedTheme = ElementTheme.Dark };
        var content = RallyUi.Column(GamePanels.Sources(_session.Candidates, candidate => { dialog.Hide(); _ = _session.PlayAsync(candidate, renew: true); }), RallyUi.Button("Retry current source", () => { dialog.Hide(); _ = _session.RetryAsync(); }));
        dialog.Content = new ScrollViewer { Content = content, MaxHeight = 420, MinWidth = 360 }; await dialog.ShowAsync();
    }
}
