using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Rally.App.Design;
using Rally.Core;
using Windows.System;

namespace Rally.App.Views;

public sealed partial class HomePage : Page
{
    private readonly PageState _state;
    private readonly Grid _body = new() { RowSpacing = 0 };
    private readonly Border _heroHost = new();
    private readonly Grid _liveHeader = new();
    private readonly Grid _rail = RallyUi.Columns(3, 18);
    private readonly Grid _upcoming = new() { ColumnSpacing = 18, RowSpacing = 0 };
    private readonly StackPanel _sports = new() { Spacing = 0 };
    private readonly List<Button> _upcomingButtons = [];
    private List<SportEvent> _events = [], _live = [], _soon = [];
    private List<HighlightClip> _clips = [];
    private bool _guide;
    private double _heroHeight = 210;
    private bool _compactLayout;
    private double GuideRowHeight => ActualHeight < 680 ? 34 : 52;
    private int _livePage;
    private int _venueGeneration;
    private string _railTitle = "Live Now";
    private readonly TextBlock _scheduleTitle = RallyUi.Heading("Starting Soon");
    private readonly DispatcherTimer _refresh = new() { Interval = TimeSpan.FromSeconds(40) };
    public HomePage()
    {
        InitializeComponent(); _upcoming.ChildrenTransitions = new Microsoft.UI.Xaml.Media.Animation.TransitionCollection { new Microsoft.UI.Xaml.Media.Animation.RepositionThemeTransition() }; _heroHost.SizeChanged += (_, args) => _heroHost.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, args.NewSize.Width, args.NewSize.Height) }; NavigationCacheMode = NavigationCacheMode.Required; _state = new(this);
        _body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _refresh.Tick += async (_, _) => { try { await RefreshSnapshot(); } catch (OperationCanceledException) { } catch { } };
        SizeChanged += (_, args) =>
        {
            _heroHeight = Math.Clamp(args.NewSize.Height - 386, 142, 258);
            if (!_guide) ResizeHero();
            ResizeRail();
            var compact = args.NewSize.Height < 680;
            if (_body.Children.Count > 0 && compact != _compactLayout)
            {
                _compactLayout = compact; BuildUpcoming(); BuildSports();
                if (_guide) _upcoming.Height = Math.Max(34, _soon.Count * GuideRowHeight);
            }
        };
        Loaded += (_, _) => _refresh.Start(); Unloaded += (_, _) => _refresh.Stop();
        PointerWheelChanged += (_, e) => { var delta = e.GetCurrentPoint(this).Properties.MouseWheelDelta; ShowGuide(delta < 0); e.Handled = true; };
    }
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _state.Activate();
        if (_body.Children.Count > 0) { BuildSports(); await RefreshSnapshot(); return; }
        await _state.Load(async ct =>
        {
            _events = await App.Data.GamesAsync(ct: ct);
            _live = _events.Where(ev => ev.Status is EventStatus.Live or EventStatus.Halftime).ToList();
            _soon = _events.Where(ev => ev.Status == EventStatus.NotStarted && ev.StartTime >= DateTimeOffset.Now.AddMinutes(-15)).OrderBy(ev => ev.StartTime).Take(4).ToList();
            if (_live.Count == 0)
            {
                var recent = _events.Where(ev => ev.Status == EventStatus.Finished).OrderByDescending(ev => ev.StartTime).Take(8);
                var details = await Task.WhenAll(recent.Select(ev => App.Data.DetailAsync(ev, ct: ct)));
                _clips = details.SelectMany(d => d.Clips).DistinctBy(c => c.Id).ToList(); _railTitle = "Recent Highlights";
            }
            Build(); var scroll = RallyUi.Scroll(_body); scroll.Padding = new Thickness(0); return scroll;
        });
    }
    private async Task RefreshSnapshot()
    {
        var events = await App.Data.GamesAsync(ct: _state.Token); if (_state.Token.IsCancellationRequested) return;
        var live = events.Where(ev => ev.Status is EventStatus.Live or EventStatus.Halftime).ToList();
        var changed = !_live.Select(g => $"{g.League}:{g.Id}").SequenceEqual(live.Select(g => $"{g.League}:{g.Id}"));
        _events = events; await App.Notifications.CheckAndNotifyAsync(events);
        _soon = events.Where(ev => ev.Status == EventStatus.NotStarted && ev.StartTime >= DateTimeOffset.Now.AddMinutes(-15)).OrderBy(ev => ev.StartTime).Take(4).ToList();
        BuildUpcoming();
        if (_guide) _upcoming.Height = Math.Max(48, _soon.Count * GuideRowHeight);
        if (changed)
        {
            _venueGeneration++;
            _live = live; _livePage = 0;
            if (live.Count == 0) { var details = await Task.WhenAll(events.Where(g => g.Status == EventStatus.Finished).OrderByDescending(g => g.StartTime).Take(8).Select(g => App.Data.DetailAsync(g, ct: _state.Token))); _clips = details.SelectMany(d => d.Clips).DistinctBy(c => c.Id).ToList(); }
            if (_state.Token.IsCancellationRequested) return; _railTitle = live.Count > 0 ? "Live Now" : "Recent Highlights"; _liveHeader.Children.Clear(); _liveHeader.Children.Add(RallyUi.SectionHeader(_railTitle, "See All ›", () => App.Window?.NavigateTo(live.Count > 0 ? "live" : "highlights"))); BuildLiveRail();
            var featured = live.FirstOrDefault() ?? _soon.FirstOrDefault() ?? events.OrderByDescending(g => g.StartTime).FirstOrDefault();
            if (featured is not null) { _heroHost.Child = RallyUi.Hero(featured, () => PageState.Watch(featured), () => PageState.Event(featured)); if (_heroHost.Child is Grid hero) hero.Height = _heroHeight; if (featured.VenueImageUrl is null) _ = LoadVenue(featured); }
        }
        else foreach (var card in _rail.Children.OfType<Button>()) { var name = Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(card); var game = events.FirstOrDefault(g => RallyUi.Matchup(g) == name); if (game is not null) { var replacement = RallyUi.EventCard(game, () => { }); var content = replacement.Content; replacement.Content = null; card.Content = content; } } ResizeRail();
    }
