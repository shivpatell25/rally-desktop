using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Services;

namespace Rally.App.Design;
public sealed class PlaybackSeekBar : Grid
{
    private readonly PlaybackSession _session;
    private readonly Slider _seek = new() { Minimum = 0, Maximum = 1, SmallChange = 10_000, LargeChange = 30_000, IsThumbToolTipEnabled = false };
    private readonly TextBlock _label = RallyUi.Text("", 11, true);
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _updating, _dragging;
    public PlaybackSeekBar(PlaybackSession session)
    {
        _session = session; RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto });
        RallyUi.Put(this, _label, 0); RallyUi.Put(this, _seek, 0, 1);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_seek, "Playback position");
        _seek.ValueChanged += (_, e) => { if (!_updating && _seek.FocusState == FocusState.Keyboard) session.Seek((long)e.NewValue); };
        _seek.PointerPressed += (_, _) => _dragging = true;
        _seek.PointerCaptureLost += (_, _) => { if (_dragging) session.Seek((long)_seek.Value); _dragging = false; };
        _timer.Tick += (_, _) => Update(); Loaded += (_, _) => { session.Changed += Update; _timer.Start(); Update(); }; Unloaded += (_, _) => { session.Changed -= Update; _timer.Stop(); };
    }
    private static string Time(long value) => TimeSpan.FromMilliseconds(Math.Max(0, value)).ToString(value >= 3_600_000 ? @"h\:mm\:ss" : @"m\:ss");
    private void Update()
    {
        var timeline = _session.Timeline; _seek.IsEnabled = timeline.CanSeek; _updating = true;
        try { _seek.Maximum = Math.Max(1, timeline.Duration); if (!_dragging && _seek.FocusState != FocusState.Keyboard) _seek.Value = timeline.Position; } finally { _updating = false; }
        _label.Text = timeline.IsLive ? timeline.AtLiveEdge ? "LIVE · At live edge" : $"LIVE · {Time(timeline.Duration - timeline.Position)} behind · Jump to Live to catch up"
            : timeline.Duration > 0 ? $"{Time(timeline.Position)} / {Time(timeline.Duration)}" : _session.Loading ? "Connecting…" : _session.Status;
        if (timeline.IsLive && !timeline.CanSeek) _label.Text += " · Rewind is not available";
        _label.MaxLines = 2;
    }
}
