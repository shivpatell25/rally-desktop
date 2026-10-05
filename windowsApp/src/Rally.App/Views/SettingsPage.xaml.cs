using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Design;
using Rally.App.Services;
using Rally.Core;
using Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;
namespace Rally.App.Views;
public sealed partial class SettingsPage : Page
{
    private readonly PageState _state;
    private readonly SettingsStore _settings = App.Data.Settings;
    private readonly StackPanel _detail = new() { Spacing = 20, MaxWidth = 780, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly TextBlock _status = RallyUi.Text("", 13, true);
    public SettingsPage()
    {
        InitializeComponent(); _state = new(this); var layout = new Grid { ColumnSpacing = 32 };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) }); layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var menu = new StackPanel { Spacing = 8 };
        foreach (var title in new[] { "Sources", "Playback", "Appearance", "Notifications", "Your Teams", "App & About" }) menu.Children.Add(RallyUi.Button(title, () => Show(title)));
        RallyUi.Put(layout, menu, 0); RallyUi.Put(layout, RallyUi.Scroll(_detail), 1); _state.Root.Children.Add(layout); Show("Sources");
    }
    private void Show(string section)
    {
        _detail.Children.Clear(); _status.Text = ""; _detail.Children.Add(RallyUi.Heading(section));
        if (section == "Sources") Sources();
        else if (section == "Playback")
        {
            Toggle("Low Latency", "Use a shorter stream buffer. Less resilient to slow connections.", _settings.LowLatencyMode, v => _settings.LowLatencyMode = v);
            Toggle("Adaptive Source Quality", "Prefer verified sources using playback history.", _settings.AdaptiveQualityEnabled, v => _settings.AdaptiveQualityEnabled = v);
            Toggle("Normalize Audio", "Keep volume differences between sources smaller.", _settings.AudioNormalizationEnabled, v => _settings.AudioNormalizationEnabled = v);
            Toggle("Follow Focused Audio", "In multiview, listen to the stream selected with the keyboard.", _settings.FollowFocusedAudio, v => _settings.FollowFocusedAudio = v);
        }
        else if (section == "Appearance")
        {
            Toggle("Reduced Motion", "Keep focus and screen transitions immediate.", _settings.ReducedMotion, v => _settings.ReducedMotion = v);
            Toggle("Larger Text", "Increase interface text for easier reading. Reopen a screen to apply.", _settings.LargeText, v => _settings.LargeText = v);
            Toggle("High Contrast Focus", "Use brighter keyboard focus edges.", _settings.HighContrastFocus, v => _settings.HighContrastFocus = v);
            Toggle("Spoken Score Summaries", "Announce the live scores when opening Home.", _settings.SpokenScoreSummaries, v => _settings.SpokenScoreSummaries = v);
            Toggle("Score Saver", "Show ambient scores after five idle minutes.", _settings.ScoreSaverEnabled, v => _settings.ScoreSaverEnabled = v);
            _detail.Children.Add(RallyUi.Text("Sports on Home", 16, false, true));
            foreach (var league in HomePage.HomeSports())
            {
                var check = new CheckBox { Content = league, IsChecked = !_settings.DisabledLeagues.Contains(league) };
                check.Click += (_, _) => { var disabled = _settings.DisabledLeagues; if (check.IsChecked == true) disabled.Remove(league); else if (!disabled.Contains(league)) disabled.Add(league); _settings.DisabledLeagues = disabled; };
                var up = RallyUi.Button("↑", () => MoveSport(league, -1)); var down = RallyUi.Button("↓", () => MoveSport(league, 1));
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(up, $"Move {league} earlier"); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(down, $"Move {league} later");
                _detail.Children.Add(RallyUi.Row(check, up, down));
            }
        }
        else if (section == "Notifications")
        {
            Toggle("Team Game Alerts", "Windows notifications for kickoff, scores and finals from teams you follow.", _settings.LiveGameAlertsEnabled, v => _settings.LiveGameAlertsEnabled = v);
            Toggle("RedZone Alerts", "Scoring alerts while RedZone is selected in multiview.", _settings.RedZoneAlertsEnabled, v => _settings.RedZoneAlertsEnabled = v);
            _detail.Children.Add(RallyUi.Text("Notification delivery follows Windows Focus Assist and your system notification settings.", 13, true));
        }
        else if (section == "Your Teams") Teams();
        else About();
        _detail.Children.Add(_status);
    }
    private void MoveSport(string league, int offset)
    {
        var order = HomePage.HomeSports().ToList(); var current = order.IndexOf(league); var target = current + offset;
        if (current < 0 || target < 0 || target >= order.Count) return; (order[current], order[target]) = (order[target], order[current]); _settings.SportsOrder = order; Show("Appearance");
    }
    private void Toggle(string title, string description, bool value, Action<bool> save)
    {
        var toggle = new ToggleSwitch { Header = title, IsOn = value }; toggle.Toggled += (_, _) => save(toggle.IsOn);
        _detail.Children.Add(RallyUi.Column(toggle, RallyUi.Text(description, 12, true)));
    }
    private static TextBox Field(string label, string value, bool multiline = false) => new() { Header = label, Text = value, MinWidth = 420, AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, MinHeight = multiline ? 100 : 0 };
    private void Sources()
    {
        _detail.Children.Add(RallyUi.Text("Streaming Addons", 17, false, true));
        var addons = Field("Stremio manifest URLs — one per line", string.Join("\n", _settings.StremioAddonUrls), true);
        _detail.Children.Add(addons);
        _detail.Children.Add(RallyUi.Button("Save Addons", () =>
        {
            var urls = addons.Text.Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
            if (urls.Any(u => UrlNormalizer.NormalizeAddon(u) is null)) { _status.Text = "Check the addon URLs."; return; }
            _settings.StremioAddonUrls = urls; _settings.SetupComplete = true; App.Data.Addons.Invalidate(); _status.Text = "Addons saved.";
        }));
        _detail.Children.Add(RallyUi.Text("Live TV Provider", 17, false, true));
        var provider = new ComboBox { Header = "Provider", ItemsSource = new[] { "Stalker / Ministra", "Xtream Codes", "M3U / M3U8" }, SelectedIndex = (int)_settings.IptvProvider, Width = 420 };
        var fields = new StackPanel { Spacing = 16 }; _detail.Children.Add(provider); _detail.Children.Add(fields);
        void ProviderFields()
        {
            fields.Children.Clear();
            var kind = (IptvProvider)provider.SelectedIndex;
            var portal = Field("Portal URL", _settings.PortalUrl); var mac = Field("MAC Address", _settings.MacAddress);
            var serial = Field("Serial Number (optional)", _settings.SerialNumber); var device = Field("Device ID (optional)", _settings.DeviceId);
            var server = Field("Server URL", _settings.XtreamServerUrl); var user = Field("Username", _settings.XtreamUsername); var password = new PasswordBox { Header = "Password", Password = _settings.XtreamPassword, MinWidth = 420 };
            var playlist = Field("Playlist URL or local file", _settings.M3uUrl); var guide = Field("XMLTV Guide URL or local file (optional)", _settings.XmltvUrl);
            if (kind == IptvProvider.Stalker) foreach (var field in new UIElement[] { portal, mac, serial, device }) fields.Children.Add(field);
            else if (kind == IptvProvider.Xtream) foreach (var field in new UIElement[] { server, user, password }) fields.Children.Add(field);
            else { fields.Children.Add(playlist); fields.Children.Add(RallyUi.Button("Choose Playlist File…", () => _ = ChoosePlaylist(playlist))); fields.Children.Add(guide); }
            bool Save()
            {
                var error = SettingsValidator.Validate(kind, portal.Text, mac.Text, server.Text, user.Text, password.Password, _settings.StremioAddonUrls);
                if (error is not null) { _status.Text = error; return false; }
                if (kind == IptvProvider.M3u && playlist.Text.Trim().Length == 0) { _status.Text = "Enter a playlist URL or choose a file."; return false; }
                _settings.IptvProvider = kind; _settings.PortalUrl = portal.Text; _settings.MacAddress = mac.Text; _settings.SerialNumber = serial.Text; _settings.DeviceId = device.Text;
                _settings.XtreamServerUrl = server.Text; _settings.XtreamUsername = user.Text; _settings.XtreamPassword = password.Password; _settings.M3uUrl = playlist.Text; _settings.XmltvUrl = guide.Text;
                _settings.AuthToken = ""; _settings.ChannelCacheIdentity = ""; _settings.SetupComplete = true; _status.Text = "Provider saved."; return true;
            }
            fields.Children.Add(RallyUi.Row(RallyUi.Button("Save Provider", () => Save()), RallyUi.Button("Save & Test", async () =>
            {
                if (!Save()) return; _status.Text = "Testing connection…";
                try { var channels = await App.Data.ChannelsAsync(true, _state.Token); _status.Text = channels.Count > 0 ? $"Connected · {channels.Count} channels" : "No channels returned. Check the provider details."; }
                catch (OperationCanceledException) { }
                catch { _status.Text = "Connection failed. Check the provider details and network."; }
            })));
        }
        provider.SelectionChanged += (_, _) => ProviderFields(); ProviderFields();
        _detail.Children.Add(RallyUi.Text("Passwords and playlist URLs are encrypted for your Windows account. Addons and providers are supplied by you.", 12, true));
    }
    private async Task ChoosePlaylist(TextBox field)
    {
        var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Window!)); picker.FileTypeFilter.Add(".m3u"); picker.FileTypeFilter.Add(".m3u8");
        var file = await picker.PickSingleFileAsync(); if (file is not null) field.Text = file.Path;
    }
    private void Teams()
    {
        _detail.Children.Add(RallyUi.Button("Browse All Teams", () => App.Window?.NavigateTo("leagues")));
        foreach (var team in _settings.FavoriteTeamProfiles) _detail.Children.Add(RallyUi.Row(RallyUi.Image(team.LogoUrl, 40, 40), RallyUi.Text(team.Name, 15), RallyUi.Button("Unfollow", () => { _settings.ToggleFavoriteTeam(team); Show("Your Teams"); })));
        if (_settings.FavoriteTeamProfiles.Count == 0) _detail.Children.Add(RallyUi.Text("Follow a team from Leagues to personalize My Rally.", 14, true));
    }
    private void About()
    {
        _detail.Children.Add(RallyUi.Asset("rally_wordmark.png", 160, 60));
        _detail.Children.Add(RallyUi.Text($"Rally {RallyInfo.CurrentVersion} · Windows {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}", 16, false, true));
        _detail.Children.Add(RallyUi.Text("Your sports. One place.\nNative Windows playback, live scores, multiview and your teams.", 14, true));
        _detail.Children.Add(RallyUi.Button("Check for Updates", async () => { _status.Text = "Checking…"; var release = await new UpdateService().CheckAsync(); _status.Text = release is null ? "No newer release was returned." : $"{release.Tag} is available."; if (release is not null) _detail.Children.Insert(_detail.Children.Count - 1, RallyUi.Button("Download Update", () => _ = new UpdateService().OpenReleaseAsync(release))); }));
        _detail.Children.Add(RallyUi.Row(RallyUi.Button("Export Preferences…", () => _ = Backup(false)), RallyUi.Button("Import Preferences…", () => _ = Backup(true))));
        _detail.Children.Add(RallyUi.Text("Backups contain preferences, teams and saved games. Credentials are excluded.", 12, true));
        _detail.Children.Add(RallyUi.Button("Copy Support Information", () => { var package = new DataPackage(); package.SetText($"Rally {RallyInfo.CurrentVersion}\n{Environment.OSVersion}\nArchitecture: {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}\nProvider: {_settings.IptvProvider}\nAddons: {_settings.StremioAddonUrls.Count}\n{App.Playback.Diagnostics()}"); Clipboard.SetContent(package); _status.Text = "Support information copied. Credentials are excluded."; }));
        _detail.Children.Add(RallyUi.Button("Clear Cached Sports Data", () => { try { if (Directory.Exists(_settings.CacheDirectory)) Directory.Delete(_settings.CacheDirectory, true); _status.Text = "Cache cleared."; } catch { _status.Text = "Some cached files are in use."; } }));
        _detail.Children.Add(RallyUi.Button("Rally on GitHub ↗", () => _ = Windows.System.Launcher.LaunchUriAsync(new Uri("https://github.com/shivpatell25/rally-desktop"))));
    }
    private async Task Backup(bool import)
    {
        try
        {
            if (import)
            {
                var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Window!)); picker.FileTypeFilter.Add(".json");
                var file = await picker.PickSingleFileAsync(); if (file is null) return; var json = await Windows.Storage.FileIO.ReadTextAsync(file); if (json.Length > 1_000_000) throw new InvalidDataException(); _settings.ImportPreferences(json); _status.Text = "Preferences imported.";
            }
            else
            {
                var picker = new FileSavePicker { SuggestedFileName = "Rally-preferences" }; WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Window!)); picker.FileTypeChoices.Add("JSON", new List<string> { ".json" });
                var file = await picker.PickSaveFileAsync(); if (file is null) return; await Windows.Storage.FileIO.WriteTextAsync(file, _settings.ExportPreferences()); _status.Text = "Preferences exported.";
            }
        }
        catch { _status.Text = "The preferences file couldn't be read or saved."; }
    }
}
