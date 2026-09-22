using LibVLCSharp.Platforms.Windows;
using LibVLCSharp.Shared;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

// Multicast tile wall: up to 4 concurrent streams in a 2-column grid
// (1 tile spans both columns; 3 tiles: first tile spans, other two below;
// 4 tiles: 2x2). Mirrors Android MultiViewScreen grid caps + macOS
// MultiViewState (max 4, single audio focus, per-tile retry/remove).
public sealed partial class MultiViewPage : Page
{
    private sealed class Tile
    {
        public required string Id { get; init; }
        public required SportEvent Event { get; init; }
        public required MediaPlayer Player { get; init; }
        public required VideoView View { get; init; }
        public required TextBlock TitleBlock { get; init; }
        public required TextBlock StatusBlock { get; init; }
        public required Border Root { get; init; }
        public PlayCandidate? Candidate { get; set; }
        public string? PlayUrl { get; set; }
    }

    private LibVLC? _libvlc;
    private readonly SettingsStore _settings = new();
    private readonly StremioClient _stremio = new(new HttpClient());
    private readonly StalkerClient _stalker;
    private readonly XtreamClient _xtream;
    private List<IptvChannel> _channels = [];
    private readonly List<Tile> _tiles = [];
    private int _audioIndex;
    private bool _disposed;

    public MultiViewPage()
    {
        InitializeComponent();
        _stalker = new StalkerClient(new HttpClient(), _settings);
        _xtream = new XtreamClient(new HttpClient(), _settings);
        Unloaded += (_, _) => DisposeAll();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var events = (e.Parameter as List<SportEvent>)?.Take(4).ToList() ?? [];
        await LoadAsync(events).ConfigureAwait(false);
    }

