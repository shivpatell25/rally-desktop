using System.Text.Json;
using Rally.Core;

namespace Rally.Tests;

public sealed class DesktopContractFixtureTests
{
    private static JsonElement Fixture()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "desktop-contract.json");
        return JsonDocument.Parse(File.ReadAllText(path)).RootElement.Clone();
    }

    [Fact]
    public void SharedDesktopContract()
    {
        var root = Fixture();
        foreach (var row in root.GetProperty("statuses").EnumerateArray())
        {
            var status = row.GetProperty("raw").GetString() switch
            {
                "LIVE" => EventStatus.Live,
                "HALFTIME" => EventStatus.Halftime,
                "NOT_STARTED" => EventStatus.NotStarted,
                "FINISHED" => EventStatus.Finished,
                _ => throw new InvalidDataException("Unknown status fixture"),
            };
            Assert.Equal(row.GetProperty("active").GetBoolean(),
                status is EventStatus.Live or EventStatus.Halftime);
        }

        foreach (var row in root.GetProperty("qualities").EnumerateArray())
        {
            var parsed = Quality.Parse(row.GetProperty("title").GetString()!);
            var resolution = row.GetProperty("resolution");
            Assert.Equal(resolution.ValueKind == JsonValueKind.Null ? null : resolution.GetString(), parsed.Resolution);
            Assert.Equal(row.GetProperty("hdr").GetBoolean(), parsed.IsHdr);
            Assert.Equal(row.GetProperty("rank").GetInt32(), StreamSelector.QualityRank(parsed));
        }

        var headerFixture = root.GetProperty("headers");
        var input = headerFixture.GetProperty("input").EnumerateObject()
            .ToDictionary(p => p.Name, p => p.Value.GetString()!);
        var sanitized = StreamRequestHeaders.Sanitize(input);
        var allowed = headerFixture.GetProperty("allowed").EnumerateArray()
            .Select(v => v.GetString()!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        Assert.True(allowed.SetEquals(sanitized.Keys));

        foreach (var row in root.GetProperty("settings").EnumerateArray())
        {
            var provider = Enum.Parse<IptvProvider>(row.GetProperty("provider").GetString()!, true);
            static string Value(JsonElement e, string name) =>
                e.TryGetProperty(name, out var value) ? value.GetString() ?? "" : "";
            var error = SettingsValidator.Validate(provider, Value(row, "portal"), Value(row, "mac"),
                Value(row, "server"), Value(row, "user"), Value(row, "pass"), []);
            Assert.Equal(row.GetProperty("valid").GetBoolean(), error is null);
        }

        var detail = root.GetProperty("details");
        var labels = detail.GetProperty("labels").EnumerateArray().Select(v => v.GetString()!).ToList();
        var rows = detail.GetProperty("rows").EnumerateArray().Select(row =>
            new PlayerStatRow(row.GetProperty("displayName").GetString()!, Stats: row.GetProperty("stats")
                .EnumerateArray().Select(v => v.GetString()!).ToList())).ToList();
        var table = new PlayerStatTable(null, detail.GetProperty("teamName").GetString()!,
            detail.GetProperty("teamAbbreviation").GetString()!, null,
            detail.GetProperty("category").GetString(), labels, rows);
        Assert.All(table.Rows!, row => Assert.Equal(table.Labels!.Count, row.Stats!.Count));

        foreach (var row in root.GetProperty("health").EnumerateArray())
        {
            var startup = row.GetProperty("startupMs");
            var health = new StreamHealth(row.GetProperty("successes").GetInt32(),
                row.GetProperty("failures").GetInt32(),
                AverageStartupMs: startup.ValueKind == JsonValueKind.Null ? 0 : startup.GetInt64());
            Assert.Equal(row.GetProperty("score").GetInt32(), health.Score);
        }
    }
}
