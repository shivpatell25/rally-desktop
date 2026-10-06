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
            var details = await Task.WhenAll(games.Select(async g => { try { return await App.Data.DetailAsync(g, ct: ct); } catch { return GameDetail.Empty; } })); var clips = details.SelectMany(d => d.Clips).DistinctBy(c => c.Id).ToList();
            var grid = RallyUi.Flow(clips.Select(c => (UIElement)HomePage.ClipCard(c)).ToArray());
            var body = RallyUi.Column(RallyUi.Heading("Highlights"), grid); if (clips.Count == 0) body.Children.Add(RallyUi.Empty("No highlights are available yet", "New game clips will appear here when published.", "View Schedule", () => App.Window?.NavigateTo("schedule"))); return RallyUi.Scroll(body);
        });
    }
}
