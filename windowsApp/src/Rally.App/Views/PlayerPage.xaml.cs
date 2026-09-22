using LibVLCSharp.Shared;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.Core;

namespace Rally.App.Views;

public sealed partial class PlayerPage : Page
{
    private LibVLC? _libvlc;
    private MediaPlayer? _player;
    private readonly SettingsStore _settings = new();
    private readonly HttpClient _http = new();
    private readonly StremioClient _stremio;
    private readonly StalkerClient _stalker;
    private readonly XtreamClient _xtream;
    private readonly StreamPreflightProbe _probe;
    private List<PlayCandidate> _candidates = [];
    private readonly Dictionary<string, string> _notes = new(StringComparer.Ordinal);
    private readonly List<string> _log = [];
    private PlayCandidate? _current;

    public PlayerPage()
    {
        InitializeComponent();
        _stremio = new StremioClient(_http);
        _stalker = new StalkerClient(_http, _settings);
        _xtream = new XtreamClient(_http, _settings);
        _probe = new StreamPreflightProbe(new HttpClient { Timeout = TimeSpan.FromSeconds(5) });
        Unloaded += (_, _) =>
        {
            _player?.Stop();
            _player?.Dispose();
            _libvlc?.Dispose();
            _player = null;
            _libvlc = null;
        };
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        await LoadAsync(e.Parameter);
    }

    private async Task LoadAsync(object? param)
    {
        _current = null;
        _candidates = [];
        _notes.Clear();
        ErrorText.Visibility = Visibility.Collapsed;
        EnsurePlayer();
        if (_libvlc is null || _player is null) return;
        Loading.IsActive = true;
        try
        {
            switch (param)
            {
                case SportEvent ev:
                    await LoadEventAsync(ev);
                    break;
                case IptvChannel ch:
                    await LoadDirectChannelsAsync([ch], ch.Name);
                    break;
                case string url when !string.IsNullOrWhiteSpace(url):
                    await LoadClipUrlAsync(url);
                    break;
                case null:
                    ShowError("No event selected");
                    break;
                default:
                    ShowError("No event selected");
                    break;
            }
        }
        finally { Loading.IsActive = false; }
    }

    private void EnsurePlayer()
    {
        LibVLCSharp.Shared.Core.Initialize();
        _libvlc?.Dispose();
        _player?.Dispose();
        _libvlc = new LibVLC("--no-video-title-show");
        _player = new MediaPlayer(_libvlc);
        Video.MediaPlayer = _player;
    }

    private async Task LoadEventAsync(SportEvent ev)
    {
        NowPlaying.Text = ev.Name;
        var options = await FetchStremioOptionsAsync(ev);
        var channels = await FetchProviderChannelsAsync();
        Log($"stremio={options.Count} channels={channels.Count}");
        _candidates = StreamResolver.Candidates(ev, channels, options,
            health: SafeHealth,
            tvStations: ev.Broadcasts);
        await PreflightTopAsync();
        RefreshSources();
        RefreshDiagnostics();
        if (_candidates.Count == 0)
        {
            ShowError("No playable sources found — check addon URLs and IPTV provider in Settings");
            return;
        }
        var first = StreamResolver.Primary(_candidates) ?? _candidates[0];
        Log($"autoplay {first.Title}");
        await PlayAsync(first);
    }

    private async Task LoadDirectChannelsAsync(List<IptvChannel> channels, string title)
    {
        NowPlaying.Text = title;
        _candidates = StreamResolver.ChannelCandidates(channels);
        RefreshSources();
        RefreshDiagnostics();
        if (_candidates.Count == 0)
        {
            ShowError("No playable sources found — check addon URLs and IPTV provider in Settings");
            return;
        }
        Log($"autoplay direct {title}");
        await PlayAsync(_candidates[0]);
    }

    private async Task LoadClipUrlAsync(string url)
    {
        // ESPN highlight one-off, mirroring macOS playClip: Stremio-kind, exact, rank 0.
        var clip = new PlayCandidate(Guid.NewGuid().ToString(), "Highlight", url, null,
            PlayKind.Stremio, true, 0, null, "ESPN");
        _candidates = [clip];
        RefreshSources();
        RefreshDiagnostics();
        await PlayAsync(clip);
    }

