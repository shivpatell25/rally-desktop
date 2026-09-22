using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Views;

namespace Rally.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        ContentFrame.Navigate(typeof(HomePage));
        Nav.SelectedItem = Nav.MenuItems[0];
    }

    /// <summary>Shell-level navigation by nav-item tag. Search/highlights and all
    /// sibling pages take no param from the shell (detail pages get params from
    /// their own callers: EventDetailPage + SportEvent, TeamHubPage + FavoriteTeam,
    /// LeagueCenterPage + string league, MultiViewPage + List{SportEvent},
    /// PlayerPage + SportEvent/IptvChannel/string URL).</summary>
    public void NavigateTo(string tag)
    {
        switch (tag)
        {
            case "home": ContentFrame.Navigate(typeof(HomePage)); break;
            case "multi": ContentFrame.Navigate(typeof(MultiViewPage)); break;
            case "settings": ContentFrame.Navigate(typeof(SettingsPage)); break;
            case "onboarding": ContentFrame.Navigate(typeof(OnboardingPage)); break;
            default: NavigateSibling(tag); break;
        }
    }

    /// <summary>Direct type navigation for deep links (App.xaml.cs).</summary>
    public void Navigate(Type pageType, object? param = null) => ContentFrame.Navigate(pageType, param);

    /// <summary>Selects the nav item matching tag (null clears selection, e.g. onboarding).</summary>
    public void SelectNavItem(string? tag)
    {
        foreach (var item in Nav.MenuItems.OfType<NavigationViewItem>())
        {
            if ((item.Tag as string) == tag) { Nav.SelectedItem = item; return; }
        }
        Nav.SelectedItem = null;
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var tag = (args.SelectedItem as NavigationViewItem)?.Tag as string;
        if (tag is not null) NavigateTo(tag);
    }

    // Sibling-owned pages (LiveTv, Leagues, SearchHighlights, Teams agents) resolve
    // by name so the shell compiles and runs before/after they land; once landed
    // the exact agreed types below are found via the app assembly.
    private void NavigateSibling(string tag)
    {
        string[] candidates = tag switch
        {
            "live" => ["LiveTvPage"],
            "leagues" => ["LeaguesPage"],
            "highlights" => ["HighlightsPage"],
            "myteams" => ["MyTeamsPage"],
            "search" => ["SearchPage"],
            _ => [],
        };
        var asm = typeof(MainWindow).Assembly;
        foreach (var name in candidates)
        {
            var t = asm.GetType($"Rally.App.Views.{name}");
            if (t is not null) { ContentFrame.Navigate(t); return; }
        }
        System.Diagnostics.Debug.WriteLine($"[Rally] nav target '{tag}' not available yet.");
    }
}
