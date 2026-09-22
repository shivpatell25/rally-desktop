using LibVLCSharp.Shared;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

// Game-view split: video left, Detail/Stats/Clips tabs right, other-live
// strip below. Mirrors macOS TvGameView gameViewLayout (video + info tabs +
// live row + highlights) and Android PlayerScreen game mode.
public sealed partial class GameViewPage : Page
{
    public sealed record InfoRow(string Title, string? Subtitle = null)
    {
        public Visibility HasSubtitle =>
            string.IsNullOrEmpty(Subtitle) ? Visibility.Collapsed : Visibility.Visible;
    }

    public sealed record LiveRow(SportEvent Event)
    {
        public string Name => LiveName(Event);
        public string Subtitle => $"{Event.League} · {LiveStatus(Event)}";
    }

    public sealed record ClipRow(HighlightClip Clip)
    {
        public string Title => Clip.Title;
        public string Subtitle => Clip.DurationSeconds is int s
            ? $"{s / 60}:{s % 60:00}"
            : (Clip.Description ?? "");
    }

    private LibVLC? _libvlc;
    private MediaPlayer? _player;
    private readonly SettingsStore _settings = new();
    private readonly StremioClient _stremio = new(new HttpClient());
    private readonly EspnClient _espn = new(new HttpClient());
    private readonly EspnDetail _detail = new(new HttpClient());
    private readonly StalkerClient _stalker;
    private readonly XtreamClient _xtream;
    private SportEvent? _event;
    private PlayCandidate? _current;
    private bool _disposed;

