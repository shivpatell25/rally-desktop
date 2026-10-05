namespace Rally.App.Services;
public static class ScoreAnnouncer
{
    private static Windows.Media.Playback.MediaPlayer? _player;
    public static async Task Announce(IEnumerable<Rally.Core.SportEvent> events)
    {
        if (!App.Data.Settings.SpokenScoreSummaries) return;
        try
        {
            var text = string.Join(". ", events.Take(3).Select(e => $"{e.Name}. {e.AwayTeam?.Abbreviation} {e.ScoreAway} to {e.HomeTeam?.Abbreviation} {e.ScoreHome}. {e.GameStatusDetail}"));
            if (text.Length == 0) return;
            using var speech = new Windows.Media.SpeechSynthesis.SpeechSynthesizer();
            var stream = await speech.SynthesizeTextToStreamAsync(text); _player?.Dispose();
            var player = new Windows.Media.Playback.MediaPlayer(); _player = player;
            player.Source = Windows.Media.Core.MediaSource.CreateFromStream(stream, stream.ContentType);
            player.MediaEnded += (_, _) => { player.Dispose(); stream.Dispose(); }; player.Play();
        }
        catch { }
    }
}
