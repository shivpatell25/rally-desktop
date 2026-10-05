using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Design;
namespace Rally.App.Views;
public sealed partial class OnboardingPage : Page
{
    public OnboardingPage()
    {
        InitializeComponent(); var state = new PageState(this);
        var body = RallyUi.Column(RallyUi.Asset("rally_wordmark.png", 220, 90), RallyUi.Text("Your sports. One place.", 32, false, true), RallyUi.Text("Live games, real-time scores, highlights and multiview.\nConnect your own streaming addon, IPTV provider or playlist to watch.", 17, true), RallyUi.Button("Set Up Sources", () => App.Window?.NavigateTo("settings"), true), RallyUi.Button("Explore Rally", () => { App.Data.Settings.SetupComplete = true; App.Window?.NavigateTo("home"); }));
        body.HorizontalAlignment = HorizontalAlignment.Center; body.VerticalAlignment = VerticalAlignment.Center; body.MaxWidth = 650; body.Spacing = 24; state.Root.Children.Add(body);
    }
}