    public GameViewPage()
    {
        InitializeComponent();
        _stalker = new StalkerClient(new HttpClient(), _settings);
        _xtream = new XtreamClient(new HttpClient(), _settings);
        Unloaded += (_, _) => DisposePlayer();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is SportEvent ev)
            await LoadEventAsync(ev).ConfigureAwait(false);
    }

    private async Task LoadEventAsync(SportEvent ev)
    {
        _event = ev;
        _current = null;
        DispatcherQueue.TryEnqueue(() =>
        {
            try { LibVLCSharp.Shared.Core.Initialize(); } catch { /* already initialized */ }
            GameTitle.Text = ev.Name;
            NowPlaying.Text = "Loading…";
            ErrorLine.Visibility = Visibility.Collapsed;
            DetailList.ItemsSource = new List<InfoRow> { new("Loading…") };
            StatsList.ItemsSource = new List<InfoRow> { new("Loading…") };
            ClipsList.ItemsSource = new List<ClipRow>();
        });

        var streamTask = ResolvePrimaryAsync(ev);
        var detailTask = FetchDetailAsync(ev);
        var liveTask = FetchOtherLiveAsync(ev);
        var primary = await streamTask.ConfigureAwait(false);
        var detail = await detailTask.ConfigureAwait(false);
        var live = await liveTask.ConfigureAwait(false);
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed) return;
            ApplyStream(primary);
            ApplyDetail(detail);
            LiveStrip.ItemsSource = live;
        });
    }

    // NOTE (duplication): the resolve -> primary -> headers -> health flow
    // below duplicates PlayerPage.LoadAsync/Play (owned by PlayerOwner).
    // Kept inline so GameView stays self-contained during the parity pass;
    // follow-up is to extract a shared StreamStarter helper and call it
    // from both pages.
    private async Task<(PlayCandidate? Candidate, string Url, string? Error)> ResolvePrimaryAsync(SportEvent ev)
    {
        try
        {
            var channels = await LoadChannelsAsync().ConfigureAwait(false);
            var options = new List<StremioStreamOption>();
            foreach (var addon in _settings.StremioAddonUrls)
            {
                try { options.AddRange(await _stremio.FindStreamsAsync(ev, addon).ConfigureAwait(false)); }
                catch { /* per-addon failure is not fatal */ }
            }
            var cands = StreamResolver.Candidates(ev, channels, options,
                url => _settings.GetStreamHealth(url).Score);
            var primary = StreamResolver.Primary(cands);
            if (primary is null) return (null, "", "No live broadcast available");
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
        catch (Exception ex) { return (null, "", ex.Message); }
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

    private void ApplyStream((PlayCandidate? Candidate, string Url, string? Error) result)
    {
        _libvlc?.Dispose();
        _player?.Dispose();
        _libvlc = new LibVLC("--no-video-title-show");
        _player = new MediaPlayer(_libvlc);
        _player.Playing += (_, _) =>
        {
            try { if (_current is not null) _settings.RecordStreamSuccess(_current.Url, 0); } catch { }
        };
        _player.EncounteredError += (_, _) =>
        {
            try { if (_current is not null) _settings.RecordStreamFailure(_current.Url); } catch { }
            DispatcherQueue.TryEnqueue(() => ShowError("Playback error — Retry."));
        };
        Video.MediaPlayer = _player;
        if (result.Candidate is null)
        {
            NowPlaying.Text = "";
            ShowError(result.Error ?? "No live broadcast available");
            try { if (_event is not null) _settings.RecordStreamFailure(_event.Id); } catch { }
            return;
        }
        _current = result.Candidate;
        PlayUrl(result.Url, result.Candidate.Title, result.Candidate.Headers);
    }

    private void PlayUrl(string url, string title, Dictionary<string, string>? headers)
    {
        if (_libvlc is null || _player is null) return;
        // libVLC cannot inject Cookie/Authorization headers: only
        // user-agent + referrer survive (same limit as PlayerPage).
        var media = new Media(_libvlc, url, FromType.FromLocation);
        foreach (var (k, v) in headers ?? new Dictionary<string, string>())
        {
            if (k.Equals("user-agent", StringComparison.OrdinalIgnoreCase)) media.AddOption($":http-user-agent={v}");
            if (k.Equals("referer", StringComparison.OrdinalIgnoreCase)) media.AddOption($":http-referrer={v}");
            // NOTE: Cookie/Authorization headers are dropped here by design.
        }
        NowPlaying.Text = title;
        _player.Play(media);
    }

    private async Task<GameDetail> FetchDetailAsync(SportEvent ev)
    {
        try
        {
            var league = EspnClient.Leagues.FirstOrDefault(l => l.League == ev.League);
            if (league == default) return GameDetail.Empty;
            return await _detail.FetchSummaryAsync(league.Sport, league.Path, ev.Id,
                ev.AwayTeam?.Abbreviation, ev.HomeTeam?.Abbreviation).ConfigureAwait(false);
        }
        catch { return GameDetail.Empty; }
    }

    private void ApplyDetail(GameDetail detail)
    {
        if (_event is null) return;
        var ev = _event;
        var rows = new List<InfoRow>
        {
            new($"{ev.AwayTeam?.Abbreviation ?? "AWY"} @ {ev.HomeTeam?.Abbreviation ?? "HME"}",
                ev.ScoreAway is not null && ev.ScoreHome is not null ? $"{ev.ScoreAway} - {ev.ScoreHome}" : LiveStatus(ev)),
            new("Status", ev.GameStatusDetail ?? LiveStatus(ev)),
        };
        if (!string.IsNullOrEmpty(ev.Venue)) rows.Add(new InfoRow("Venue", ev.Venue));
        var broadcasts = ev.Broadcasts is { Count: > 0 } b ? b : detail.Broadcasts;
        if (broadcasts.Count > 0) rows.Add(new InfoRow("Broadcasts", string.Join(" · ", broadcasts)));
        foreach (var leader in detail.Leaders.Take(8))
            rows.Add(new InfoRow($"{leader.Category} · {leader.PlayerShortName}", leader.StatDisplay));
        foreach (var stat in detail.TeamStats)
            rows.Add(new InfoRow(stat.Label, $"{ev.AwayTeam?.Abbreviation}: {stat.AwayValue} · {ev.HomeTeam?.Abbreviation}: {stat.HomeValue}"));
        if (rows.Count == 2) rows.Add(new InfoRow("No extra detail yet", "Stats appear closer to game time."));
        DetailList.ItemsSource = rows;

        var stats = new List<InfoRow>();
        foreach (var table in detail.PlayerTables)
        {
            var labels = table.Labels is { Count: > 0 } l ? $" ({string.Join(" · ", l)})" : "";
            stats.Add(new InfoRow($"{table.TeamName} · {table.Category ?? "Stats"}{labels}"));
            foreach (var row in table.Rows ?? [])
                stats.Add(new InfoRow(row.DisplayName,
                    row.Stats is { Count: > 0 } s ? string.Join(" · ", s) : null));
        }
        if (stats.Count == 0) stats.Add(new InfoRow("No player stats yet", "Player stats appear closer to game time."));
        StatsList.ItemsSource = stats;

        ClipsList.ItemsSource = detail.Clips.Select(c => new ClipRow(c)).ToList();
    }

    private async Task<List<LiveRow>> FetchOtherLiveAsync(SportEvent current)
    {
        try
        {
            var all = await _espn.FetchAllAsync().ConfigureAwait(false);
            return all.Where(e => e.Id != current.Id && e.Status == EventStatus.Live)
                .Take(10).Select(e => new LiveRow(e)).ToList();
        }
        catch { return []; }
    }

    private void ShowError(string message)
    {
        ErrorLine.Text = message;
        ErrorLine.Visibility = Visibility.Visible;
    }

    private static string LiveName(SportEvent e)
    {
        var away = e.AwayTeam?.Abbreviation ?? "";
        var home = e.HomeTeam?.Abbreviation ?? "";
        return string.IsNullOrEmpty(away) && string.IsNullOrEmpty(home) ? e.Name : $"{away} @ {home}";
    }

    private static string LiveStatus(SportEvent e) => e.Status switch
    {
        EventStatus.Live => "LIVE",
        EventStatus.Halftime => "HALF",
        EventStatus.Finished => "FINAL",
        _ => e.StartTime.LocalDateTime.ToString("g"),
    };

    private void Clips_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ClipsList.SelectedItem is not ClipRow row) return;
        ClipsList.SelectedItem = null;
        var clip = row.Clip;
        if (!string.IsNullOrEmpty(clip.StreamUrl))
            PlayUrl(clip.StreamUrl, clip.Title, null);
        else if (!string.IsNullOrEmpty(clip.WebUrl))
            ShowError($"Clip has no direct stream (web only): {clip.WebUrl}");
        else
            ShowError("Clip has no playable stream.");
    }

    private void LiveStrip_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LiveStrip.SelectedItem is LiveRow row)
        {
            LiveStrip.SelectedItem = null;
            _ = LoadEventAsync(row.Event);
        }
    }

    private void Pause_Click(object sender, RoutedEventArgs e)
    {
        if (_player is null) return;
        if (_player.IsPlaying) _player.Pause();
        else _player.Play();
    }

    private void Restart_Click(object sender, RoutedEventArgs e)
    {
        // Live streams have no seekable start: restart reconnects the
        // current source. VOD clips restart from position 0.
        if (_player is null || _current is null) return;
        try
        {
            if (_player.Position > 0.001f && _player.Length > 0)
            {
                _player.Time = 0;
                return;
            }
        }
        catch { /* live: fall through to reconnect */ }
        _player.Stop();
        PlayUrl(_current.Url, _current.Title, _current.Headers);
    }

    private async void Retry_Click(object sender, RoutedEventArgs e)
    {
        if (_event is not null)
            await LoadEventAsync(_event).ConfigureAwait(false);
    }

    private void DisposePlayer()
    {
        _disposed = true;
        try { _player?.Stop(); } catch { }
        try { Video.MediaPlayer = null; } catch { }
        _player?.Dispose();
        _player = null;
        _libvlc?.Dispose();
        _libvlc = null;
    }
}
