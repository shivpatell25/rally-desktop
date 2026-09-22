using Microsoft.UI.Xaml;
using Rally.App.Views;
using Rally.Core;

namespace Rally.App;

public partial class App : Application
{
    public static MainWindow? Window { get; private set; }

    private readonly SettingsStore _settings = new();

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Window = new MainWindow();
        TryRegisterProtocol();
        // First-run gate (mirrors Android startDest gating): fresh installs land on
        // onboarding until sources are saved. Specified as
        // !SetupComplete && !HasCredentials; in practice StremioAddonUrls falls back
        // to SettingsStore.DefaultAddon so HasCredentials already reads true pre-setup —
        // SetupComplete is the operative first-run signal.
        if (!_settings.SetupComplete)
        {
            Window.NavigateTo("onboarding");
            Window.SelectNavItem(null);
        }
        HandleProtocolLaunch(Window);
        Window.Activate();
    }

    // rally:// protocol: rally://event/{id} -> EventDetailPage (event resolved by
    // id via FetchAllAsync); rally://player/{channelId} -> PlayerPage with the
    // IptvChannel direct (no synthetic events per nav contract; PlayerPage's
    // IptvChannel branch is owned by PlayerOwner).
    private static void HandleProtocolLaunch(MainWindow window)
    {
        string? link = null;
        foreach (var arg in Environment.GetCommandLineArgs())
        {
            if (arg.StartsWith("rally://", StringComparison.OrdinalIgnoreCase)) { link = arg; break; }
        }
        if (link is null) return;
        _ = HandleProtocolLinkAsync(window, link);
    }

    private static async Task HandleProtocolLinkAsync(MainWindow window, string link)
    {
        try
        {
            var path = link["rally://".Length..].Trim('/').Split('/', 2);
            if (path.Length != 2) return;
            if (path[0].Equals("event", StringComparison.OrdinalIgnoreCase))
            {
                var id = Uri.UnescapeDataString(path[1]);
                var espn = new EspnClient(new HttpClient());
                var ev = (await espn.FetchAllAsync().ConfigureAwait(false))
                    .FirstOrDefault(e => e.Id == id);
                if (ev is null) return;
                window.DispatcherQueue.TryEnqueue(() =>
                {
                    // EventDetailPage (Rally.App.Views, SportEvent param) is sibling-owned;
                    // fall back to PlayerPage (SportEvent branch) if it hasn't landed yet.
                    var t = typeof(MainWindow).Assembly.GetType("Rally.App.Views.EventDetailPage")
                        ?? typeof(PlayerPage);
                    window.Navigate(t, ev);
                });
            }
            else if (path[0].Equals("player", StringComparison.OrdinalIgnoreCase))
            {
                var channelId = Uri.UnescapeDataString(path[1]);
                var channel = new IptvChannel(channelId, "", channelId);
                window.DispatcherQueue.TryEnqueue(() => window.Navigate(typeof(PlayerPage), channel));
            }
        }
        catch { /* malformed deep link: stay on launch content */ }
    }

    // Protocol registration for unpackaged apps needs an HKCU\Software\Classes\rally
    // URL-protocol key (side-load step: the installer or first run writes it; the
    // MSIX path would declare the protocol in Package.appxmanifest instead).
    // Best-effort only: failure is non-fatal.
    private static void TryRegisterProtocol()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Classes\rally");
            key.SetValue("", "URL:Rally Protocol");
            key.SetValue("URL Protocol", "");
            using var cmd = key.CreateSubKey(@"shell\open\command");
            cmd.SetValue("", $"\"{exe}\" \"%1\"");
        }
        catch { /* registry unavailable (policy/redirection): protocol links just won't route */ }
    }
}
