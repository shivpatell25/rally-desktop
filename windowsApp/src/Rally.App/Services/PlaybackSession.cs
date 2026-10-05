using LibVLCSharp.Shared;
using Rally.Core;

namespace Rally.App.Services;

public sealed record PlaybackRequest(SportEvent Game, PlayCandidate Source);

public sealed class PlaybackSession : IAsyncDisposable
{
    private readonly RallyRepository _data;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private LibVLC? _engine;
    private readonly TaskCompletionSource<string[]> _outputReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool _softwareOutput;
    private string _adapter = "Initializing";
    public void ConfigureVideoOutput(string[] options, bool softwareOutput, string adapter)
    {
        _softwareOutput = softwareOutput; _adapter = adapter;
        _outputReady.TrySetResult(options);
    }
    private StreamRelay? _relay;
    private CancellationTokenSource? _request;
    private CancellationTokenSource? _playRequest;
    private bool _disposed, _wantsPlayback = true, _suspended, _retryPending;
    private long _suspendedPosition, _lastFrames;
    private DateTimeOffset? _healthySince;
    private Task? _disposeTask;
    private int _generation;
    public MediaPlayer? Player { get; private set; }
    public SportEvent? Event { get; private set; }
    public List<PlayCandidate> Candidates { get; private set; } = [];
    public PlayCandidate? Current { get; private set; }
    public string Status { get; private set; } = "Choose a game or channel";
    private bool _playing, _switching;
    private int _volume = 100;
    private bool _muted;
    public bool IsPlaying => _playing;
    internal bool HasVideoFrames
    {
        get { try { using var media = Player?.Media; return media?.Statistics is MediaStats stats && stats.DisplayedPictures > 0; } catch { return false; } }
    }
    public bool Loading { get; private set; }
    public event Action? Changed;
    public event Action? Detaching;
    private DateTimeOffset _lastAdvance = DateTimeOffset.UtcNow;
    private long _lastTime;
    private int _recoveries;
    private readonly System.Collections.Concurrent.ConcurrentQueue<string> _errors = new();
    public PlaybackSession(RallyRepository data) { _data = data; }
    private void Notify() => App.Window?.DispatcherQueue.TryEnqueue(() => Changed?.Invoke());
    public async Task OpenAsync(object? parameter, CancellationToken cancellationToken = default)
    {
        if (_disposed) return;
        // A standalone channel/clip is a different playback context from a game,
        // even when an addon returns the same URL for both.
        var sameSource = Event is null && (parameter is PlayCandidate requestedSource && Current?.Url == requestedSource.Url
            || parameter is string clip && Current?.Url == clip);
        if (sameSource && _suspended) { await ResumeAsync(); return; }
        if (sameSource && Player is not null) { Notify(); return; }
        if (parameter is SportEvent returning && Event?.Id == returning.Id && Event.League == returning.League && _suspended) { await ResumeAsync(); return; }
        if (parameter is SportEvent ev && Event?.Id == ev.Id && Event.League == ev.League && Player is not null) { Notify(); return; }
        await SuspendAsync();
        if (_disposed) return;
        Current = null; Candidates = [];
        _request?.Cancel(); _request?.Dispose(); _request = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); var ct = _request.Token;
        Loading = true; Status = "Finding sources…"; Event = parameter is PlaybackRequest selected ? selected.Game : parameter as SportEvent; Notify();
        try
        {
            Candidates = parameter switch
            {
                SportEvent game => await _data.SourcesAsync(game, ct),
                PlaybackRequest selectedGame => new[] { selectedGame.Source }.Concat(await _data.SourcesAsync(selectedGame.Game, ct)).DistinctBy(c => c.Url).ToList(),
                IptvChannel channel => StreamResolver.ChannelCandidates([channel]),
                PlayCandidate candidate => [candidate],
                string url when Uri.TryCreate(url, UriKind.Absolute, out _) => [new("clip", "Highlight", url, null, PlayKind.Stremio, true, 0)],
                _ => []
            };
            if (ct.IsCancellationRequested) return;
            if (Candidates.Count == 0) { Status = "No sources found. Check your addon or IPTV settings."; Loading = false; Notify(); return; }
            await PlayAsync(parameter is PlaybackRequest choice ? choice.Source : StreamResolver.Primary(Candidates) ?? Candidates[0], ct, renew: parameter is PlaybackRequest);
        }
        catch (OperationCanceledException) { }
        catch { if (!ct.IsCancellationRequested && !_disposed) { _switching = false; Loading = false; Status = "Sources couldn't be loaded. Try again or choose another source."; Notify(); } }
    }
    public async Task PlayAsync(PlayCandidate candidate, CancellationToken ct = default, bool recovery = false, bool renew = false)
    {
        if (_disposed) return;
        _playRequest?.Cancel(); _playRequest?.Dispose();
        _playRequest = CancellationTokenSource.CreateLinkedTokenSource(ct); ct = _playRequest.Token;
        var generation = Interlocked.Increment(ref _generation); _suspended = false; _wantsPlayback = true; _switching = true; _playing = false; Loading = true; Status = "Connecting…"; Notify();
        var acquired = false;
        try
        {
            await _gate.WaitAsync(ct); acquired = true;
            if (generation != _generation) return;
            Current = candidate;
            // The window owns the swapchain independently. Recreate the native
            // decoder after stopping it, so seek/restart state cannot leak into
            // the next source's Direct3D output.
            if (_relay is not null) { await _relay.DisposeAsync(); _relay = null; }
            var previous = Player;
            if (previous is not null)
            {
                _volume = Math.Clamp(previous.Volume, 0, 100); _muted = previous.Mute;
                Detaching?.Invoke(); Player = null;
                await Task.Run(() => { previous.Stop(); previous.Dispose(); });
            }
            if (generation != _generation) return;
            var outputOptions = await _outputReady.Task.WaitAsync(TimeSpan.FromSeconds(15), ct);
            if (renew)
            {
                candidate = await _data.RenewSourceAsync(candidate, Event, ct);
                if (generation != _generation) return;
                Candidates = new[] { candidate }.Concat(Candidates.Where(c => !(c.Title == candidate.Title && c.AddonName == candidate.AddonName))).ToList();
                Current = candidate;
            }
            var url = await _data.StreamUrlAsync(candidate, ct); ct.ThrowIfCancellationRequested();
            if (generation != _generation || _disposed) return;
            LibVLCSharp.Shared.Core.Initialize(); if (_engine is null)
            {
                // VLC's default WASAPI output shares its Windows audio session
                // between players. DirectSound controls each stream's buffer,
                // allowing multiview to mute streams independently.
                _engine = new LibVLC(outputOptions.Concat(new[] { "--no-video-title-show", "--no-snapshot-preview", "--aout=directsound", "--no-volume-save" }).ToArray());
                _engine.Log += (_, log) => { if (log.Level >= LogLevel.Warning) { _errors.Enqueue(System.Text.RegularExpressions.Regex.Replace(log.Message, @"https?://\S+", "[stream]")); while (_errors.Count > 12) _errors.TryDequeue(out var discarded); } };
            }
            var headers = StreamRequestHeaders.Sanitize(candidate.Headers);
            if (candidate.Channel is not null && _data.Settings.IptvProvider == IptvProvider.Stalker)
                foreach (var header in _data.Stalker.PlaybackHeaders()) headers[header.Key] = header.Value;
            if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https") { _relay = new(url, headers); url = _relay.Url; }
            if (Player is null)
            {
                var native = new MediaPlayer(_engine) { EnableKeyInput = false, EnableMouseInput = false, Volume = _volume, Mute = _muted }; Player = native;
                native.Playing += (_, _) => { if (_switching || !ReferenceEquals(Player, native)) return; _playing = true; Loading = false; Status = Current?.Title ?? "Playing"; _lastAdvance = DateTimeOffset.UtcNow; if (Current is not null) _data.Settings.RecordStreamSuccess(Current.Url, 0); Notify(); };
                native.Paused += (_, _) => { if (_switching || !ReferenceEquals(Player, native)) return; _playing = false; Notify(); }; native.Stopped += (_, _) => { if (_switching || !ReferenceEquals(Player, native)) return; _playing = false; Notify(); };
                native.EncounteredError += (_, _) => { if (_switching || !ReferenceEquals(Player, native)) return; _playing = false; Loading = false; Status = "This stream couldn't play. Choose another source or retry."; if (Current is not null) _data.Settings.RecordStreamFailure(Current.Url); Notify(); };
                native.EndReached += (_, _) => { if (_switching || !ReferenceEquals(Player, native)) return; _playing = false; Status = "Playback ended"; Notify(); };
                native.Buffering += (_, e) => { if (_switching || !ReferenceEquals(Player, native)) return; Loading = e.Cache < 100; Notify(); };
            }
            var player = Player; Current = candidate; _lastAdvance = DateTimeOffset.UtcNow;
            using var media = new Media(_engine, url, FromType.FromLocation);
            // WARP presents video but cannot safely act as a hardware decoder.
            // Explicit software decode avoids its restart/seek device crashes.
            if (_softwareOutput) media.AddOption(":avcodec-hw=none");
            media.AddOption($":network-caching={(_data.Settings.LowLatencyMode ? 650 : 1600)}"); media.AddOption(":http-reconnect");
            if (_data.Settings.AudioNormalizationEnabled) media.AddOption(":audio-filter=normvol");
            _wantsPlayback = true; _suspended = false; _healthySince = null; _lastFrames = 0;
            _switching = false; Notify(); if (!player.Play(media)) { Loading = false; Status = "The stream could not start. Try another source."; Notify(); } _lastTime = 0; if (!recovery) _recoveries = 0;
        }
        catch (OperationCanceledException) { if (generation == _generation) { _switching = false; Loading = false; Status = "Playback canceled"; Notify(); } }
        catch { if (generation == _generation && !_disposed) { _switching = false; Loading = false; Status = "Playback couldn't start. Retry or select another source."; Notify(); } }
        finally { if (acquired) _gate.Release(); }
    }
    public void TogglePause() { if (Loading || Player is null || _disposed) return; _wantsPlayback = !_wantsPlayback; Player.SetPause(!_wantsPlayback); _lastAdvance = DateTimeOffset.UtcNow; _healthySince = null; Notify(); }
    public void SetMuted(bool muted) { _muted = muted; if (!_disposed && Player is { } player) player.Mute = muted; }
    public void Restart() { if (Loading) return; if (Player?.IsSeekable == true) Player.Time = 0; else { Status = "Restart is unavailable for this live source."; Notify(); } }
    public void Seek(long milliseconds) { if (Loading) return; if (Player?.IsSeekable == true) Player.Time = Math.Clamp(milliseconds, 0, Math.Max(0, Player.Length)); }
    public async Task RetryAsync() { if (Current is not null) await PlayAsync(Current, renew: true); else if (Event is not null) await OpenAsync(Event); }
    public void Tick()
    {
        if (_disposed || _suspended || _switching || _retryPending || !_wantsPlayback || Current is null) return;
        var player = Player; var now = DateTimeOffset.UtcNow;
        if (Loading) { if (now - _lastAdvance > TimeSpan.FromSeconds(30)) Recover(); return; }
        if (player is null) { if (now - _lastAdvance > TimeSpan.FromSeconds(3)) Recover(); return; }
        if (player.State == VLCState.Paused) return;
        if (player.State == VLCState.Ended && (Event is null || Event.Status == EventStatus.Finished) && Current.Channel is null) return;
        var currentTime = player.Time; long frames = 0; var hasVideo = false;
        try { using var media = player.Media; hasVideo = media?.Tracks.Any(t => t.TrackType == TrackType.Video) == true; if (media?.Statistics is MediaStats stats) frames = stats.DisplayedPictures; } catch { }
        if (currentTime != _lastTime && (!hasVideo || frames != _lastFrames))
        {
            _lastTime = currentTime; _lastFrames = frames; _lastAdvance = now;
            _healthySince ??= now; if (now - _healthySince > TimeSpan.FromSeconds(30)) _recoveries = 0;
        }
        else { _healthySince = null; if (player.State is VLCState.Error or VLCState.Ended || now - _lastAdvance > TimeSpan.FromSeconds(25)) Recover(); }
    }
    private async void Recover()
    {
        if (_retryPending || _disposed || Current is null) return;
        _retryPending = true;
        try
        {
            _data.Settings.RecordStreamStall(Current.Url);
            if (_recoveries >= 2) { await SuspendAsync(); _suspended = false; _wantsPlayback = false; Status = "This source stopped updating. Retry or choose another source."; Loading = false; Notify(); return; }
            _recoveries++; await PlayAsync(Current, recovery: true, renew: true);
        }
        finally { _retryPending = false; }
    }
    public async Task SuspendAsync()
    {
        if (_disposed) return;
        _suspended = true; Interlocked.Increment(ref _generation); _playRequest?.Cancel(); _request?.Cancel();
        await _gate.WaitAsync();
        try
        {
            var old = Player; _suspendedPosition = old?.Time ?? 0; Player = null; _playing = false; Loading = false;
            Detaching?.Invoke();
            if (old is not null) await Task.Run(() => { old.Stop(); old.Dispose(); });
            if (_relay is not null) { await _relay.DisposeAsync(); _relay = null; }
            Notify();
        }
        finally { _gate.Release(); }
    }
    public async Task ResumeAsync()
    {
        if (!_suspended || _disposed || Current is null) return;
        var wanted = _wantsPlayback; var position = _suspendedPosition;
        await PlayAsync(Current, renew: true);
        var generation = _generation;
        for (var i = 0; i < 150 && !_disposed && generation == _generation && Player is not null && Player.State is not (VLCState.Playing or VLCState.Error or VLCState.Ended); i++) await Task.Delay(100);
        if (_disposed || generation != _generation || Player is null) return;
        // Playing is raised before the first decoded frame. Pausing immediately
        // can leave the restored page black and make an early VOD seek ineffective.
        for (var i = 0; i < 50 && !HasVideoFrames && !_disposed && generation == _generation && Player is not null; i++)
        {
            using var media = Player.Media;
            if (media?.Tracks.Any(track => track.TrackType == TrackType.Video) != true) break;
            await Task.Delay(100);
        }
        if (_disposed || generation != _generation || Player is null) return;
        if ((Event is null || Event.Status == EventStatus.Finished) && Current.Channel is null && Player.IsSeekable && position > 0)
        {
            Player.Time = position;
            // HLS seeks are asynchronous. Let decoding reach the saved position
            // before restoring a pause, rather than freezing at the segment's
            // preceding keyframe.
            for (var i = 0; i < 50 && !_disposed && generation == _generation && Player is not null && Math.Abs(Player.Time - position) > 1_500; i++) await Task.Delay(100);
        }
        if (_disposed || generation != _generation || Player is null) return;
        _wantsPlayback = wanted; Player.SetPause(!wanted); Notify();
    }
    public string Diagnostics()
    {
        var player = Loading || _switching ? null : Player; var host = Uri.TryCreate(Current?.Url, UriKind.Absolute, out var uri) ? uri.Host : "—";
        var technical = "";
        try
        {
            using var media = player?.Media;
            if (media is not null)
            {
                var track = media.Tracks.FirstOrDefault(t => t.TrackType == TrackType.Video);
                if (track.TrackType == TrackType.Video) technical = $"Resolution: {track.Data.Video.Width} × {track.Data.Video.Height}\nFrame rate: {(track.Data.Video.FrameRateDen > 0 ? ((double)track.Data.Video.FrameRateNum / track.Data.Video.FrameRateDen).ToString("0.##") + " fps" : "Not reported")}\nCodec: {System.Text.Encoding.ASCII.GetString(BitConverter.GetBytes(track.Codec)).TrimEnd('\0')}\n";
                if (media.Statistics is MediaStats stats) technical += $"Input bitrate: {stats.InputBitrate * 8:0.00} Mbps\nDecoded frames: {stats.DecodedVideo}\nDisplayed frames: {stats.DisplayedPictures}\nDropped frames: {stats.LostPictures}\n";
            }
        }
        catch { }
        return $"{technical}Graphics: {_adapter}\nDecoding: {(_softwareOutput ? "Software (compatible adapter)" : "Automatic hardware")}\nSource: {Current?.Title ?? "—"}\nProvider: {Current?.AddonName ?? Current?.Kind.ToString() ?? "—"}\nHost: {host}\nTransport: {(_relay is null ? "Direct" : "Managed relay")}\nState: {(Loading ? "Connecting" : player?.State.ToString())}\nPosition: {player?.Time / 1000}s\nDuration: {player?.Length / 1000}s\nSeekable: {player?.IsSeekable}\nAudio tracks: {player?.AudioTrackCount}\nCaption tracks: {player?.SpuCount}\nVolume: {player?.Volume}%\nRecoveries: {_recoveries}\nRecent errors: {string.Join(" | ", _errors)}";
    }
    public ValueTask DisposeAsync() => new(_disposeTask ??= DisposeCoreAsync());
    private async Task DisposeCoreAsync()
    {
        if (_disposed) return;
        _disposed = true; Interlocked.Increment(ref _generation); _playRequest?.Cancel(); _request?.Cancel(); await _gate.WaitAsync();
        try { _playing = false; if (_relay is not null) { await _relay.DisposeAsync(); _relay = null; } Detaching?.Invoke(); var old = Player; Player = null; if (old is not null) await Task.Run(() => { old.Stop(); old.Dispose(); }); if (_relay is not null) await _relay.DisposeAsync(); _engine?.Dispose(); _engine = null; }
        finally { _gate.Release(); App.Window?.DispatcherQueue.TryEnqueue(() => App.Window.ReleaseVideo(this)); }
    }
}
