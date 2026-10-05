using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;

namespace Rally.App.Views;

public sealed partial class PlayerPage : Page
{
    private readonly Grid _root = new();
    private readonly Border _overlay = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private DateTimeOffset _input = DateTimeOffset.UtcNow;
    public PlayerPage()
    {
        InitializeComponent(); Content = _root;
        _root.Children.Add(new VideoSurface(App.Playback));
        var controls = new PlaybackControls(App.Playback, true);
        var diagnostics = RallyUi.Button("Diagnostics", () => _ = RallyUi.Dialog(this, "Stream Information", RallyUi.Text(App.Playback.Diagnostics(), 13)));
        var retry = RallyUi.Button("Retry", () => _ = App.Playback.RetryAsync());
        var seek = new Slider { Minimum = 0, Maximum = 1, Value = 0, SmallChange = 5_000, LargeChange = 30_000 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(seek, "Playback position");
        var updatingPosition = false;
        seek.ValueChanged += (_, args) =>
        {
            if (!updatingPosition && seek.FocusState == FocusState.Keyboard) App.Playback.Seek((long)args.NewValue);
        };
        seek.PointerCaptureLost += (_, _) => App.Playback.Seek((long)seek.Value);
        var head = new Grid(); var mark = RallyUi.Asset("rally_mark_ui.png", 36, 36); mark.HorizontalAlignment = HorizontalAlignment.Right; head.Children.Add(mark); var extras = RallyUi.Row(diagnostics, retry); extras.HorizontalAlignment = HorizontalAlignment.Left; head.Children.Add(extras);
        _overlay.Child = RallyUi.Column(head, seek, controls); _overlay.Background = RallyUi.Surface; _overlay.Padding = new Thickness(24); _overlay.VerticalAlignment = VerticalAlignment.Bottom; _overlay.Margin = new Thickness(32); _overlay.CornerRadius = new CornerRadius(8);
        _root.Children.Add(_overlay);
        PointerMoved += (_, _) => Wake(); PointerPressed += (_, _) => Wake(); KeyDown += (_, _) => Wake();
        _timer.Tick += (_, _) => { App.Playback.Tick(); var player = App.Playback.Player; seek.IsEnabled = player?.IsSeekable == true; updatingPosition = true;
            try { seek.Maximum = Math.Max(1, player?.Length ?? 1); if (seek.FocusState == FocusState.Unfocused) seek.Value = Math.Max(0, player?.Time ?? 0); }
            finally { updatingPosition = false; } if (DateTimeOffset.UtcNow - _input > TimeSpan.FromSeconds(5) && App.Playback.IsPlaying && !(Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(XamlRoot) is Control focused && focused.FocusState == FocusState.Keyboard)) _overlay.Visibility = Visibility.Collapsed; };
        Loaded += (_, _) => _timer.Start(); Unloaded += (_, _) => _timer.Stop();
    }
    protected override async void OnNavigatedTo(NavigationEventArgs e) { Wake(); await App.Playback.OpenAsync(e.Parameter); }
    private void Wake() { _input = DateTimeOffset.UtcNow; _overlay.Visibility = Visibility.Visible; }
}
