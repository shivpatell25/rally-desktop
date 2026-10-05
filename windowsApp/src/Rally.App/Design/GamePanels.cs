using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.Core;

namespace Rally.App.Design;

public static class GamePanels
{
    public static UIElement Stats(SportEvent ev, GameDetail detail, bool compact = true)
    {
        var body = new StackPanel { Spacing = compact ? 10 : 22 };
        var leaders = RallyUi.Columns(2, 14);
        foreach (var (team, column) in new[] { (ev.AwayTeam, 0), (ev.HomeTeam, 1) })
        {
            var group = RallyUi.Column(RallyUi.Row(RallyUi.Image(team?.LogoUrl, 26, 26), RallyUi.Text(team?.Name ?? "Team", 12, false, true))); group.Spacing = compact ? 5 : 9;
            foreach (var leader in detail.Leaders.Where(l => l.TeamAbbr == team?.Abbreviation).Take(compact ? 3 : 5))
            {
                var photo = RallyUi.Image(leader.HeadshotUrl, compact ? 24 : 36, compact ? 24 : 36);
                var text = RallyUi.Column(RallyUi.Text(leader.PlayerShortName, 11, false, true), RallyUi.Text($"{leader.Category}: {leader.StatDisplay}", 10, true)); text.Spacing = 3;
                group.Children.Add(RallyUi.Row(photo, text));
            }
            if (group.Children.Count == 1) group.Children.Add(RallyUi.Text("Player leaders appear when reported.", 11, true));
            RallyUi.Put(leaders, group, column);
        }
        body.Children.Add(RallyUi.Column(RallyUi.Text("Team Leaders", 14, false, true), leaders));
        var teamStats = RallyUi.Column(RallyUi.Text("Team Stats", 14, false, true)); teamStats.Spacing = compact ? 5 : 8;
        foreach (var stat in detail.TeamStats.Take(compact ? 5 : 16))
        {
            var row = RallyUi.Columns(3, 8);
            var away = RallyUi.Text(stat.AwayValue, 12, false, true); var label = RallyUi.Text(stat.Label, 11, true); label.TextAlignment = TextAlignment.Center; label.HorizontalAlignment = HorizontalAlignment.Stretch;
            var home = RallyUi.Text(stat.HomeValue, 12, false, true); home.TextAlignment = TextAlignment.Right; home.HorizontalAlignment = HorizontalAlignment.Stretch;
            RallyUi.Put(row, away, 0); RallyUi.Put(row, label, 1); RallyUi.Put(row, home, 2); teamStats.Children.Add(row);
        }
        if (detail.TeamStats.Count == 0) teamStats.Children.Add(RallyUi.Text("Stats are not available yet.", 12, true));
        body.Children.Add(teamStats);
        if (detail.Context?.HomeWinProbability is double probability)
            body.Children.Add(RallyUi.Column(RallyUi.Text("Win Probability", 13, false, true), RallyUi.Text($"{ev.AwayTeam?.Abbreviation} {(1 - probability):P0}   ·   {ev.HomeTeam?.Abbreviation} {probability:P0}", 12), RallyUi.Text(compact ? "" : detail.Context.PredictionLabel ?? "ESPN", 10, true)));
        if (!string.IsNullOrEmpty(detail.Context?.Situation) || !string.IsNullOrEmpty(detail.Context?.Drive))
            body.Children.Add(RallyUi.Column(RallyUi.Text("Current Drive", 13, false, true), RallyUi.Text(string.Join(" · ", new[] { detail.Context?.Situation, detail.Context?.Drive }.Where(x => !string.IsNullOrWhiteSpace(x))), 11, true)));
        var latest = detail.Plays.Take(compact ? 1 : 4).ToList();
        if (latest.Count > 0) body.Children.Add(Plays(latest, "Latest Plays", 11));
        return body;
    }
    public static UIElement Plays(IEnumerable<GamePlay> plays, string title = "Play by Play", double size = 13)
    {
        var body = RallyUi.Column(RallyUi.Text(title, 15, false, true));
        foreach (var play in plays)
        {
            var metadata = $"{(play.Period > 0 ? $"Period {play.Period}" : "")} · {play.Clock}";
            var text = RallyUi.Text(play.Text, size); text.MaxLines = 4;
            body.Children.Add(RallyUi.Column(RallyUi.Text(metadata.Trim(' ', '·'), 10, true), text));
        }
        if (body.Children.Count == 1) body.Children.Add(RallyUi.Text("Play-by-play will appear when reported for this game.", 13, true));
        return body;
    }
    public static UIElement Players(GameDetail detail)
    {
        var body = new StackPanel { Spacing = 20 };
        foreach (var group in GamePlayers.Merge(detail.PlayerTables).GroupBy(p => p.TeamId))
        {
            var first = group.First(); body.Children.Add(RallyUi.Row(RallyUi.Image(first.TeamLogoUrl, 30, 30), RallyUi.Text(first.TeamName, 16, false, true)));
            foreach (var player in group)
            {
                var stats = string.Join("   ·   ", player.Stats.Select(s => $"{s.Key}: {s.Value}"));
                var text = RallyUi.Column(RallyUi.Text($"{player.Name}  {player.Position} #{player.Jersey}", 13, false, true), RallyUi.Text(stats, 11, true)); text.Spacing = 4;
                var row = RallyUi.Columns(2, 10); row.ColumnDefinitions[0].Width = new GridLength(40); RallyUi.Put(row, RallyUi.Image(player.HeadshotUrl, 40, 40), 0); RallyUi.Put(row, text, 1); body.Children.Add(row);
            }
        }
        if (body.Children.Count == 0) body.Children.Add(RallyUi.Empty("Players are not reported yet", "The game’s player statistics will appear here when available."));
        return body;
    }
    public static UIElement Sources(IEnumerable<PlayCandidate> sources, Action<PlayCandidate> play)
    {
        var body = new StackPanel { Spacing = 10 };
        foreach (var source in sources)
        {
            var text = RallyUi.Column(RallyUi.Text(source.Title, 13, false, true), RallyUi.Text($"{source.AddonName ?? "Live TV"} · {(source.ExactMatch ? "Exact matchup" : source.MatchEvidence ?? "Channel match")}", 11, true));
            var button = RallyUi.Tile(text, source.Title, () => play(source), true); button.Padding = new Thickness(12); body.Children.Add(button);
        }
        if (body.Children.Count == 0) body.Children.Add(RallyUi.Empty("No sources found", "Configure an addon, playlist, or IPTV provider in Settings.", "Open Settings", () => App.Window?.NavigateTo("settings")));
        return body;
    }
    public static UIElement ScoreBug(SportEvent ev)
    {
        var row = RallyUi.Row(); row.Spacing = 20; row.HorizontalAlignment = HorizontalAlignment.Center; row.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(RallyUi.Image(ev.AwayTeam?.LogoUrl, 48, 40)); row.Children.Add(RallyUi.Text(ev.AwayTeam?.Abbreviation ?? "", 15, false, true));
        row.Children.Add(RallyUi.Text(ev.ScoreAway?.ToString() ?? "—", 34, false, true));
        var status = RallyUi.Text(RallyUi.Status(ev), 13, false, true); status.TextAlignment = TextAlignment.Center; status.HorizontalAlignment = HorizontalAlignment.Center;
        if (ev.Status is EventStatus.Live or EventStatus.Halftime) status.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 60, 65));
        var clock = RallyUi.Text(ev.GameStatusDetail ?? ev.StartTime.LocalDateTime.ToString("h:mm tt"), 12, true); clock.TextAlignment = TextAlignment.Center; clock.HorizontalAlignment = HorizontalAlignment.Center;
        row.Children.Add(RallyUi.Column(status, clock)); row.Children.Add(RallyUi.Text(ev.ScoreHome?.ToString() ?? "—", 34, false, true));
        row.Children.Add(RallyUi.Text(ev.HomeTeam?.Abbreviation ?? "", 15, false, true)); row.Children.Add(RallyUi.Image(ev.HomeTeam?.LogoUrl, 48, 40)); return row;
    }
}
