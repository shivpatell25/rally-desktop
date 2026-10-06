using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Design;
namespace Rally.App.Views;
public sealed partial class LeaguesPage : Page
{
    public LeaguesPage()
    {
        InitializeComponent(); var state = new PageState(this); var leagues = Rally.Core.EspnClient.Leagues.Select(l => l.League).Prepend("Soccer").Distinct().ToList();
        var grid = RallyUi.Flow(leagues.Select(league => (UIElement)RallyUi.SportTile(league, () => PageState.Go(typeof(LeagueCenterPage), league))).ToArray());
        state.Root.Children.Add(RallyUi.Scroll(RallyUi.Column(RallyUi.Heading("Leagues"), grid)));
    }
}
