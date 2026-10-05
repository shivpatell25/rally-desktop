using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class HighlightsPage : Page
{
    private readonly PageState _state;
    public HighlightsPage() { InitializeComponent(); _state = new(this); }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        await _state.Load(async ct =>
        {
            var games = (await App.Data.GamesAsync(ct: ct)).Where(g => g.Status is EventStatus.Finished or EventStatus.Live).OrderByDescending(g => g.StartTime).Take(20);
            var details = await Task.WhenAll(games.Select(g => App.Data.DetailAsync(g, ct: ct))); var clips = details.SelectMany(d => d.Clips).DistinctBy(c => c.Id).ToList();
            var grid = RallyUi.Columns(3, 18); grid.RowSpacing = 26;
            for (var i = 0; i < clips.Count; i++) { if (i % 3 == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); RallyUi.Put(grid, HomePage.ClipCard(clips[i]), i % 3, i / 3); }
            var body = RallyUi.Column(RallyUi.Heading("Highlights"), grid); if (clips.Count == 0) body.Children.Add(RallyUi.Empty("No highlights are available yet", "New game clips will appear here when published.", "View Schedule", () => App.Window?.NavigateTo("schedule"))); return RallyUi.Scroll(body);
        });
    }
}
