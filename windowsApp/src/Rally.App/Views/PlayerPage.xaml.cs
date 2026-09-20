using LibVLCSharp.Shared;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

public sealed partial class PlayerPage : Page
{
    private LibVLC? _libvlc;
    private MediaPlayer? _player;
    private readonly SettingsStore _settings = new();
    private readonly StremioClient _stremio = new(new HttpClient());
    private SportEvent? _event;
    private List<PlayCandidate> _candidates = [];

    public PlayerPage()
    {
        InitializeComponent();
        Unloaded += (_, _) => { _player?.Stop(); _player?.Dispose(); _libvlc?.Dispose(); };
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        await LoadAsync(e.Parameter as SportEvent);
    }

    private async Task LoadAsync(SportEvent? ev)
    {
        _event = ev;
        if (_event is null) return;
        Core.Initialize();
        _libvlc?.Dispose();
        _player?.Dispose();
        _libvlc = new LibVLC("--no-video-title-show");
        _player = new MediaPlayer(_libvlc);
        Video.MediaPlayer = _player;
        var options = new List<StremioStreamOption>();
        foreach (var addon in _settings.StremioAddonUrls)
        {
            try { options.AddRange(await _stremio.FindStreamsAsync(_event, addon)); }
            catch { /* per-addon failure is not fatal */ }
        }
        _candidates = StreamResolver.Candidates(_event, [], options);
        Sources.ItemsSource = _candidates;
        if (_candidates.FirstOrDefault() is PlayCandidate first) Play(first);
    }

    private void Play(PlayCandidate cand)
    {
        if (_libvlc is null || _player is null) return;
        var media = new Media(_libvlc, cand.Url, FromType.FromLocation);
        foreach (var (k, v) in cand.Headers ?? new Dictionary<string, string>())
        {
            if (k.Equals("user-agent", StringComparison.OrdinalIgnoreCase)) media.AddOption($":http-user-agent={v}");
            if (k.Equals("referer", StringComparison.OrdinalIgnoreCase)) media.AddOption($":http-referrer={v}");
        }
        NowPlaying.Text = cand.Title;
        _player.Play(media);
    }

    private void Sources_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Sources.SelectedItem is PlayCandidate cand) Play(cand);
    }

    private void Pause_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) => _player?.Pause();

    private async void Retry_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) => await LoadAsync(_event);
}
