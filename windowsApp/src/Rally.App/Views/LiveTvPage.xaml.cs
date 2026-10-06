using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Navigation;
using Rally.App.Design;
using Rally.Core;
namespace Rally.App.Views;
public sealed partial class LiveTvPage : Page
{
    private readonly PageState _state;
    private readonly ContentControl _content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly ContentControl _channelRows = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly TextBlock _channelCount = RallyUi.Text("", 12, true);
    private readonly Grid _channelBody = new() { RowSpacing = 12 };
    private readonly TextBox _search = new() { PlaceholderText = "Search channels", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _category = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private List<IptvChannel> _channels = [];
    private bool _channelMode;
    private int _loadGeneration;
    private bool _refreshing;
    private readonly DispatcherTimer _refresh = new() { Interval = TimeSpan.FromSeconds(40) };
    public LiveTvPage()
    {
        InitializeComponent(); NavigationCacheMode = NavigationCacheMode.Required; _state = new(this);
        _channelBody.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _channelBody.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _channelBody.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RallyUi.Put(_channelBody, RallyUi.Flow(_search, _category, RallyUi.Button("Refresh", () => _ = Channels(true))), 0);
        RallyUi.Put(_channelBody, _channelCount, 0, 1); RallyUi.Put(_channelBody, _channelRows, 0, 2);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_search, "Search channels");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_category, "Channel category");
        _search.TextChanged += (_, _) => Filter(); _category.SelectionChanged += (_, _) => Filter();
        BuildRoot();
        _refresh.Tick += async (_, _) => { if (_refreshing) return; _refreshing = true; try { if (_channelMode && _channelRows.Content is ListView list) await Guides(((IEnumerable<IptvChannel>)list.ItemsSource).Take(16).ToList(), list); else if (!_channelMode) await Games(); } finally { _refreshing = false; } };
        Loaded += (_, _) => _refresh.Start(); Unloaded += (_, _) => _refresh.Stop();
    }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate(); _channelMode = _state.Recall("channelMode", _channelMode);
        if (_channelMode) await Channels(); else await Games();
    }
    private void BuildRoot()
    {
        var body = new Grid { RowSpacing = 16 };
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RallyUi.Put(body, RallyUi.Heading("Live"), 0);
        RallyUi.Put(body, RallyUi.Row(RallyUi.Button("Live Games", () => _ = Games()), RallyUi.Button("Live TV", () => _ = Channels())), 0, 1);
        RallyUi.Put(body, _content, 0, 2);
        _state.Root.Children.Add(body);
    }
    private async Task Games()
    {
        _channelMode = false; _state.Remember("channelMode", false); var generation = ++_loadGeneration;
        if (_content.Content is null) _content.Content = RallyUi.Text("Loading live games…", 13, true);
        try { var games = (await App.Data.GamesAsync(ct: _state.Token)).Where(ev => ev.Status is EventStatus.Live or EventStatus.Halftime).ToList(); if (generation != _loadGeneration || _state.Token.IsCancellationRequested) return; using var interaction = _state.PreserveInteraction(); _content.Content = games.Count > 0 ? RallyUi.Scroll(PageState.Events(games)) : RallyUi.Empty("No games are live right now", "Browse your live channels or recent highlights.", "Browse Live TV", () => _ = Channels()); }
        catch (OperationCanceledException) { }
        catch { if (generation != _loadGeneration || _state.Token.IsCancellationRequested) return; _content.Content = RallyUi.Empty("Scores couldn't load", "Check your connection.", "Retry", () => _ = Games()); }
    }
    private async Task Channels(bool refresh = false)
    {
        _channelMode = true; _state.Remember("channelMode", true); var generation = ++_loadGeneration;
        var selectedCategory = _category.SelectedItem as string;
        _content.Content = RallyUi.Text("Loading channels…", 13, true);
        try
        {
            var channels = await App.Data.ChannelsAsync(refresh, _state.Token);
            if (generation != _loadGeneration || _state.Token.IsCancellationRequested) return;
            _channels = channels;
            if (_channels.Count == 0) { _content.Content = RallyUi.Empty("Add your live TV source", "Connect Stalker, Xtream, or an M3U playlist in Settings.", "Open Settings", () => App.Window?.NavigateTo("settings")); return; }
            _category.ItemsSource = new[] { "All Channels" }.Concat(_channels.Select(c => c.Category).Distinct().Order()); _category.SelectedItem = selectedCategory is not null && _channels.Any(c => c.Category == selectedCategory) ? selectedCategory : "All Channels"; Filter(); _content.Content = _channelBody;
        }
        catch (OperationCanceledException) { }
        catch { if (generation != _loadGeneration || _state.Token.IsCancellationRequested) return; _content.Content = RallyUi.Empty("Channels couldn't load", "Check your provider settings and connection.", "Retry", () => _ = Channels(true)); }
    }
    private void Filter()
    {
        if (_channels.Count == 0) return;
        var category = _category.SelectedItem as string ?? "All Channels"; var query = _search.Text.Trim();
        var rows = _channels.Where(c => (category == "All Channels" || c.Category == category) && (query.Length == 0 || c.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || c.Number.Contains(query))).ToList();
        var list = new ListView { ItemsSource = rows, IsItemClickEnabled = true, SelectionMode = ListViewSelectionMode.None, VerticalAlignment = VerticalAlignment.Stretch };
        list.ItemTemplate = (DataTemplate)XamlReader.Load("""
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Grid Padding="10" ColumnSpacing="16"><Grid.ColumnDefinitions><ColumnDefinition Width="52"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Image Source="{Binding LogoUrl}" Width="44" Height="44"/><StackPanel Grid.Column="1" Spacing="4"><TextBlock Text="{Binding Name}" FontSize="16" FontWeight="SemiBold"/><TextBlock Text="{Binding Guide.Now.Title}" Foreground="#A6ADB7" FontSize="12"/><TextBlock Text="{Binding Category}" Foreground="#A6ADB7" FontSize="11"/></StackPanel></Grid></DataTemplate>
""");
        list.ContainerContentChanging += (_, args) => { if (args.Item is IptvChannel channel) Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, channel.Name); };
        list.ItemClick += (_, e) => { if (e.ClickedItem is IptvChannel channel) PageState.Go(typeof(PlayerPage), channel); };
        _channelCount.Text = $"{rows.Count} channels · {_channels.Count} total"; _channelRows.Content = rows.Count == 0 ? RallyUi.Empty("No matching channels", "Try another name or category.") : list;
        _ = Guides(rows.Take(16).ToList(), list);
    }
    private async Task Guides(List<IptvChannel> channels, ListView list)
    {
        try
        {
            using var gate = new SemaphoreSlim(4);
            var updated = await Task.WhenAll(channels.Select(async channel => { await gate.WaitAsync(_state.Token); try { return channel with { Guide = await App.Data.GuideAsync(channel, _state.Token) }; } catch (OperationCanceledException) { return channel; } catch { return channel; } finally { gate.Release(); } }));
            if (_state.Token.IsCancellationRequested || !ReferenceEquals(_channelRows.Content, list)) return;
            foreach (var channel in updated) { var index = _channels.FindIndex(c => c.Id == channel.Id); if (index >= 0) _channels[index] = channel; }
            list.ItemsSource = ((IEnumerable<IptvChannel>)list.ItemsSource).Select(c => updated.FirstOrDefault(u => u.Id == c.Id) ?? c).ToList();
        }
        catch (OperationCanceledException) { }
    }
}
