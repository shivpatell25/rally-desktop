using Rally.Core;
namespace Rally.Tests;
public sealed class WindowsStabilizationTests
{
    [Fact]
    public void AddonTokensAreExcludedFromPlainPreferencesAndPortableBackups()
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var settings = new SettingsStore(folder); settings.StremioAddonUrls = ["https://example.com/private-token/manifest.json"];
        Assert.DoesNotContain("private-token", File.ReadAllText(Path.Combine(folder, "settings.json")));
        Assert.DoesNotContain("private-token", settings.ExportPreferences());
        Assert.Single(new SettingsStore(folder).StremioAddonUrls);
        settings.StremioAddonUrls = []; Assert.Empty(new SettingsStore(folder).StremioAddonUrls);
    }
    [Fact]
    public void FinalStatusDoesNotMakeRegularSeasonGamePostseason()
    {
        var game = new SportEvent("1", "Chiefs vs Ravens", null, null, DateTimeOffset.Now, EventStatus.Finished, 24, 20, "football", "NFL", GameStatusDetail: "Final");
        Assert.False(LeagueHub.IsPostseason(game)); Assert.True(LeagueHub.IsPostseason(game with { Name = "AFC Conference Championship" }));
        Assert.Equal(14, LeagueHub.Cutoff("NFL"));
    }
}
