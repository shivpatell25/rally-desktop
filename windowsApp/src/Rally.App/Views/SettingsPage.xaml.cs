using System.Text.RegularExpressions;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Services;
using Rally.Core;

namespace Rally.App.Views;

public sealed partial class SettingsPage : Page
{
    private static readonly Regex MacPattern = new(@"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$");

    private readonly SettingsStore _settings = new();
    private readonly StalkerClient _stalker;
    private readonly XtreamClient _xtream;
    private readonly UpdateService _updates = new();

    public SettingsPage()
    {
        InitializeComponent();
        var http = new HttpClient();
        _stalker = new StalkerClient(http, _settings);
        _xtream = new XtreamClient(http, _settings);
        Provider.SelectedIndex = _settings.IptvProvider == IptvProvider.Xtream ? 1 : 0;
        PortalUrl.Text = _settings.PortalUrl;
        MacAddress.Text = _settings.MacAddress;
        XtreamServer.Text = _settings.XtreamServerUrl;
        XtreamUser.Text = _settings.XtreamUsername;
        XtreamPass.Password = _settings.XtreamPassword;
        Addons.Text = string.Join("\n", _settings.StremioAddonUrls);
        TeamLeague.ItemsSource = EspnClient.Leagues.Select(l => l.League).ToList();
        TeamLeague.SelectedIndex = 0;
        LiveAlerts.IsOn = _settings.LiveGameAlertsEnabled;
        RedZoneAlerts.IsOn = _settings.RedZoneAlertsEnabled;
        LowLatency.IsOn = _settings.LowLatencyMode;
        AdaptiveQuality.IsOn = _settings.AdaptiveQualityEnabled;
        AudioNormalization.IsOn = _settings.AudioNormalizationEnabled;
        ReducedMotion.IsOn = _settings.ReducedMotion;
        LargeText.IsOn = _settings.LargeText;
        VersionText.Text = $"Rally {RallyInfo.CurrentVersion}";
        RefreshFavorites();
    }

    private void Save_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        // Validation before persisting.
        var portal = PortalUrl.Text.Trim();
        if (portal.Length > 0 && !MacPattern.IsMatch(MacAddress.Text.Trim()))
        {
            Status.Text = "Portal set but MAC address is not XX:XX:XX:XX:XX:XX";
            return;
        }
        var xtreamServer = XtreamServer.Text.Trim();
        var xtreamUser = XtreamUser.Text.Trim();
        var xtreamPass = XtreamPass.Password;
        bool anyXtream = xtreamServer.Length > 0 || xtreamUser.Length > 0 || xtreamPass.Length > 0;
        if (anyXtream && (xtreamServer.Length == 0 || xtreamUser.Length == 0 || xtreamPass.Length == 0 ||
            UrlNormalizer.NormalizeXtreamServer(xtreamServer).Length == 0))
        {
            Status.Text = "Xtream needs server URL, username, and password together";
            return;
        }
        var addonLines = Addons.Text.Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
        var badAddon = addonLines.FirstOrDefault(u => UrlNormalizer.NormalizeAddon(u) is null);
        if (badAddon is not null)
        {
            Status.Text = $"Invalid addon URL: {badAddon}";
            return;
        }

        // Credential change clears the provider token + channel cache identity so
        // stale auth can never be reused against the new endpoint.
        var portalChanged = !string.Equals(
            UrlNormalizer.NormalizePortal(portal), _settings.PortalUrl, StringComparison.Ordinal);
        var xtreamChanged = !string.Equals(xtreamServer, _settings.XtreamServerUrl, StringComparison.Ordinal) ||
            !string.Equals(xtreamUser, _settings.XtreamUsername, StringComparison.Ordinal);
        var note = "";
        if (portalChanged || xtreamChanged)
        {
            _settings.AuthToken = "";
            _settings.ChannelCacheIdentity = "";
            note = " Credentials changed — signed out, please Test connection.";
        }

