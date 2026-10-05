namespace Rally.Core;
public static class LeagueHub
{
    private static readonly string[] PlayoffWords = ["playoff", "wild card", "divisional", "conference championship", "championship", "finals", "postseason", "super bowl"];
    public static bool IsPostseason(SportEvent game) => PlayoffWords.Any(word => string.Join(" ", new[] { game.Name, game.GameStatusDetail ?? "" }.Concat(game.Broadcasts ?? [])).Contains(word, StringComparison.OrdinalIgnoreCase));
    public static int Cutoff(string league) => league switch { "NFL" => 14, "NBA" or "NHL" => 16, "MLB" => 12, _ => 8 };
}