#if DEBUG
    internal Task RefreshForQa() => RefreshSnapshot();
#endif
    private void Build()
    {
        _venueGeneration++;
        _body.Children.Clear();
        var featured = _live.FirstOrDefault() ?? _soon.FirstOrDefault() ?? _events.OrderByDescending(ev => ev.StartTime).FirstOrDefault();
        _heroHost.Child = featured is null ? RallyUi.Empty("Welcome to Rally", "Live games, highlights and your next matchup.", "Browse Live TV", () => App.Window?.NavigateTo("live"))
            : RallyUi.Hero(featured, () => PageState.Watch(featured), () => PageState.Event(featured));
        ResizeHero(); RallyUi.Put(_body, _heroHost, 0, 0);
        if (featured is not null && featured.VenueImageUrl is null) _ = LoadVenue(featured);
        _liveHeader.Children.Clear(); _liveHeader.Children.Add(RallyUi.SectionHeader(_railTitle, "See All ›", () => App.Window?.NavigateTo(_live.Count > 0 ? "live" : "highlights")));
        var liveSection = RallyUi.Column(_liveHeader, _rail); liveSection.Spacing = 0; liveSection.Margin = new Thickness(0, 12, 0, 0);
        RallyUi.Put(_body, liveSection, 0, 1); BuildLiveRail();
        var scheduleHead = new Grid(); scheduleHead.Children.Add(_scheduleTitle);
        var full = RallyUi.Button("SEE FULL SCHEDULE ›", () => App.Window?.NavigateTo("schedule")); full.FontSize = 11; full.HorizontalAlignment = HorizontalAlignment.Right; full.Margin = new Thickness(0, -10, 0, 8); scheduleHead.Children.Add(full);
        var upcomingSection = RallyUi.Column(scheduleHead, _upcoming); upcomingSection.Spacing = 0; upcomingSection.Margin = new Thickness(0, 14, 0, 0); RallyUi.Put(_body, upcomingSection, 0, 2);
        _ = Services.ScoreAnnouncer.Announce(_live);
        BuildUpcoming(); BuildSports(); RallyUi.Put(_body, _sports, 0, 3); _sports.Visibility = Visibility.Collapsed; _sports.Margin = new Thickness(0, 24, 0, 0);
    }
    private void ResizeHero()
    {
        _heroHost.Height = _heroHeight;
        if (_heroHost.Child is Grid hero) hero.Height = _heroHeight;
    }
    private void ResizeRail()
    {
        foreach (var card in _rail.Children.OfType<Button>()) if (card.Content is StackPanel body && body.Children.FirstOrDefault() is Border art) { art.MaxHeight = ActualHeight < 680 ? (_guide ? 76 : 105) : 142; if (art.Child is Grid artwork) { artwork.MaxHeight = art.MaxHeight; if (ActualHeight < 680) { artwork.Padding = new Thickness(18, 14, 18, 14); foreach (var logo in artwork.Children.OfType<Image>()) logo.Width = logo.Height = _guide ? 44 : 52; } } body.Spacing = ActualHeight < 680 ? 8 : 12; }
    }
    private async Task LoadVenue(SportEvent ev)
    {
        var generation = ++_venueGeneration; var token = _state.Token;
        try { var detail = await App.Data.DetailAsync(ev, ct: token); if (!token.IsCancellationRequested && generation == _venueGeneration && detail.Context?.VenueImageUrl is string url) { _heroHost.Child = RallyUi.Hero(ev, () => PageState.Watch(ev), () => PageState.Event(ev), url); if (_heroHost.Child is Grid hero) hero.Height = _heroHeight; } } catch (OperationCanceledException) { } catch { /* The current hero remains usable when venue artwork is unavailable. */ }
    }
    private void BuildLiveRail()
    {
        _rail.Children.Clear();
        var start = _livePage * 3;
        if (_live.Count > 0)
        {
            var group = _live.Skip(start).Take(3).ToList();
            for (var i = 0; i < group.Count; i++)
            {
                var ev = group[i]; var button = RallyUi.EventCard(ev, () => PageState.Event(_events.FirstOrDefault(g => g.Id == ev.Id && g.League == ev.League) ?? ev), false);
                var slot = i; button.KeyDown += (_, key) =>
                {
                    if (key.Key == VirtualKey.Right && slot == group.Count - 1 && start + 3 < _live.Count) { _livePage++; BuildLiveRail(); (_rail.Children[0] as Button)?.Focus(FocusState.Keyboard); key.Handled = true; }
                    else if (key.Key == VirtualKey.Left && slot == 0 && _livePage > 0) { _livePage--; BuildLiveRail(); (_rail.Children.LastOrDefault() as Button)?.Focus(FocusState.Keyboard); key.Handled = true; }
                    else if (key.Key == VirtualKey.Down && _upcomingButtons.Count > 0) { _upcomingButtons[Math.Min(slot, _upcomingButtons.Count - 1)].Focus(FocusState.Keyboard); key.Handled = true; }
                };
                RallyUi.Put(_rail, button, i);
            }
        }
        else
        {
            var group = _clips.Skip(start).Take(3).ToList();
            for (var i = 0; i < group.Count; i++) { var clip = group[i]; var card = ClipCard(clip); RallyUi.Put(_rail, card, i); }
            if (group.Count == 0) { var empty = RallyUi.Empty("Highlights are being updated", "Browse recent games or your live channels.", "Browse Live TV", () => App.Window?.NavigateTo("live")); RallyUi.Put(_rail, empty, 0); Grid.SetColumnSpan((FrameworkElement)empty, 3); }
        }
        ResizeRail();
        _rail.ChildrenTransitions = App.Data.Settings.ReducedMotion ? new Microsoft.UI.Xaml.Media.Animation.TransitionCollection() : new Microsoft.UI.Xaml.Media.Animation.TransitionCollection { new Microsoft.UI.Xaml.Media.Animation.EntranceThemeTransition() };
    }
    internal static Button ClipCard(HighlightClip clip, bool compact = false)
    {
        var art = RallyUi.Image(clip.ThumbnailUrl, height: compact ? 66 : 142, stretch: Stretch.UniformToFill);
        var title = RallyUi.Text(clip.Title, compact ? 11 : 15, false, true); title.MaxLines = 2; title.Margin = new Thickness(4, 3, 4, 0);
        var body = RallyUi.Column(art, title, RallyUi.Text(clip.DurationSeconds is int duration ? TimeSpan.FromSeconds(duration).ToString("m\\:ss") + " · Highlights" : "Highlights", compact ? 10 : 12, true)); body.Spacing = compact ? 4 : 12; return RallyUi.Tile(body, clip.Title, () =>
        { if (clip.StreamUrl is string stream) PageState.Go(typeof(PlayerPage), stream); else if (clip.WebUrl is string web) _ = Windows.System.Launcher.LaunchUriAsync(new Uri(web)); });
    }
    private void BuildUpcoming()
    {
        _upcoming.ChildrenTransitions = App.Data.Settings.ReducedMotion ? new Microsoft.UI.Xaml.Media.Animation.TransitionCollection() : new Microsoft.UI.Xaml.Media.Animation.TransitionCollection { new Microsoft.UI.Xaml.Media.Animation.RepositionThemeTransition() };
        _upcoming.ColumnDefinitions.Clear(); _upcoming.RowDefinitions.Clear(); _upcoming.ColumnSpacing = _guide ? 0 : 18;
        if (_soon.Count == 0) { _upcoming.Children.Clear(); _upcomingButtons.Clear(); _upcoming.Children.Add(RallyUi.Empty("No upcoming games yet", "Open Schedule to browse another day.")); return; }
        foreach (var empty in _upcoming.Children.Where(child => child is not Button).ToList()) _upcoming.Children.Remove(empty);
        while (_upcomingButtons.Count > _soon.Count) { var last = _upcomingButtons[^1]; _upcoming.Children.Remove(last); _upcomingButtons.RemoveAt(_upcomingButtons.Count - 1); }
        for (int i = 0; i < (_guide ? 1 : 4); i++) _upcoming.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < _soon.Count; i++)
        {
            var ev = _soon[i]; var body = _guide ? GuideRow(ev) : CompactEvent(ev);
            var isNew = i >= _upcomingButtons.Count;
            var slot = i;
            var button = isNew ? RallyUi.Tile(body, RallyUi.Matchup(ev), () => { if (slot < _soon.Count) PageState.Event(_soon[slot]); }, _guide) : _upcomingButtons[i];
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, RallyUi.Matchup(ev));
            if (button.Tag is not ValueTuple<SportEvent, bool> previous || previous.Item1 != ev || previous.Item2 != _guide) button.Content = body;
            button.Tag = (ev, _guide); button.Background = _guide ? RallyUi.Surface : new SolidColorBrush(Microsoft.UI.Colors.Transparent); button.BorderThickness = new Thickness(_guide ? 1 : 0); button.MinHeight = _guide ? (ActualHeight < 680 ? 32 : 48) : 72;
            if (_guide && ActualHeight < 680 && body is Grid compactRow) { compactRow.Padding = new Thickness(18, 2, 18, 2); foreach (var image in compactRow.Children.OfType<Image>()) image.Height = 24; foreach (var text in compactRow.Children.OfType<TextBlock>()) text.TextWrapping = TextWrapping.NoWrap; }
            if (_guide) _upcoming.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            if (isNew) button.KeyDown += (_, key) =>
            {
                if (key.Key == VirtualKey.Down && !_guide) { ShowGuide(true); _upcomingButtons[Math.Min(slot, _upcomingButtons.Count - 1)].Focus(FocusState.Keyboard); key.Handled = true; }
                else if (key.Key == VirtualKey.Up && _guide && slot == 0) { ShowGuide(false); _upcomingButtons[0].Focus(FocusState.Keyboard); key.Handled = true; }
            };
            Grid.SetColumn(button, _guide ? 0 : i); Grid.SetRow(button, _guide ? i : 0); if (isNew) { _upcoming.Children.Add(button); _upcomingButtons.Add(button); }
        }
    }
    private static UIElement CompactEvent(SportEvent ev)
    {
        var logos = ev.AwayTeam is not null && ev.HomeTeam is not null
            ? RallyUi.Row(RallyUi.Image(ev.AwayTeam.LogoUrl, 36, 36), RallyUi.Image(ev.HomeTeam.LogoUrl, 36, 36))
            : RallyUi.Row(RallyUi.SportMark(ev.League, 36));
        logos.Spacing = 8; logos.Width = 80; logos.HorizontalAlignment = HorizontalAlignment.Center;
        var title = RallyUi.Text(RallyUi.Matchup(ev), 11, false, true); title.MaxLines = 2;
        var names = RallyUi.Column(title, RallyUi.Text(ev.League, 10, true)); names.Spacing = 4;
        names.MaxWidth = 164;
        var row = RallyUi.Columns(2, 8); row.ColumnDefinitions[0].Width = GridLength.Auto; RallyUi.Put(row, logos, 0); RallyUi.Put(row, names, 1);
        var stack = RallyUi.Column(RallyUi.Text(ev.StartTime.LocalDateTime.ToString("h:mm tt"), 11, true), row); stack.Spacing = 6; stack.Padding = new Thickness(4, 4, 4, 4); return stack;
    }
    internal static UIElement GuideRow(SportEvent ev)
    {
        var grid = new Grid { Padding = new Thickness(18, 8, 18, 8), ColumnSpacing = 18 };
        foreach (var width in new[] { new GridLength(100), new GridLength(54), new GridLength(54), new GridLength(1, GridUnitType.Star), new GridLength(70), new GridLength(42) }) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        RallyUi.Put(grid, RallyUi.Text(ev.StartTime.LocalDateTime.ToString("h:mm tt"), 13), 0);
        RallyUi.Put(grid, RallyUi.Image(ev.AwayTeam?.LogoUrl, 36, 32), 1); RallyUi.Put(grid, RallyUi.Image(ev.HomeTeam?.LogoUrl, 36, 32), 2);
        RallyUi.Put(grid, RallyUi.Text(RallyUi.Matchup(ev), 13), 3); RallyUi.Put(grid, RallyUi.Text(ev.League, 11, true), 4);
        var reminder = RallyUi.Button(""); reminder.MinHeight = 28; reminder.Padding = new Thickness(6, 2, 6, 2);
        var icon = new FontIcon { FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 14, Glyph = App.Data.Settings.IsSavedEvent(ev) ? "\uE73E" : "\uEA8F" }; reminder.Content = icon;
        reminder.Click += (_, _) => { var saved = App.Data.Settings.ToggleSavedEvent(ev); icon.Glyph = saved ? "\uE73E" : "\uEA8F"; };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(reminder, $"Remind me: {RallyUi.Matchup(ev)}"); RallyUi.Put(grid, reminder, 5); return grid;
    }
    internal static string[] HomeSports()
    {
        var leagues = new[] { "NFL", "NBA", "MLB", "NHL", "NCAAF", "NCAAB", "MLS", "UFC", "Soccer", "Tennis" };
        var saved = App.Data.Settings.SportsOrder;
        return saved.Where(leagues.Contains).Concat(leagues.Where(l => !saved.Contains(l))).Distinct().ToArray();
    }
    private void BuildSports()
    {
        _sports.Children.Clear(); var title = RallyUi.Heading("Browse by Sport"); title.Margin = new Thickness(4, 0, 0, ActualHeight < 680 ? 10 : 16); _sports.Children.Add(title);
        var grid = RallyUi.Columns(10, 12);
        var order = HomeSports().Where(l => !App.Data.Settings.DisabledLeagues.Contains(l)).ToArray();
        grid.ColumnDefinitions.Clear(); for (int col = 0; col < Math.Max(1, order.Length); col++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < order.Length; i++) { var league = order[i]; var tile = RallyUi.SportTile(league, () => PageState.Go(typeof(LeagueCenterPage), league));
            if (ActualHeight < 680 && tile.Content is StackPanel sport) { sport.Margin = new Thickness(4); sport.Spacing = 3; tile.MinHeight = 56; if (sport.Children.FirstOrDefault() is FrameworkElement mark) mark.Height = mark.Width = 30; } RallyUi.Put(grid, tile, i); }
        _sports.Children.Add(grid);
    }
    internal void SetGuideForQa(bool guide) => ShowGuide(guide);
    public void ShowTop() => ShowGuide(false);
    private void ShowGuide(bool guide)
    {
        if (_guide == guide) return; _guide = guide;
        if (!guide) _heroHost.Visibility = Visibility.Visible;
        RallyUi.Animate(_heroHost, "Height", guide ? 0 : _heroHeight, 300, () => { if (_guide) _heroHost.Visibility = Visibility.Collapsed; });
        _heroHost.IsHitTestVisible = !guide;
        _scheduleTitle.Text = guide ? "TONIGHT’S SCHEDULE" : "STARTING SOON";
        var previousHeight = _upcoming.ActualHeight; BuildUpcoming();
        _upcoming.Height = previousHeight; RallyUi.Animate(_upcoming, "Height", guide ? _soon.Count * GuideRowHeight : 82, 300);
        _sports.Visibility = guide ? Visibility.Visible : Visibility.Collapsed; _sports.Margin = new Thickness(0, ActualHeight < 680 ? 4 : 24, 0, 0); ResizeRail();
        _sports.Opacity = guide ? 0 : 1; RallyUi.Animate(_sports, "Opacity", guide ? 1 : 0, 220);
    }
}
