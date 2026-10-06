using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Rally.Core;

namespace Rally.App.Design;

public sealed class PageState
{
    private readonly Page _page;
    private CancellationTokenSource _cancel = new();
    private CancellationTokenSource? _load;
    private int _generation;
    private static long InputVersion => App.Window?.InteractionVersion ?? 0;
    public CancellationToken Token => _cancel.Token;
    public Grid Root { get; } = new() { Padding = new Thickness(54, 8, 54, 20) };
    public PageState(Page page)
    {
        _page = page; page.Content = Root;
        page.Unloaded += (_, _) => { _generation++; _load?.Cancel(); _cancel.Cancel(); };
        page.Loaded += (_, _) => App.Window?.RestorePageState(page);
        page.Loaded += (_, _) => { if (_cancel.IsCancellationRequested) { _cancel.Dispose(); _cancel = new(); } };
        page.SizeChanged += (_, args) => Root.Padding = new Thickness(args.NewSize.Width < 1000 ? 28 : 54, 8, args.NewSize.Width < 1000 ? 28 : 54, 20);
    }
    public void Activate() { if (_cancel.IsCancellationRequested) { _cancel.Dispose(); _cancel = new(); } }
    public T Recall<T>(string key, T fallback) => App.Window is { } window ? window.Recall(key, fallback) : fallback;
    public void Remember(string key, object value) => App.Window?.Remember(key, value);
    public async Task Load(Func<CancellationToken, Task<UIElement>> loader)
    {
        Activate(); _load?.Cancel(); _load?.Dispose(); _load = CancellationTokenSource.CreateLinkedTokenSource(Token);
        var token = _load.Token; var generation = ++_generation;
        Root.Children.Clear(); Root.Children.Add(new ProgressRing { IsActive = true, Width = 32, Height = 32 });
        try
        {
            var content = await loader(token);
            if (token.IsCancellationRequested || generation != _generation) return;
            Root.Children.Clear(); Root.Children.Add(content); App.Window?.RestorePageState(_page);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch
        {
            if (token.IsCancellationRequested || generation != _generation) return;
            Root.Children.Clear(); Root.Children.Add(RallyUi.Empty("Couldn't load this screen", "Check your connection, then try again.", "Retry", () => _ = Load(loader)));
        }
    }
    private sealed class RestoreInteraction(Action restore) : IDisposable { public void Dispose() => restore(); }
    private static IEnumerable<DependencyObject> Children(DependencyObject root)
    {
        yield return root;
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in Children(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    public IDisposable PreserveInteraction()
    {
        if (Root.XamlRoot is null) return new RestoreInteraction(() => { });
        var nodes = Children(Root).ToArray();
        var focused = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot) as Control;
        var name = focused?.FocusState == FocusState.Keyboard && nodes.Contains(focused) ? Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(focused) : "";
        var offsets = nodes.OfType<ScrollViewer>().Select(s => (s.HorizontalOffset, s.VerticalOffset)).ToArray();
        var inputVersion = InputVersion;
        return new RestoreInteraction(() => _page.DispatcherQueue.TryEnqueue(async () =>
        {
            if (Token.IsCancellationRequested || Root.XamlRoot is null) return;
            var current = Children(Root).ToArray();
            if (inputVersion != InputVersion) return;
            var scrolls = current.OfType<ScrollViewer>().ToArray();
            for (var i = 0; i < Math.Min(scrolls.Length, offsets.Length); i++)
                scrolls[i].ChangeView(offsets[i].HorizontalOffset, offsets[i].VerticalOffset, null, true);
            if (name.Length > 0 && focused is not null && !current.Contains(focused))
                for (var attempt = 0; attempt < 10; attempt++)
                {
                    if (Token.IsCancellationRequested || Root.XamlRoot is null) return;
                    // New controls cannot receive focus until WinUI measures
                    // them. Do not take focus back after the user moves on.
                    if (inputVersion != InputVersion) return;
                    var replacement = Children(Root).OfType<Control>().FirstOrDefault(c => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(c) == name);
                    if (replacement is { ActualWidth: > 0, IsEnabled: true } && replacement.Focus(FocusState.Keyboard)) return;
                    await Task.Delay(50);
                }
        }));
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
        wrap.SizeChanged += (_, args) =>
        {
            var count = args.NewSize.Width < 620 ? 1 : args.NewSize.Width < 940 ? 2 : 3;
            if (wrap.ColumnDefinitions.Count == count) return;
            wrap.ColumnDefinitions.Clear(); wrap.RowDefinitions.Clear();
            for (var i = 0; i < count; i++) wrap.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            for (var i = 0; i < wrap.Children.Count; i++) { if (i % count == 0) wrap.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); Grid.SetColumn((FrameworkElement)wrap.Children[i], i % count); Grid.SetRow((FrameworkElement)wrap.Children[i], i / count); }
        };
        return wrap;
    }
}
