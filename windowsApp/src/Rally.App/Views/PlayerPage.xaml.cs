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
    private CancellationTokenSource _cancel = new();
    public PlayerPage()
    {
        InitializeComponent(); Content = _root; _root.Children.Add(new VideoSurface(App.Playback));
        var controls = new PlaybackControls(App.Playback, true);
        var diagnostics = RallyUi.Button("Stream Information", () => _ = RallyUi.Dialog(this, "Stream Information", RallyUi.Text(App.Playback.Diagnostics(), 13)));
        var seek = new PlaybackSeekBar(App.Playback);
        _overlay.Child = RallyUi.Column(diagnostics, seek, controls); _overlay.Background = RallyUi.Surface; _overlay.Padding = new Thickness(18); _overlay.VerticalAlignment = VerticalAlignment.Bottom; _overlay.Margin = new Thickness(24); _root.Children.Add(_overlay);
        SizeChanged += (_, _) => { var compact = App.Window?.IsCompactOverlay == true; diagnostics.Visibility = ActualWidth < 600 ? Visibility.Collapsed : Visibility.Visible; seek.Visibility = compact ? Visibility.Collapsed : Visibility.Visible; _overlay.Padding = new Thickness(compact ? 8 : 18); _overlay.Margin = new Thickness(compact ? 8 : 24); };
        PointerMoved += (_, _) => Wake(); PointerPressed += (_, _) => Wake(); KeyDown += (_, _) => Wake();
        _timer.Tick += (_, _) => { App.Playback.Tick(); if (DateTimeOffset.UtcNow - _input > TimeSpan.FromSeconds(5) && App.Playback.IsPlaying && !(Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(XamlRoot) is Control focused && focused.FocusState == FocusState.Keyboard)) _overlay.Visibility = Visibility.Collapsed; };
        Loaded += (_, _) => _timer.Start(); Unloaded += (_, _) => { _timer.Stop(); _cancel.Cancel(); };
    }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (_cancel.IsCancellationRequested) { _cancel.Dispose(); _cancel = new(); }
        Wake(); await App.Playback.OpenAsync(e.Parameter, _cancel.Token);
    }
    private void Wake() { _input = DateTimeOffset.UtcNow; _overlay.Visibility = Visibility.Visible; }
}
