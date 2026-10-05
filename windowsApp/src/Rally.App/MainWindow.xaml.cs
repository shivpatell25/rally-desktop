using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Windowing;
using Rally.App.Design;
using Rally.App.Views;
using Windows.System;

namespace Rally.App;

public sealed partial class MainWindow : Window
{
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    private readonly Dictionary<Type, string> _focusHistory = new();
    private readonly Services.WindowSizing _sizing;
    private readonly Dictionary<string, Button> _tabs = new();
    private bool _fullscreen;
    private bool _closing, _closeReady;
    private sealed class VideoHost
    {
        public required LibVLCSharp.Platforms.Windows.VideoView View;
        public FrameworkElement? Anchor;
        public required Action Changed;
        public required Action Detach;
    }
    private readonly Dictionary<Services.PlaybackSession, VideoHost> _videoHosts = new();
    public void AttachVideo(Services.PlaybackSession session, FrameworkElement anchor)
    {
        if (!_videoHosts.TryGetValue(session, out var host))
        {
            var view = new LibVLCSharp.Platforms.Windows.VideoView { Width = 2, Height = 2, Opacity = 0, IsTabStop = false };
            view.Initialized += (_, args) =>
            {
                // WinUI and VLC share this immediate context. Software decoding does
                // not enable VLC's hardware-decoder protection, so protect it before
                // either renderer starts issuing commands (including seek/restart).
                var option = args.SwapChainOptions.First(o => o.StartsWith("--winrt-d3dcontext="));
                var pointer = new IntPtr(Convert.ToInt64(option.Split('=')[1][2..], 16));
                System.Runtime.InteropServices.Marshal.AddRef(pointer);
                using (var context = new SharpDX.Direct3D11.DeviceContext(pointer))
                using (var protection = context.QueryInterface<SharpDX.Direct3D11.Multithread>())
                {
                    protection.SetMultithreadProtected(true);
                    // DeviceChild owns its cached Device reference; only dispose
                    // the new QueryInterface/Adapter references here.
                    using var dxgi = context.Device.QueryInterface<SharpDX.DXGI.Device>();
                    using var adapter = dxgi.Adapter;
                    var description = adapter.Description;
                    var software = description.Description.Contains("Basic Render", StringComparison.OrdinalIgnoreCase)
                        || description.Description.Contains("Software", StringComparison.OrdinalIgnoreCase);
                    session.ConfigureVideoOutput(args.SwapChainOptions, software, description.Description);
                }
            };
            host = new() { View = view, Changed = () => view.MediaPlayer = session.Player, Detach = () => view.MediaPlayer = null };
            _videoHosts.Add(session, host); session.Changed += host.Changed; session.Detaching += host.Detach;
            VideoLayer.Children.Add(view);
        }
        host.Anchor = anchor; UpdateVideoBounds();
    }
    public void DetachVideo(Services.PlaybackSession session, FrameworkElement anchor)
    {
        if (_videoHosts.TryGetValue(session, out var host) && ReferenceEquals(host.Anchor, anchor)) { host.Anchor = null; host.View.Opacity = 0; }
    }
    public void ReleaseVideo(Services.PlaybackSession session)
    {
        if (!_videoHosts.Remove(session, out var host)) return;
        session.Changed -= host.Changed; session.Detaching -= host.Detach; host.View.MediaPlayer = null; VideoLayer.Children.Remove(host.View);
    }
    private void UpdateVideoBounds()
    {
        foreach (var host in _videoHosts.Values)
        {
            var anchor = host.Anchor; if (anchor?.XamlRoot is null || anchor.ActualWidth < 1 || anchor.ActualHeight < 1) { host.View.Opacity = 0; continue; }
            var point = anchor.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point(0, 0));
            Canvas.SetLeft(host.View, point.X); Canvas.SetTop(host.View, point.Y);
            host.View.Width = anchor.ActualWidth; host.View.Height = anchor.ActualHeight; host.View.Opacity = 1;
        }
    }
    private DateTimeOffset _lastInput = DateTimeOffset.UtcNow;
    #if DEBUG
    internal async Task CaptureVideoForQa(string path)
    {
        var player = App.Playback.Player ?? throw new InvalidOperationException("No player");
        if (!await Task.Run(() => player.TakeSnapshot(0, path, 0, 0))) throw new InvalidOperationException("Native snapshot unavailable");
        for (var attempt = 0; attempt < 40 && !File.Exists(path); attempt++) await Task.Delay(100);
        if (!File.Exists(path)) throw new TimeoutException("Snapshot was not saved");
    }
    internal async Task IdleForQa() { var previous = App.Data.Settings.ScoreSaverEnabled; App.Data.Settings.ScoreSaverEnabled = true; await ShowIdle(); App.Data.Settings.ScoreSaverEnabled = previous; }
    internal void WakeForQa() => Wake();
