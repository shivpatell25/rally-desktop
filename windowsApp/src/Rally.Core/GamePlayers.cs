namespace Rally.Core;

public static class GamePlayers
{
    public static List<GamePlayer> Merge(IEnumerable<PlayerStatTable> tables)
    {
        var players = new Dictionary<string, GamePlayer>(StringComparer.Ordinal);
        foreach (var table in tables)
        foreach (var row in table.Rows ?? [])
        {
            var teamId = table.TeamId ?? table.TeamAbbreviation;
            var id = $"{teamId}:{row.Id ?? row.DisplayName.ToLowerInvariant()}";
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            if (players.TryGetValue(id, out var previous))
                foreach (var pair in previous.Stats) values[pair.Key] = pair.Value;
            for (var i = 0; i < (row.Stats?.Count ?? 0); i++)
            {
                var label = table.Labels?.ElementAtOrDefault(i) ?? $"Stat {i + 1}";
                var key = string.IsNullOrWhiteSpace(table.Category) ? label : $"{table.Category} · {label}";
                values[key] = row.Stats![i];
            }
            players[id] = new GamePlayer(id, teamId, table.TeamName, table.TeamAbbreviation,
                table.TeamLogoUrl, row.DisplayName, row.Position ?? previous?.Position,
                row.Jersey ?? previous?.Jersey, row.HeadshotUrl ?? previous?.HeadshotUrl, values);
        }
        return players.Values.OrderBy(p => p.TeamAbbreviation).ThenBy(p => p.Name).ToList();
    }

    public static List<SportEvent> MultiViewGames(IEnumerable<SportEvent> selected,
        IEnumerable<SportEvent> dailyEvents, bool includesRedZone, DateTimeOffset now)
    {
        var events = selected;
        if (includesRedZone)
            events = events.Concat(dailyEvents.Where(e => e.League == "NFL" &&
                e.StartTime.LocalDateTime.Date == now.LocalDateTime.Date && e.Status != EventStatus.Canceled));
        return events.DistinctBy(e => $"{e.League}:{e.Id}").OrderBy(e => e.StartTime).ToList();
    }
}
