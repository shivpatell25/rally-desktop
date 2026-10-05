using System.Text.Json;

namespace Rally.Core;

public static class GameData
{
    private static IEnumerable<JsonElement> Array(JsonElement? value) => value?.ValueKind == JsonValueKind.Array ? value.Value.EnumerateArray() : [];
    private static string? Text(JsonElement? value) => value?.ValueKind is JsonValueKind.String ? value.Value.GetString() : value?.ValueKind is JsonValueKind.Number ? value.Value.GetRawText() : null;
    private static int? Integer(JsonElement? value) => int.TryParse(Text(value), out var number) ? number : null;
    public static List<GamePlay> ParsePlays(JsonElement root)
    {
        var entries = Array(root.GetPropertyOrNull("plays")).ToList();
        var drives = root.GetPropertyOrNull("drives");
        foreach (var drive in Array(drives?.GetPropertyOrNull("previous"))) entries.AddRange(Array(drive.GetPropertyOrNull("plays")));
        entries.AddRange(Array(drives?.GetPropertyOrNull("current")?.GetPropertyOrNull("plays")));
        var scoring = Array(root.GetPropertyOrNull("scoringPlays")).ToList();
        entries.AddRange(scoring);
        var scoringIds = scoring.Select(p => Text(p.GetPropertyOrNull("id"))).OfType<string>().ToHashSet();
        return entries.Select((p, index) => new GamePlay(
            Text(p.GetPropertyOrNull("id")) ?? $"{index}:{Text(p.GetPropertyOrNull("text"))}",
            Text(p.GetPropertyOrNull("text")) ?? "", Text(p.GetPropertyOrNull("clock")?.GetPropertyOrNull("displayValue")),
            Integer(p.GetPropertyOrNull("period")?.GetPropertyOrNull("number")) ?? 0,
            Text(p.GetPropertyOrNull("team")?.GetPropertyOrNull("id")),
            p.GetPropertyOrNull("scoringPlay")?.ValueKind == JsonValueKind.True || scoringIds.Contains(Text(p.GetPropertyOrNull("id")) ?? ""),
            Integer(p.GetPropertyOrNull("awayScore")), Integer(p.GetPropertyOrNull("homeScore")),
            Integer(p.GetPropertyOrNull("sequenceNumber")) ?? index))
            .Where(p => p.Text.Length > 0).DistinctBy(p => p.Id).OrderByDescending(p => p.Sequence).ToList();
    }
    public static GameContext ParseContext(JsonElement root)
    {
        var venue = root.GetPropertyOrNull("gameInfo")?.GetPropertyOrNull("venue");
        var address = venue?.GetPropertyOrNull("address");
        var weather = root.GetPropertyOrNull("gameInfo")?.GetPropertyOrNull("weather");
        var competition = Array(root.GetPropertyOrNull("header")?.GetPropertyOrNull("competitions")).FirstOrDefault();
        var situation = competition.GetPropertyOrNull("situation");
        var drive = root.GetPropertyOrNull("drives")?.GetPropertyOrNull("current");
        var predictor = root.GetPropertyOrNull("predictor");
        var home = predictor?.GetPropertyOrNull("homeTeam") ?? predictor?.GetPropertyOrNull("home");
        var prediction = predictor?.GetPropertyOrNull("homeWinPercentage") ?? predictor?.GetPropertyOrNull("homeWinProbability")
            ?? home?.GetPropertyOrNull("winPercent") ?? home?.GetPropertyOrNull("winPercentage") ?? home?.GetPropertyOrNull("chanceToWin");
        double? probability = double.TryParse(Text(prediction), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var p) ? Math.Clamp(p > 1 ? p / 100 : p, 0, 1) : null;
        var liveProbability = Array(root.GetPropertyOrNull("winprobability")).LastOrDefault().GetPropertyOrNull("homeWinPercentage");
        if (double.TryParse(Text(liveProbability), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var live)) probability = Math.Clamp(live > 1 ? live / 100 : live, 0, 1);
        var driveText = string.Join(" · ", new[] { Text(drive?.GetPropertyOrNull("description")),
            Integer(drive?.GetPropertyOrNull("offensivePlays")) is int count ? $"{count} plays" : null,
            Integer(drive?.GetPropertyOrNull("yards")) is int yards ? $"{yards} yards" : null,
            Text(drive?.GetPropertyOrNull("timeElapsed")?.GetPropertyOrNull("displayValue")) }.Where(t => !string.IsNullOrEmpty(t)));
        return new GameContext(Text(venue?.GetPropertyOrNull("fullName")),
            string.Join(", ", new[] { Text(address?.GetPropertyOrNull("city")), Text(address?.GetPropertyOrNull("state")) ?? Text(address?.GetPropertyOrNull("country")) }.Where(t => !string.IsNullOrWhiteSpace(t))),
            Text(Array(venue?.GetPropertyOrNull("images")).FirstOrDefault().GetPropertyOrNull("href")),
            Text(weather?.GetPropertyOrNull("temperature")) is string temp ? $"{temp}°F" : null,
            Text(situation?.GetPropertyOrNull("shortDownDistanceText")) ?? Text(situation?.GetPropertyOrNull("downDistanceText")),
            driveText, probability, liveProbability is null ? "ESPN matchup prediction" : "ESPN live win probability");
    }
}