#endif
    private int _idleGeneration;
    private readonly DispatcherTimer _idleTimer = new() { Interval = TimeSpan.FromSeconds(10) };
    public Frame Navigator => ContentFrame;
    public bool IsFullscreen => _fullscreen;
    public MainWindow()
    {
        InitializeComponent();
        _sizing = new(WinRT.Interop.WindowNative.GetWindowHandle(this));
        var dark = 1; DwmSetWindowAttribute(WinRT.Interop.WindowNative.GetWindowHandle(this), 20, ref dark, sizeof(int));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min(1440, area.Width - 32); var height = Math.Min(940, area.Height - 32);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
        Root.LayoutUpdated += (_, _) => UpdateVideoBounds();
        foreach (var (tag, title) in new[] { ("home", "Home"), ("live", "Live"), ("schedule", "Schedule"), ("leagues", "Leagues"), ("highlights", "Highlights"), ("myteams", "My Rally") })
        {
            var button = RallyUi.Button(title, () => NavigateTo(tag)); button.Background = new SolidColorBrush(Colors.Transparent); button.BorderThickness = new Thickness(0); button.Padding = new Thickness(12, 9, 12, 9); button.FontSize = 16; button.FontWeight = Microsoft.UI.Text.FontWeights.Normal;
            _tabs[tag] = button; Destinations.Children.Add(button);
        }
        var search = RallyUi.Button("Search", () => NavigateTo("search")); search.Content = new FontIcon { Glyph = "\uE721", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 16 }; UtilityNav.Children.Add(search);
        var settings = RallyUi.Button("Settings", () => NavigateTo("settings")); settings.Content = new FontIcon { Glyph = "\uE713", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 16 }; UtilityNav.Children.Add(settings);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName((DependencyObject)UtilityNav.Children[0], "Search");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName((DependencyObject)UtilityNav.Children[1], "Settings");
        Root.KeyDown += KeyDown;
        Root.PointerMoved += (_, _) => Wake(); Root.PointerPressed += (_, _) => Wake();
        Activated += (_, args) => { if (args.WindowActivationState != WindowActivationState.Deactivated) Wake(); else if (!App.Playback.IsPlaying) _ = ShowIdle(); };
        AppWindow.Closing += async (_, args) =>
        {
            if (_closeReady) return;
            args.Cancel = true;
            if (_closing) return;
            _closing = true; _idleTimer.Stop();
            // Stop all renderers while their swapchains still exist. Closed is
            // too late: WinUI has already begun unloading the visual tree then.
            foreach (var session in _videoHosts.Keys.Append(App.Playback).Distinct().ToArray()) await session.DisposeAsync();
            _closeReady = true; Close();
        };
        Closed += (_, _) => { _sizing.Dispose(); _idleTimer.Stop(); };
        _idleTimer.Tick += (_, _) => { if (!App.Playback.IsPlaying && DateTimeOffset.UtcNow - _lastInput > TimeSpan.FromMinutes(5)) _ = ShowIdle(); };
        _idleTimer.Start();
        ContentFrame.Navigating += (_, _) => { if (ContentFrame.CurrentSourcePageType is Type page && Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot) is Control control && control.FocusState == FocusState.Keyboard) { var name = Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(control); if (name.Length > 0) _focusHistory[page] = name; } };
        ContentFrame.Navigated += async (_, args) => { if (args.NavigationMode != Microsoft.UI.Xaml.Navigation.NavigationMode.Back || !_focusHistory.TryGetValue(args.SourcePageType, out var name)) return; await Task.Delay(250); if (ContentFrame.CurrentSourcePageType != args.SourcePageType) return; foreach (var control in Descendants(ContentFrame).OfType<Control>()) if (Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(control) == name && control.ActualWidth > 0 && control.IsEnabled) { control.Focus(FocusState.Keyboard); break; } };
        ContentFrame.Navigated += (_, args) => { SelectNavItem(TagFor(args.SourcePageType)); var videoPage = args.SourcePageType == typeof(GameViewPage) || args.SourcePageType == typeof(PlayerPage); TopNav.Visibility = _fullscreen || videoPage ? Visibility.Collapsed : Visibility.Visible; Shell.RowDefinitions[0].Height = new GridLength(_fullscreen || videoPage ? 0 : 86); if (!videoPage && args.SourcePageType != typeof(MultiViewPage)) _ = App.Playback.SuspendAsync(); };
        Root.SizeChanged += (_, args) => { TopNav.Padding = new Thickness(args.NewSize.Width < 1100 ? 20 : 44, 14, args.NewSize.Width < 1100 ? 20 : 44, 14); Destinations.Spacing = args.NewSize.Width < 1100 ? 0 : 8; LogoButton.Width = NavWordmark.Width = args.NewSize.Width < 1000 ? 88 : 126; };
    }
    private async Task ShowIdle()
    {
        if (!App.Data.Settings.ScoreSaverEnabled || App.Playback.IsPlaying || ContentFrame.Content is PlayerPage or GameViewPage or MultiViewPage or OnboardingPage) return;
        try
        {
            var generation = ++_idleGeneration; var games = await App.Data.GamesAsync(); if (generation != _idleGeneration || App.Playback.IsPlaying) return;
            var clock = RallyUi.Text(DateTimeOffset.Now.LocalDateTime.ToString("h:mm tt"), 64); clock.HorizontalAlignment = HorizontalAlignment.Center;
            var scores = RallyUi.Columns(4, 16); var selected = games.OrderByDescending(g => g.Status is Rally.Core.EventStatus.Live or Rally.Core.EventStatus.Halftime).Take(4).ToList();
            for (var i = 0; i < selected.Count; i++) { var game = selected[i]; RallyUi.Put(scores, RallyUi.Panel(RallyUi.Column(RallyUi.Text(game.League, 11, true), RallyUi.Text(RallyUi.Matchup(game), 13, false, true), RallyUi.Text(RallyUi.Score(game), 20))), i); }
            var body = RallyUi.Column(RallyUi.Asset("rally_wordmark.png", 130, 45), clock, scores, RallyUi.Text("Move the pointer or press a key to return", 12, true));
            body.VerticalAlignment = VerticalAlignment.Center; body.Margin = new Thickness(48); IdleVeil.Children.Clear(); IdleVeil.Children.Add(body); IdleVeil.Visibility = Visibility.Visible;
        }
        catch { }
    }
    private void Wake() { _idleGeneration++; _lastInput = DateTimeOffset.UtcNow; IdleVeil.Visibility = Visibility.Collapsed; }
    private void Logo_Click(object sender, RoutedEventArgs e) => NavigateTo("home");
    private void KeyDown(object sender, KeyRoutedEventArgs e)
    {
        Wake();
        var focus = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot);
        if (focus is TextBox or PasswordBox or AutoSuggestBox) return;
        if (e.Key == VirtualKey.Escape) { if (_fullscreen) SetFullscreen(false); else Back(); e.Handled = true; }
        else if (e.Key == VirtualKey.F11) { SetFullscreen(!_fullscreen); e.Handled = true; }
        else if (e.Key == VirtualKey.Space && ContentFrame.Content is GameViewPage or PlayerPage) { App.Playback.TogglePause(); e.Handled = true; }
        else if (e.Key == VirtualKey.F && Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) { NavigateTo("search"); e.Handled = true; }
        else if (e.Key == VirtualKey.Left && Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) { Back(); e.Handled = true; }
        else if (e.Key == VirtualKey.Home && Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) { NavigateTo("home"); e.Handled = true; }
    }
    public void SetFullscreen(bool enabled)
    {
        _fullscreen = enabled; var videoPage = ContentFrame.CurrentSourcePageType == typeof(GameViewPage) || ContentFrame.CurrentSourcePageType == typeof(PlayerPage);
        TopNav.Visibility = enabled || videoPage ? Visibility.Collapsed : Visibility.Visible;
        Shell.RowDefinitions[0].Height = new GridLength(enabled || videoPage ? 0 : 86);
        AppWindow.SetPresenter(enabled ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Overlapped);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var item in Descendants(VisualTreeHelper.GetChild(root, i))) yield return item;
    }
    public void Back() { if (ContentFrame.CanGoBack) ContentFrame.GoBack(); else NavigateTo("home"); }
    public void NavigateTo(string tag)
    {
        SetFullscreen(false);
        var type = tag switch { "home" => typeof(HomePage), "live" => typeof(LiveTvPage), "schedule" => typeof(SchedulePage), "leagues" => typeof(LeaguesPage), "highlights" => typeof(HighlightsPage), "myteams" => typeof(MyTeamsPage), "search" => typeof(SearchPage), "multi" => typeof(MultiViewPage), "settings" => typeof(SettingsPage), "onboarding" => typeof(OnboardingPage), _ => null };
        if (type is null) return;
        if (ContentFrame.CurrentSourcePageType == type) { if (ContentFrame.Content is HomePage home) home.ShowTop(); return; }
        Navigate(type);
    }
    public void Navigate(Type type, object? parameter = null) => ContentFrame.Navigate(type, parameter, App.Data.Settings.ReducedMotion ? new Microsoft.UI.Xaml.Media.Animation.SuppressNavigationTransitionInfo() : new Microsoft.UI.Xaml.Media.Animation.EntranceNavigationTransitionInfo());
    public void SelectNavItem(string? tag)
    {
        foreach (var pair in _tabs) pair.Value.Background = pair.Key == tag ? new SolidColorBrush(Windows.UI.Color.FromArgb(38, 225, 234, 242)) : new SolidColorBrush(Colors.Transparent);
    }
    private static string? TagFor(Type type) => type.Name switch { nameof(HomePage) => "home", nameof(LiveTvPage) => "live", nameof(SchedulePage) => "schedule", nameof(LeaguesPage) or nameof(LeagueCenterPage) or nameof(TeamHubPage) => "leagues", nameof(HighlightsPage) => "highlights", nameof(MyTeamsPage) => "myteams", nameof(SearchPage) => "search", nameof(SettingsPage) => "settings", _ => null };
}
