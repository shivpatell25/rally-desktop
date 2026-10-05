using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.App.Design;
namespace Rally.App.Views;
public sealed partial class LeaguesPage : Page
{
    public LeaguesPage()
    {
        InitializeComponent(); var state = new PageState(this); var grid = RallyUi.Columns(4, 18); grid.RowSpacing = 18;
        var leagues = Rally.Core.EspnClient.Leagues.Select(l => l.League).Prepend("Soccer").Distinct().ToList();
        for (var i = 0; i < leagues.Count; i++) { if (i % 4 == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); var league = leagues[i]; var card = RallyUi.SportTile(league, () => PageState.Go(typeof(LeagueCenterPage), league)); card.Height = 112; RallyUi.Put(grid, card, i % 4, i / 4); }
        state.Root.Children.Add(RallyUi.Scroll(RallyUi.Column(RallyUi.Heading("Leagues"), grid)));
    }
}
