using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Rally.Core;

namespace Rally.App.Services;

// Poll-on-refresh game alerts for favorite teams + RedZone touchdown toasts.
// Toasts are best-effort: every Show path is inside try/catch so a missing
// notification platform (headless, unregistered, test) silently no-ops.
// HOME HOOK (HomeEvent owner): at the end of HomePage.RefreshAsync, add:
//   await _notifications.CheckAndNotifyAsync(events);
// where events is the refreshed List{SportEvent} (empty list on offline failure
// keeps the previous snapshot intact).
public sealed class AppNotifications(SettingsStore settings)
{
    public sealed record Toast(string Title, string Body);

    private readonly SettingsStore _settings = settings;
    private Dictionary<string, SportEvent> _last = new();
    private bool _registered;

    // Pure transition scan: NOT_STARTED -> LIVE/HALFTIME = kickoff, score change
    // while live = score, anything -> FINISHED = final. Only for events involving
    // a favorite (favIds accepts FavoriteTeam keys "League:Id" or raw team ids).
    public static IReadOnlyList<Toast> Evaluate(
        IReadOnlyList<SportEvent> previous,
        IReadOnlyList<SportEvent> current,
        IReadOnlySet<string> favIds)
    {
        if (favIds.Count == 0) return [];
        var prev = previous.ToDictionary(e => e.Id);
        var out_ = new List<Toast>();
        foreach (var ev in current)
        {
            if (!InvolvesFavorite(ev, favIds)) continue;
            if (!prev.TryGetValue(ev.Id, out var was)) continue;
            var title = Describe(ev);
            if (was.Status == EventStatus.NotStarted &&
                (ev.Status == EventStatus.Live || ev.Status == EventStatus.Halftime))
                out_.Add(new Toast("Kickoff", title));
            else if (ev.Status == EventStatus.Finished && was.Status != EventStatus.Finished)
                out_.Add(new Toast("Final", $"{title}: {ScoreLine(ev)}"));
            else if ((ev.Status == EventStatus.Live || ev.Status == EventStatus.Halftime) &&
                     (was.ScoreHome != ev.ScoreHome || was.ScoreAway != ev.ScoreAway))
                out_.Add(new Toast("Score update", $"{title}: {ScoreLine(ev)}"));
        }
        return out_;
    }

    // Called from HomePage refresh with the latest events; diffs against the last
    // snapshot, toasts, and rolls the snapshot forward. Gated on LiveGameAlertsEnabled.
    public Task CheckAndNotifyAsync(IReadOnlyList<SportEvent> events)
    {
        try
        {
            if (!_settings.LiveGameAlertsEnabled) return Task.CompletedTask;
            if (events.Count == 0) return Task.CompletedTask; // offline: keep snapshot
            var favIds = _settings.FavoriteTeamProfiles.Select(t => t.Key).ToHashSet();
            foreach (var id in _settings.FavoriteTeamProfiles.SelectMany(t => new[] { t.Id })) favIds.Add(id);
            var toasts = Evaluate(_last.Values.ToList(), events, favIds);
            foreach (var toast in toasts) Show(toast.Title, toast.Body, "rally://home");
            _last = events.ToDictionary(e => e.Id);
        }
        catch { /* best-effort */ }
        return Task.CompletedTask;
    }

    public void NotifyRedZoneTouchdown(string channelName)
    {
        try
        {
            if (!_settings.RedZoneAlertsEnabled) return;
            Show("RedZone: touchdown", channelName, "rally://live");
        }
        catch { /* best-effort */ }
    }

    private static bool InvolvesFavorite(SportEvent ev, IReadOnlySet<string> favIds)
    {
        string[] candidates =
        [
            $"{ev.League}:{ev.HomeTeam?.Id}", $"{ev.League}:{ev.AwayTeam?.Id}",
            ev.HomeTeam?.Id ?? "", ev.AwayTeam?.Id ?? "",
        ];
        return candidates.Any(c => c.Length > 0 && favIds.Contains(c));
    }

    private static string Describe(SportEvent ev) =>
        !string.IsNullOrWhiteSpace(ev.Name) ? ev.Name
        : $"{ev.AwayTeam?.Name ?? "?"} at {ev.HomeTeam?.Name ?? "?"}";

    private static string ScoreLine(SportEvent ev) =>
        $"{ev.AwayTeam?.Abbreviation ?? "AWY"} {ev.ScoreAway?.ToString() ?? "-"} – " +
        $"{ev.ScoreHome?.ToString() ?? "-"} {ev.HomeTeam?.Abbreviation ?? "HME"}";

    private void Show(string title, string body, string arguments)
    {
        try
        {
            EnsureRegistered();
            var notification = new AppNotificationBuilder()
                .AddText(title)
                .AddText(body)
                .AddArgument("action", arguments)
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch { /* notification platform unavailable: silent fallback */ }
    }

    private void EnsureRegistered()
    {
        if (_registered) return;
        try
        {
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch { /* unpackaged without registration: Show still attempted, may no-op */ }
    }
}
