using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Services;

namespace Rally.App.Design;

// VideoViews stay loaded in the window, preserving their Direct3D swapchains
// when navigation or multiview layout moves a playback anchor.
public sealed class VideoSurface : Grid
{
    private readonly PlaybackSession _session;
    private readonly ProgressRing _loading = new() { IsActive = false, Width = 32, Height = 32 };
    private readonly StackPanel _failure = new() { Spacing = 10 };
    private readonly TextBlock _message = RallyUi.Text("", 12, true);
    public VideoSurface(PlaybackSession session)
    {
        _session = session;
        Children.Add(_loading); _message.HorizontalAlignment = HorizontalAlignment.Center; _message.VerticalAlignment = VerticalAlignment.Bottom; _message.Margin = new Thickness(18); Children.Add(_message);
        var retry = RallyUi.Button("Retry", () => _ = session.RetryAsync());
        var sources = RallyUi.Button("Pick Source", () => _ = PlaybackControls.ShowSources(this, session));
        _failure.Children.Add(RallyUi.Flow(retry, sources, RallyUi.Button("Source Settings", () => App.Window?.NavigateTo("settings"))));
        _failure.HorizontalAlignment = HorizontalAlignment.Center; _failure.VerticalAlignment = VerticalAlignment.Center; Children.Add(_failure);
        Loaded += (_, _) => { App.Window?.AttachVideo(_session, this); _session.Changed += Update; Update(); };
        Unloaded += (_, _) => { _session.Changed -= Update; App.Window?.DetachVideo(_session, this); };
    }
    private void Update() { _loading.IsActive = _session.Loading; _message.Text = _session.IsPlaying ? "" : _session.Status; _failure.Visibility = !_session.Loading && !_session.IsPlaying && _session.Player?.State != LibVLCSharp.Shared.VLCState.Paused ? Visibility.Visible : Visibility.Collapsed; }
}
