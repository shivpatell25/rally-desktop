using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Rally.Core;

namespace Rally.App.Views;

// Live TV browser. 1:1 with Android IptvBrowserScreen + IptvBrowserViewModel:
// left category rail (All + distinct categories, sports first), search by
// name/number, "N channels · M total" counts, per-row Now/Next EPG loaded
// lazily, catch-up badge, no-provider / empty / error states with retry.
public sealed partial class LiveTvPage : Page
{
    private readonly SettingsStore _settings = new();
    private readonly HttpClient _http = new();
    private readonly StalkerClient _stalker;
    private readonly XtreamClient _xtream;
    private readonly SemaphoreSlim _guideGate = new(4, 4);
    private readonly HashSet<string> _guideLoading = new();
    private readonly Dictionary<string, ChannelGuide> _guideCache = new();
    private readonly object _guideLock = new();
    private CancellationTokenSource? _cts;

    private List<IptvChannel> _all = [];
    private string _selectedCategory = "All";
    private string _search = "";

    public LiveTvPage()
    {
        InitializeComponent();
        _stalker = new StalkerClient(_http, _settings);
        _xtream = new XtreamClient(_http, _settings);
        Loaded += async (_, _) => await LoadAsync(refresh: false).ConfigureAwait(false);
        Unloaded += (_, _) => { _cts?.Cancel(); _cts?.Dispose(); _cts = null; };
    }

    private bool HasProviderCredentials() => _settings.IptvProvider == IptvProvider.Xtream
        ? _settings.XtreamServerUrl.Length > 0 && _settings.XtreamUsername.Length > 0
        : _settings.PortalUrl.Length > 0;