    private async Task<List<StremioStreamOption>> FetchStremioOptionsAsync(SportEvent ev)
    {
        var all = new List<StremioStreamOption>();
        foreach (var addon in _settings.StremioAddonUrls)
        {
            try { all.AddRange(await _stremio.FindStreamsAsync(ev, addon).ConfigureAwait(false)); }
            catch (Exception ex) { Log($"addon failed: {ex.Message}"); }
        }
        return all;
    }

    private async Task<List<IptvChannel>> FetchProviderChannelsAsync()
    {
        try
        {
            if (_settings.IptvProvider == IptvProvider.Xtream)
                return await _xtream.GetChannelsAsync().ConfigureAwait(false);
            return await _stalker.GetChannelsAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Log($"channels failed: {ex.Message}");
            return [];
        }
    }

    private async Task PreflightTopAsync()
    {
        var targets = _candidates
            .Where(c => c.Kind == PlayKind.Stremio)
            .OrderByDescending(c => c.Rank)
            .Take(5)
            .ToList();
        var results = await Task.WhenAll(targets.Select(async cand =>
        {
            try { return (cand.Id, Result: (PreflightResult?)await _probe.ProbeAsync(cand.Url, cand.Headers).ConfigureAwait(false)); }
            catch { return (cand.Id, Result: (PreflightResult?)null); }
        })).ConfigureAwait(false);
        foreach (var (id, result) in results)
        {
            if (result is null) continue;
            var i = _candidates.FindIndex(c => c.Id == id);
            if (i < 0) continue;
            _candidates[i] = _candidates[i] with
            {
                PreflightPassed = result.Passed,
                PreflightLatencyMs = result.LatencyMs,
                PreflightContentType = result.ContentType,
            };
            _notes[id] = result.Passed ? $"Verified {result.LatencyMs} ms" : $"Unreachable: {result.Detail}";
        }
        _candidates = StreamResolver.Sort(_candidates, SafeHealth);
    }

    private async Task<bool> PlayAsync(PlayCandidate cand)
    {
        if (_libvlc is null || _player is null) return false;
        var startedAt = DateTimeOffset.UtcNow;
        _notes[cand.Id] = "Resolving…";
        RefreshSources();
        var url = cand.Url;
        if (cand.Kind == PlayKind.Iptv && cand.Channel is not null)
        {
            try
            {
                var resolved = _settings.IptvProvider == IptvProvider.Xtream
                    ? await _xtream.ResolveStreamUrlAsync(cand.Channel.Id)
                    : await _stalker.ResolveStreamUrlAsync(cand.Channel.Id);
                if (!string.IsNullOrWhiteSpace(resolved)) url = resolved;
                var i = _candidates.FindIndex(c => c.Id == cand.Id);
                if (i >= 0)
                {
                    _candidates[i] = _candidates[i] with { Url = url };
                    cand = _candidates[i];
                }
            }
            catch (Exception ex) { Log($"resolve failed: {ex.Message}"); }
        }
        if (!Uri.TryCreate(url, UriKind.Absolute, out var target) ||
            (target.Scheme != Uri.UriSchemeHttp && target.Scheme != Uri.UriSchemeHttps))
        {
            _notes[cand.Id] = "Bad stream URL";
            ShowError("Bad stream URL");
            try { _settings.RecordStreamFailure(cand.Url); } catch { }
            Log("bad url");
            RefreshSources();
            RefreshDiagnostics();
            return false;
        }
        // External Stremio headers ride along; authed Stalker playback synthesizes
        // UA + Cookie mac + bearer token below (Android PlayerScreen parity).
        var headers = StreamRequestHeaders.Sanitize(cand.Headers ?? ChannelHeaders(cand));
        try
        {
            using var media = new Media(_libvlc, url, FromType.FromLocation);
            // libVLC cannot inject Cookie/Authorization headers — only
            // user-agent/referer are forwarded; Stalker auth rides the resolved URL.
            foreach (var (name, value) in headers)
            {
                if (name.Equals("user-agent", StringComparison.OrdinalIgnoreCase))
                    media.AddOption($":http-user-agent={value}");
                else if (name.Equals("referer", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("referrer", StringComparison.OrdinalIgnoreCase))
                    media.AddOption($":http-referrer={value}");
            }
            NowPlaying.Text = cand.Title;
            ErrorText.Visibility = Visibility.Collapsed;
            if (!_player.Play(media))
                throw new InvalidOperationException("Player refused the stream");
            _current = cand;
            _notes[cand.Id] = "Playing";
            var startupMs = (long)(DateTimeOffset.UtcNow - startedAt).TotalMilliseconds;
            try { _settings.RecordStreamSuccess(cand.Url, startupMs); } catch { }
            Log($"playing {cand.Title} startupMs={startupMs}");
        }
        catch (Exception ex)
        {
            _notes[cand.Id] = $"Failed: {ex.Message}";
            ShowError($"Playback failed: {ex.Message}");
            try { _settings.RecordStreamFailure(cand.Url); } catch { }
            Log($"failed: {ex.Message}");
            RefreshSources();
            RefreshDiagnostics();
            return false;
        }
        RefreshSources();
        RefreshDiagnostics();
        return true;
    }

    private Dictionary<string, string>? ChannelHeaders(PlayCandidate cand)
    {
        if (cand.Kind != PlayKind.Iptv) return null;
        if (_settings.IptvProvider != IptvProvider.Stalker) return null;
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["User-Agent"] = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3",
        };
        var mac = _settings.MacAddress;
        if (!string.IsNullOrWhiteSpace(mac)) headers["Cookie"] = $"mac={mac}; stb_lang=en; timezone=GMT";
        var token = _settings.AuthToken;
        if (!string.IsNullOrWhiteSpace(token)) headers["Authorization"] = StreamRequestHeaders.NormalizedBearerToken(token.Trim());
        return headers;
    }

