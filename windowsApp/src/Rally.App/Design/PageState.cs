using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.Core;

namespace Rally.App.Design;

public sealed class PageState
{
    private readonly Page _page;
    private CancellationTokenSource _cancel = new();
    public CancellationToken Token => _cancel.Token;
    public Grid Root { get; } = new() { Padding = new Thickness(54, 8, 54, 20) };
    public PageState(Page page)
    {
        _page = page; page.Content = Root;
        page.Unloaded += (_, _) => _cancel.Cancel();
        page.Loaded += (_, _) => { if (_cancel.IsCancellationRequested) { _cancel.Dispose(); _cancel = new(); } };
        page.SizeChanged += (_, args) => Root.Padding = new Thickness(args.NewSize.Width < 1000 ? 28 : 54, 8, args.NewSize.Width < 1000 ? 28 : 54, 20);
    }
    public void Activate() { if (_cancel.IsCancellationRequested) { _cancel.Dispose(); _cancel = new(); } }
    public async Task Load(Func<CancellationToken, Task<UIElement>> loader)
    {
        if (_cancel.IsCancellationRequested) { _cancel.Dispose(); _cancel = new(); }
        var token = Token; Root.Children.Clear(); Root.Children.Add(new ProgressRing { IsActive = true, Width = 32, Height = 32 });
        try { var content = await loader(token); if (token.IsCancellationRequested) return; Root.Children.Clear(); Root.Children.Add(content); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { if (!token.IsCancellationRequested) { Root.Children.Clear(); Root.Children.Add(RallyUi.Empty("Couldn't load this screen", "Check your connection, then try again.", "Retry", () => _ = Load(loader))); } }
    }
    public static void Go(Type page, object? param = null) => App.Window?.Navigate(page, param);
    public static void Watch(SportEvent ev) => Go(typeof(Views.GameViewPage), ev);
    public static void Event(SportEvent ev) => Go(typeof(Views.EventDetailPage), ev);
    public static UIElement Events(IEnumerable<SportEvent> events, bool hideScore = false)
    {
        var wrap = new Grid { ColumnSpacing = 18, RowSpacing = 26 };
        for (var i = 0; i < 3; i++) wrap.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var index = 0; foreach (var ev in events)
        {
            if (index % 3 == 0) wrap.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            RallyUi.Put(wrap, RallyUi.EventCard(ev, () => Event(ev), hideScore), index % 3, index / 3); index++;
        }
        return wrap;
    }
}