    private async Task LoadAsync(List<SportEvent> events)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            foreach (var old in _tiles)
            {
                try { old.Player.Stop(); } catch { }
                old.Root.PointerPressed -= Tile_PointerPressed;
                try { old.View.MediaPlayer = null; } catch { }
                try { old.Player.Dispose(); } catch { }
            }
            _tiles.Clear();
            try { LibVLCSharp.Shared.Core.Initialize(); } catch { /* already initialized */ }
            _libvlc?.Dispose();
            _libvlc = new LibVLC("--no-video-title-show");
            // Tile cap note: Android caps ExoPlayer tile tracks at 720p to bound
            // CPU/battery with 4 concurrent decoders. libVLC exposes no per-player
            // resolution cap, so tiles play the primary (best-ranked) URL as-is;
            // single shared LibVLC instance bounds native overhead instead.
            StatusLine.Text = events.Count == 0 ? "" : "Loading tiles…";
        });

        // Channels are loaded once per page (not per tile); per-tile resolve
        // reuses the same pipeline as PlayerPage: provider channels + Stremio
        // addon options -> StreamResolver.Candidates -> Primary.
        // NO preflight probe per tile: 4x HEAD/GET probing would stall wall
        // startup; a failed tile surfaces inline with Retry instead.
        List<IptvChannel> channels = [];
        try { channels = await LoadChannelsAsync().ConfigureAwait(false); }
        catch { /* offline: Stremio-only resolve */ }

        _channels = channels;
        var resolved = await Task.WhenAll(events.Select(ev => ResolveTileAsync(ev, channels))).ConfigureAwait(false);
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed) return;
            foreach (var (ev, outcome) in events.Zip(resolved, (a, b) => (a, b)))
                AddTile(ev, outcome);
            _audioIndex = _tiles.Count > 0 ? _tiles.Count - 1 : 0;
            ApplyAudioFocus();
            RebuildGrid();
            StatusLine.Text = "";
        });
    }

    private async Task<List<IptvChannel>> LoadChannelsAsync()
    {
        try
        {
            return _settings.IptvProvider == IptvProvider.Xtream
                ? await _xtream.GetChannelsAsync().ConfigureAwait(false)
                : await _stalker.GetChannelsAsync().ConfigureAwait(false);
        }
        catch { return []; }
    }

    private async Task<(PlayCandidate? Candidate, string? Url, string? Error)> ResolveTileAsync(
        SportEvent ev, List<IptvChannel> channels)
    {
        try
        {
            var options = new List<StremioStreamOption>();
            foreach (var addon in _settings.StremioAddonUrls)
            {
                try { options.AddRange(await _stremio.FindStreamsAsync(ev, addon).ConfigureAwait(false)); }
                catch { /* per-addon failure is not fatal */ }
            }
            var cands = StreamResolver.Candidates(ev, channels, options,
                url => _settings.GetStreamHealth(url).Score);
            var primary = StreamResolver.Primary(cands);
            if (primary is null) return (null, null, "No live broadcast available");
            var url = primary.Url;
            if (primary.Kind == PlayKind.Iptv && primary.Channel is not null)
            {
                try
                {
                    url = _settings.IptvProvider == IptvProvider.Xtream
                        ? await _xtream.ResolveStreamUrlAsync(primary.Channel.Id).ConfigureAwait(false)
                        : await _stalker.ResolveStreamUrlAsync(primary.Channel.Id).ConfigureAwait(false);
                }
                catch { /* fall back to candidate URL */ }
            }
            return (primary, url, null);
        }
        catch (Exception ex) { return (null, null, ex.Message); }
    }

    private void AddTile(SportEvent ev, (PlayCandidate? Candidate, string? Url, string? Error) outcome)
    {
        if (_tiles.Count >= 4 || _libvlc is null) return;
        var player = new MediaPlayer(_libvlc);
        var view = new VideoView { MediaPlayer = player };
        var title = new TextBlock
        {
            Text = TileTitle(ev),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap
        };
        var status = new TextBlock { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        var id = Guid.NewGuid().ToString();
        var tile = new Tile
        {
            Id = id,
            Event = ev,
            Player = player,
            View = view,
            TitleBlock = title,
            StatusBlock = status,
            Root = new Border
            {
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["RallySurface"],
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(8),
                Tag = id,
            },
        };
        player.Playing += (_, _) =>
        {
            try { if (tile.PlayUrl is not null) _settings.RecordStreamSuccess(tile.PlayUrl, 0); } catch { }
        };
        player.EncounteredError += (_, _) =>
        {
            try { if (tile.PlayUrl is not null) _settings.RecordStreamFailure(tile.PlayUrl); } catch { }
            DispatcherQueue.TryEnqueue(() => tile.StatusBlock.Text = "Playback error — Retry.");
        };
        tile.Root.PointerPressed += Tile_PointerPressed;

        var body = new Grid { RowSpacing = 6 };
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(view, 0);
        body.Children.Add(view);

        var header = new StackPanel { Spacing = 2 };
        header.Children.Add(title);
        header.Children.Add(status);
        Grid.SetRow(header, 1);
        body.Children.Add(header);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(new Button { Content = "Audio", Tag = id });
        actions.Children.Add(new Button { Content = "Retry", Tag = id });
        actions.Children.Add(new Button { Content = "Remove", Tag = id });
        ((Button)actions.Children[0]).Click += Audio_Click;
        ((Button)actions.Children[1]).Click += Retry_Click;
        ((Button)actions.Children[2]).Click += Remove_Click;
        Grid.SetRow(actions, 2);
        body.Children.Add(actions);

        tile.Root.Child = body;
        _tiles.Add(tile);

        if (outcome is { Candidate: not null, Url: not null })
        {
            tile.Candidate = outcome.Candidate;
            PlayTile(tile, outcome.Url);
        }
        else
        {
            status.Text = outcome.Error ?? "No live broadcast available";
            if (outcome.Url is null && outcome.Candidate is not null)
                status.Text = "Could not resolve stream — Retry.";
            try { _settings.RecordStreamFailure(ev.Id); } catch { }
        }
    }

    private void PlayTile(Tile tile, string url)
    {
        if (_libvlc is null) return;
        // libVLC cannot inject Cookie/Authorization headers: only
        // user-agent + referrer survive (same limit as PlayerPage).
        var media = new Media(_libvlc, url, FromType.FromLocation);
        foreach (var (k, v) in tile.Candidate?.Headers ?? new Dictionary<string, string>())
        {
            if (k.Equals("user-agent", StringComparison.OrdinalIgnoreCase)) media.AddOption($":http-user-agent={v}");
            if (k.Equals("referer", StringComparison.OrdinalIgnoreCase)) media.AddOption($":http-referrer={v}");
            // NOTE: Cookie/Authorization headers are dropped here by design.
        }
        tile.PlayUrl = url;
        tile.StatusBlock.Text = tile.Candidate?.Title ?? "Live";
        tile.Player.Play(media);
        // New tile takes single-audio focus; the rest stay muted.
        _audioIndex = _tiles.IndexOf(tile);
        ApplyAudioFocus();
        RefreshTitles();
    }

    private void ApplyAudioFocus()
    {
        for (var i = 0; i < _tiles.Count; i++)
        {
            try { _tiles[i].Player.Volume = i == _audioIndex ? 100 : 0; } catch { }
        }
    }

    private void RefreshTitles()
    {
        for (var i = 0; i < _tiles.Count; i++)
            _tiles[i].TitleBlock.Text = (i == _audioIndex ? "🔊 " : "") + TileTitle(_tiles[i].Event);
    }

    private static string TileTitle(SportEvent ev)
    {
        var away = ev.AwayTeam?.Abbreviation ?? "";
        var home = ev.HomeTeam?.Abbreviation ?? "";
        var matchup = string.IsNullOrEmpty(away) && string.IsNullOrEmpty(home) ? ev.Name : $"{away} @ {home}";
        var score = ev.ScoreAway is not null && ev.ScoreHome is not null ? $"  {ev.ScoreAway}-{ev.ScoreHome}" : "";
        return matchup + score;
    }

    private void RebuildGrid()
    {
        TileGrid.Children.Clear();
        TileGrid.RowDefinitions.Clear();
        TileGrid.ColumnDefinitions.Clear();
        EmptyState.Visibility = _tiles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        TileGrid.Visibility = _tiles.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        TileCount.Text = $"{_tiles.Count} / 4 max";
        if (_tiles.Count == 0) return;

        TileGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        TileGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var rows = _tiles.Count <= 2 ? 1 : 2;
        for (var r = 0; r < rows; r++)
            TileGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        for (var i = 0; i < _tiles.Count; i++)
        {
            var root = _tiles[i].Root;
            int row, col, span = 1;
            if (_tiles.Count == 1) { row = 0; col = 0; span = 2; }
            else if (_tiles.Count == 2) { row = 0; col = i; }
            else if (_tiles.Count == 3) { row = i == 0 ? 0 : 1; col = i == 0 ? 0 : i - 1; span = i == 0 ? 2 : 1; }
            else { row = i / 2; col = i % 2; }
            Grid.SetRow(root, row);
            Grid.SetColumn(root, col);
            Grid.SetColumnSpan(root, span);
            TileGrid.Children.Add(root);
        }
        RefreshTitles();
    }

    private Tile? FindTile(object sender) =>
        (sender as Button)?.Tag is string id ? _tiles.FirstOrDefault(t => t.Id == id) : null;

    private void Tile_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        // Tap a tile to take single-audio focus (Android onClick -> use-audio).
        if ((sender as Border)?.Tag is string id)
        {
            var index = _tiles.FindIndex(t => t.Id == id);
            if (index >= 0)
            {
                _audioIndex = index;
                ApplyAudioFocus();
                RefreshTitles();
            }
        }
    }

    private void Audio_Click(object sender, RoutedEventArgs e)
    {
        var tile = FindTile(sender);
        if (tile is null) return;
        _audioIndex = _tiles.IndexOf(tile);
        ApplyAudioFocus();
        RefreshTitles();
    }

    private async void Retry_Click(object sender, RoutedEventArgs e)
    {
        var tile = FindTile(sender);
        if (tile is null) return;
        tile.StatusBlock.Text = "Retrying…";
        var outcome = await ResolveTileAsync(tile.Event, _channels).ConfigureAwait(false);
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed || !_tiles.Contains(tile)) return;
            if (outcome is { Candidate: not null, Url: not null })
            {
                tile.Candidate = outcome.Candidate;
                PlayTile(tile, outcome.Url);
            }
            else tile.StatusBlock.Text = outcome.Error ?? "No live broadcast available";
        });
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        var tile = FindTile(sender);
        if (tile is null) return;
        try { tile.Player.Stop(); } catch { }
        tile.Root.PointerPressed -= Tile_PointerPressed;
        tile.View.MediaPlayer = null;
        try { tile.Player.Dispose(); } catch { }
        try { (tile.View as IDisposable)?.Dispose(); } catch { }
        _tiles.Remove(tile);
        if (_audioIndex >= _tiles.Count) _audioIndex = Math.Max(0, _tiles.Count - 1);
        ApplyAudioFocus();
        RebuildGrid();
    }

    private void DisposeAll()
    {
        _disposed = true;
        foreach (var tile in _tiles)
        {
            try { tile.Player.Stop(); } catch { }
            tile.Root.PointerPressed -= Tile_PointerPressed;
            try { tile.View.MediaPlayer = null; } catch { }
            try { tile.Player.Dispose(); } catch { }
            try { (tile.View as IDisposable)?.Dispose(); } catch { }
        }
        _tiles.Clear();
        _libvlc?.Dispose();
        _libvlc = null;
    }
}