    private async Task LoadAsync(bool refresh)
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        DispatcherQueue.TryEnqueue(() => ShowState("loading"));
        if (!HasProviderCredentials())
        {
            DispatcherQueue.TryEnqueue(() => ShowState("noprovider"));
            return;
        }
        List<IptvChannel> channels;
        try
        {
            channels = _settings.IptvProvider == IptvProvider.Xtream
                ? refresh ? await _xtream.RefreshChannelsAsync(ct).ConfigureAwait(false)
                          : await _xtream.GetChannelsAsync(ct).ConfigureAwait(false)
                : refresh ? await _stalker.RefreshChannelsAsync(ct).ConfigureAwait(false)
                          : await _stalker.GetChannelsAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            var message = ex.Message;
            DispatcherQueue.TryEnqueue(() => ShowError(message));
            return;
        }
        if (ct.IsCancellationRequested) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            _all = channels;
            RebuildCategories();
            ApplyFilter();
        });
    }

    // UI thread only.
    private void RebuildCategories()
    {
        var distinct = _all
            .Select(c => string.IsNullOrWhiteSpace(c.Category) ? "Live TV" : c.Category)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        var sports = distinct
            .Where(c => c.Contains("sport", StringComparison.OrdinalIgnoreCase))
            .OrderBy(c => c, StringComparer.OrdinalIgnoreCase);
        var rest = distinct
            .Where(c => !c.Contains("sport", StringComparison.OrdinalIgnoreCase))
            .OrderBy(c => c, StringComparer.OrdinalIgnoreCase);
        var cats = new List<string> { "All" };
        cats.AddRange(sports);
        cats.AddRange(rest);
        if (!cats.Contains(_selectedCategory, StringComparer.OrdinalIgnoreCase)) _selectedCategory = "All";
        Categories.ItemsSource = cats;
        var selected = cats.FirstOrDefault(c => c.Equals(_selectedCategory, StringComparison.OrdinalIgnoreCase)) ?? "All";
        _selectedCategory = selected;
        if (!selected.Equals(Categories.SelectedItem as string, StringComparison.OrdinalIgnoreCase))
            Categories.SelectedItem = selected;
    }

    // MUST run on the UI thread (creates BitmapImage rows, touches ItemsSource).
    private void ApplyFilter()
    {
        var search = _search.Trim();
        var rows = _all
            .Where(c => (_selectedCategory.Equals("All", StringComparison.OrdinalIgnoreCase) ||
                         c.Category.Equals(_selectedCategory, StringComparison.OrdinalIgnoreCase)) &&
                        (search.Length == 0 ||
                         c.Name.Contains(search, StringComparison.OrdinalIgnoreCase) ||
                         c.Number.Contains(search, StringComparison.OrdinalIgnoreCase)))
            .Select(c =>
            {
                ChannelGuide? cached;
                lock (_guideLock) _guideCache.TryGetValue(c.Id, out cached);
                return new ChannelRow(c, cached);
            })
            .ToList();
        CategoryTitle.Text = _selectedCategory;
        Counts.Text = $"{rows.Count} channels · {_all.Count} total";
        Channels.ItemsSource = rows;
        if (_all.Count == 0)
        {
            ShowEmpty("No channels were returned", "Retry, or check your portal details in Settings.", showRetry: true);
        }
        else if (rows.Count == 0)
        {
            ShowEmpty(search.Length == 0 ? "No channels in this category" : $"No results for \u201c{search}\u201d",
                "Try another category or search term.", showRetry: false);
        }
        else
        {
            ShowState("list");
            foreach (var row in rows.Take(30)) MaybeLoadGuide(row);
        }
    }

    private void MaybeLoadGuide(ChannelRow row)
    {
        if (row.GuideLoaded) return;
        lock (_guideLock)
        {
            if (_guideCache.TryGetValue(row.Channel.Id, out var cached))
            {
                DispatcherQueue.TryEnqueue(() => row.SetGuide(cached));
                return;
            }
            if (!_guideLoading.Add(row.Channel.Id)) return;
        }
        var ct = _cts?.Token ?? CancellationToken.None;
        _ = LoadGuideAsync(row, ct);
    }

    private async Task LoadGuideAsync(ChannelRow row, CancellationToken ct)
    {
        var entered = false;
        try
        {
            await _guideGate.WaitAsync(ct).ConfigureAwait(false);
            entered = true;
            ChannelGuide? guide;
            try
            {
                guide = _settings.IptvProvider == IptvProvider.Xtream
                    ? await _xtream.GetGuideAsync(row.Channel.Id, ct).ConfigureAwait(false)
                    : await _stalker.GetGuideAsync(row.Channel.Id, ct).ConfigureAwait(false);
            }
            catch
            {
                return; // per-row guide failure is not fatal; row keeps its category fallback text
            }
            if (guide is null || ct.IsCancellationRequested) return;
            lock (_guideLock) _guideCache[row.Channel.Id] = guide;
            DispatcherQueue.TryEnqueue(() => row.SetGuide(guide));
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            if (entered) _guideGate.Release();
            lock (_guideLock) _guideLoading.Remove(row.Channel.Id);
        }
    }

    // UI thread only.
    private void ShowState(string state)
    {
        Spinner.IsActive = state == "loading";
        LoadingState.Visibility = state == "loading" ? Visibility.Visible : Visibility.Collapsed;
        NoProviderState.Visibility = state == "noprovider" ? Visibility.Visible : Visibility.Collapsed;
        ErrorState.Visibility = state == "error" ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = state == "empty" ? Visibility.Visible : Visibility.Collapsed;
        Channels.Visibility = state == "list" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowError(string message)
    {
        ErrorMessage.Text = message;
        ShowState("error");
    }

    private void ShowEmpty(string title, string subtitle, bool showRetry)
    {
        EmptyTitle.Text = title;
        EmptySubtitle.Text = subtitle;
        EmptyRetry.Visibility = showRetry ? Visibility.Visible : Visibility.Collapsed;
        ShowState("empty");
    }

    private void Categories_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Categories.SelectedItem is string cat &&
            !cat.Equals(_selectedCategory, StringComparison.OrdinalIgnoreCase))
        {
            _selectedCategory = cat;
            ApplyFilter();
        }
    }

    private void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        _search = sender.Text ?? "";
        ApplyFilter();
    }

    private void Channels_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Channels.SelectedItem is ChannelRow row)
        {
            Channels.SelectedItem = null;
            // Agreed nav contract: PlayerPage accepts object — IptvChannel here for
            // direct play via StreamResolver.ChannelCandidates (PlayerOwner implements
            // the IptvChannel branch). No synthetic SportEvent.
            Frame.Navigate(typeof(PlayerPage), row.Channel);
        }
    }

    private void Channels_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is ChannelRow row) MaybeLoadGuide(row);
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await LoadAsync(refresh: true).ConfigureAwait(false);

    public sealed class ChannelRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;

        public IptvChannel Channel { get; }
        public string Number => Channel.Number;
        public string Name => Channel.Name;
        public ImageSource? LogoImage { get; }
        public string Fallback { get; }
        public string QualityBadge { get; }
        public Visibility QualityVisibility => QualityBadge.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        public Visibility CatchUpVisibility => Channel.SupportsCatchUp ? Visibility.Visible : Visibility.Collapsed;

        private string _nowText = "";
        public string NowText
        {
            get => _nowText;
            private set
            {
                _nowText = value;
                OnPropertyChanged(nameof(NowText));
                OnPropertyChanged(nameof(NowVisibility));
            }
        }
        public Visibility NowVisibility => _nowText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

        private string _nextText;
        public string NextText
        {
            get => _nextText;
            private set
            {
                _nextText = value;
                OnPropertyChanged(nameof(NextText));
            }
        }

        public bool GuideLoaded { get; private set; }

        public ChannelRow(IptvChannel channel, ChannelGuide? guide = null)
        {
            Channel = channel;
            LogoImage = TryLogo(channel.LogoUrl);
            Fallback = channel.Number.Length > 0
                ? channel.Number
                : channel.Name.Length >= 2 ? channel.Name[..2].ToUpperInvariant() : channel.Name;
            QualityBadge = Quality.Parse(channel.Name).Resolution ?? "";
            _nextText = CategoryFallback(channel);
            if (guide is not null) SetGuide(guide);
        }

        // Must be called on the UI thread (raises bindings).
        public void SetGuide(ChannelGuide guide)
        {
            GuideLoaded = true;
            if (guide.Now?.Title is { Length: > 0 } now) NowText = $"Now · {now}";
            NextText = guide.Next?.Title is { Length: > 0 } next ? $"Next · {next}" : CategoryFallback(Channel);
        }

        private static string CategoryFallback(IptvChannel c) =>
            string.IsNullOrWhiteSpace(c.Category) ? "Live TV" : c.Category;

        private static ImageSource? TryLogo(string? url)
        {
            if (string.IsNullOrWhiteSpace(url)) return null;
            try { return new BitmapImage(new Uri(url.Trim(), UriKind.Absolute)); }
            catch { return null; }
        }

        private void OnPropertyChanged(string name) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