    private int SafeHealth(string url)
    {
        try { return _settings.GetStreamHealth(url).Score; }
        catch { return 0; }
    }

    private void RefreshSources()
    {
        Sources.ItemsSource = _candidates
            .Select(c => new SourceRow(c, _notes.TryGetValue(c.Id, out var n) ? n : ""))
            .ToList();
    }

    private void RefreshDiagnostics()
    {
        if (_current is null)
        {
            Diagnostics.Text = _candidates.Count == 0 ? "No sources." : $"{_candidates.Count} sources.";
            return;
        }
        var c = _current;
        var q = Quality.Parse(c.Title);
        var specs = string.Join(" ",
            new[] { q.Resolution, q.Fps, q.IsHdr ? "HDR" : null }.Where(s => !string.IsNullOrEmpty(s)));
        if (specs.Length == 0) specs = "Unknown";
        var delivery = c.Kind == PlayKind.Iptv
            ? $"IPTV ({_settings.IptvProvider})"
            : $"Stremio ({c.AddonName ?? "addon"})";
        Diagnostics.Text =
            $"Source: {c.Title}\nDelivery: {delivery}\nSpecs: {specs}\nHealth: {SafeHealth(c.Url)}\n" +
            string.Join("\n", _log.TakeLast(3));
    }

    private void Log(string line)
    {
        _log.Add($"{DateTimeOffset.Now:HH:mm:ss} {line}");
        while (_log.Count > 20) _log.RemoveAt(0);
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
        RefreshSources();
        RefreshDiagnostics();
    }

    private async void Sources_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Sources.SelectedItem is SourceRow row)
        {
            Sources.SelectedItem = null;
            var live = _candidates.FirstOrDefault(c => c.Id == row.Candidate.Id) ?? row.Candidate;
            await PlayAsync(live);
        }
    }

    private void Pause_Click(object sender, RoutedEventArgs e) => _player?.Pause();

    private async void Restart_Click(object sender, RoutedEventArgs e)
    {
        var target = StreamResolver.Primary(_candidates)
            ?? (_current is not null ? _candidates.FirstOrDefault(c => c.Id == _current.Id) : null)
            ?? _candidates.FirstOrDefault();
        if (target is null) return;
        _notes.Remove(target.Id);
        await PlayAsync(target);
    }

    private async void Retry_Click(object sender, RoutedEventArgs e)
    {
        ErrorText.Visibility = Visibility.Collapsed;
        foreach (var id in _candidates.Select(c => c.Id).ToList())
        {
            var live = _candidates.FirstOrDefault(c => c.Id == id);
            if (live is not null && await PlayAsync(live)) return;
        }
        if (_current is null)
            ShowError(_candidates.Count == 0 ? "No playable sources found" : "All sources failed");
    }

    public sealed record SourceRow(PlayCandidate Candidate, string Note)
    {
        public string Title => Candidate.Title;
        public string? Evidence => Candidate.MatchEvidence;
        public string VerifiedText => Candidate.PreflightPassed == true && Candidate.PreflightLatencyMs is long ms
            ? $"Verified {ms} ms"
            : Candidate.PreflightPassed == false ? "Unreachable" : "";
    }
}
