using Microsoft.UI.Xaml.Controls;
using Rally.Core;

namespace Rally.App.Views;

public sealed partial class SettingsPage : Page
{
    private readonly SettingsStore _settings = new();
    private readonly StalkerClient _stalker;
    private readonly XtreamClient _xtream;

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
    }

    private void Save_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _settings.IptvProvider = (Provider.SelectedItem as ComboBoxItem)?.Tag as string == "Xtream"
            ? IptvProvider.Xtream : IptvProvider.Stalker;
        _settings.PortalUrl = PortalUrl.Text;
        _settings.XtreamServerUrl = XtreamServer.Text;
        _settings.XtreamUsername = XtreamUser.Text;
        _settings.XtreamPassword = XtreamPass.Password;
        _settings.StremioAddonUrls = Addons.Text.Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
        _settings.SetupComplete = true;
        Status.Text = "Saved";
    }

    private async void Test_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        Status.Text = "Testing…";
        Save_Click(sender, e);
        var ok = _settings.IptvProvider == IptvProvider.Stalker
            ? await _stalker.AuthenticateAsync(true)
            : await _xtream.AuthenticateAsync();
        Status.Text = ok ? "Connected" : "Failed — check URL and credentials";
    }
}