        _settings.IptvProvider = (Provider.SelectedItem as ComboBoxItem)?.Tag as string == "Xtream"
            ? IptvProvider.Xtream : IptvProvider.Stalker;
        _settings.PortalUrl = portal;
        _settings.XtreamServerUrl = xtreamServer;
        _settings.XtreamUsername = xtreamUser;
        _settings.XtreamPassword = xtreamPass;
        _settings.StremioAddonUrls = addonLines;
        _settings.SetupComplete = true;
        Status.Text = "Saved." + note;
    }

    private async void Test_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        Status.Text = "Testing…";
        Save_Click(sender, e);
        try
        {
            var ok = _settings.IptvProvider == IptvProvider.Stalker
                ? await _stalker.AuthenticateAsync(true).ConfigureAwait(false)
                : await _xtream.AuthenticateAsync().ConfigureAwait(false);
            Status.Text = ok ? "Connected" : "Failed — check URL and credentials";
        }
        catch { Status.Text = "Failed — check URL and credentials"; }
    }

    private void RefreshFavorites() =>
        FavoritesList.ItemsSource = _settings.FavoriteTeamProfiles.ToList();

    private async void AddTeam_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        var league = TeamLeague.SelectedItem as string ?? "";
        var name = TeamName.Text.Trim();
        if (league.Length == 0 || name.Length == 0)
        {
            TeamsStatus.Text = "Pick a league and type a team name";
            return;
        }
        TeamsStatus.Text = "Looking up…";
        try
        {
            var meta = EspnClient.Leagues.First(l => l.League == league);
            var detail = new EspnDetail(new HttpClient());
            var rows = await detail.FetchStandingsAsync(meta.Sport, meta.Path).ConfigureAwait(false);
            var match = rows.FirstOrDefault(r =>
                r.TeamName.Equals(name, StringComparison.OrdinalIgnoreCase) ||
                r.TeamName.Contains(name, StringComparison.OrdinalIgnoreCase) ||
                r.Abbreviation.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (match is null)
            {
                TeamsStatus.Text = $"No team matching '{name}' in {league}";
                return;
            }
            var added = _settings.ToggleFavoriteTeam(
                new FavoriteTeam(match.TeamId, league, match.TeamName, match.Abbreviation, match.LogoUrl));
            TeamsStatus.Text = added ? $"Added {match.TeamName}" : $"Removed {match.TeamName}";
            TeamName.Text = "";
            RefreshFavorites();
        }
        catch { TeamsStatus.Text = "Lookup failed — check connection and retry"; }
    }

    private void RemoveTeam_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        var key = (sender as Microsoft.UI.Xaml.Controls.Button)?.Tag as string;
        if (key is null) return;
        var current = _settings.FavoriteTeamProfiles;
        current.RemoveAll(t => t.Key == key);
        _settings.FavoriteTeamProfiles = current;
        RefreshFavorites();
    }

    private void Alerts_Toggled(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _settings.LiveGameAlertsEnabled = LiveAlerts.IsOn;
        _settings.RedZoneAlertsEnabled = RedZoneAlerts.IsOn;
    }

    private void Viewing_Toggled(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _settings.LowLatencyMode = LowLatency.IsOn;
        _settings.AdaptiveQualityEnabled = AdaptiveQuality.IsOn;
        _settings.AudioNormalizationEnabled = AudioNormalization.IsOn;
        _settings.ReducedMotion = ReducedMotion.IsOn;
        _settings.LargeText = LargeText.IsOn;
    }

    private async void CheckUpdates_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        UpdateStatus.Text = "Checking…";
        UpdateNotes.Text = "";
        try
        {
            var release = await _updates.CheckAsync().ConfigureAwait(false);
            if (release is null)
            {
                UpdateStatus.Text = $"You're up to date ({RallyInfo.CurrentVersion})";
                return;
            }
            var size = release.AssetSize is long bytes ? $" ({bytes / 1_048_576} MB)" : "";
            UpdateStatus.Text = $"Update available: {release.Tag}{size} — opening download…";
            UpdateNotes.Text = release.Notes ?? "";
            await _updates.OpenReleaseAsync(release).ConfigureAwait(false);
        }
        catch { UpdateStatus.Text = "Update check failed — retry later"; }
    }

    private void ClearCredentials_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _settings.AuthToken = "";
        _settings.XtreamPassword = "";
        _settings.ChannelCacheIdentity = "";
        XtreamPass.Password = "";
        Status.Text = "Credentials cleared — Test connection after re-entering them";
    }
}
