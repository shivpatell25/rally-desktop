using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Automation;
using Rally.Core;
using Windows.UI;
using Windows.Foundation;

namespace Rally.App.Design;

public static class RallyUi
{
    public static readonly Color Ink = Color.FromArgb(255, 3, 7, 9);
    public static readonly Brush White = new SolidColorBrush(Color.FromArgb(255, 244, 245, 247));
    public static readonly Brush Muted = new SolidColorBrush(Color.FromArgb(255, 166, 173, 183));
    public static readonly Brush Surface = new SolidColorBrush(Color.FromArgb(150, 10, 15, 19));
    public static readonly Brush Edge = new SolidColorBrush(Color.FromArgb(45, 158, 178, 194));
    public static readonly FontFamily BodyFont = new("ms-appx:///Assets/inter_variable.ttf#Inter");
    public static readonly FontFamily TitleFont = new("ms-appx:///Assets/sora_variable.ttf#Sora");
    public static TextBlock Text(string value, double size = 15, bool muted = false, bool bold = false) => new()
    {
        Text = value, FontSize = size * (App.Data.Settings.LargeText ? 1.12 : 1), Foreground = muted ? Muted : White, FontFamily = BodyFont,
        FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        HorizontalAlignment = HorizontalAlignment.Left, TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis
    };
    public static TextBlock Heading(string value) { var text = Text(value.ToUpperInvariant(), 13, false, true); text.CharacterSpacing = 120; text.Margin = new Thickness(4, 0, 0, 16); return text; }
    private static readonly Dictionary<string, (ImageSource Source, DateTimeOffset Used)> Images = [];
    public static Image Image(string? url, double width = double.NaN, double height = double.NaN, Stretch stretch = Stretch.Uniform)
    {
        var image = new Image { Width = width, Height = height, Stretch = stretch, IsHitTestVisible = false };
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            if (!Images.TryGetValue(uri.AbsoluteUri, out var cached))
            {
                if (Images.Count >= 96) foreach (var key in Images.OrderBy(p => p.Value.Used).Take(24).Select(p => p.Key).ToArray()) Images.Remove(key);
                ImageSource source = uri.AbsolutePath.EndsWith(".svg", StringComparison.OrdinalIgnoreCase) ? new SvgImageSource(uri) : new BitmapImage { DecodePixelWidth = 640, UriSource = uri };
                cached = (source, DateTimeOffset.UtcNow);
            }
            Images[uri.AbsoluteUri] = (cached.Source, DateTimeOffset.UtcNow); image.Source = cached.Source;
        }
        return image;
    }
    public static Image Asset(string name, double width = double.NaN, double height = double.NaN, Stretch stretch = Stretch.Uniform) => Image($"ms-appx:///Assets/{name}", width, height, stretch);
    public static Button Button(string title, Action? action = null, bool primary = false)
    {
        var button = new Button { Content = title, CornerRadius = new CornerRadius(8), Padding = new Thickness(17, 10, 17, 10),
            FontFamily = BodyFont, FontSize = 13, Foreground = primary ? new SolidColorBrush(Ink) : White,
            Background = primary ? White : Surface, BorderBrush = Edge, BorderThickness = new Thickness(primary ? 0 : 1),
            UseSystemFocusVisuals = true, FocusVisualPrimaryBrush = White, FocusVisualSecondaryBrush = new SolidColorBrush(Ink), FocusVisualPrimaryThickness = new Thickness(App.Data.Settings.HighContrastFocus ? 3 : 1), MinHeight = 40 };
        AutomationProperties.SetName(button, title);
        if (action is not null) button.Click += (_, args) => { if (args.OriginalSource is Button origin && !ReferenceEquals(origin, button)) return; action(); };
        return button;
    }
    public static Button Tile(UIElement body, string name, Action action, bool chrome = false)
    {
        var button = Button(name, action); button.Content = body; button.Padding = new Thickness(0);
        button.Background = chrome ? Surface : new SolidColorBrush(Colors.Transparent);
        button.BorderThickness = new Thickness(chrome ? 1 : 0);
        button.HorizontalAlignment = HorizontalAlignment.Stretch; button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.VerticalContentAlignment = VerticalAlignment.Stretch;
        // A transform leaves layout bounds unchanged. Keyboard and pointer receive
        // the same understated effect; rails reserve room for the expanded edge.
        var scale = new ScaleTransform(); button.RenderTransform = scale; button.RenderTransformOrigin = new Point(.5, .5);
        void Focus(bool active)
        {
            if (App.Data.Settings.ReducedMotion) { scale.ScaleX = scale.ScaleY = active ? 1.035 : 1; return; }
            Animate(scale, "ScaleX", active ? 1.035 : 1, 140); Animate(scale, "ScaleY", active ? 1.035 : 1, 140);
        }
        button.GotFocus += (_, _) => Focus(true); button.LostFocus += (_, _) => Focus(false);
        button.PointerEntered += (_, _) => Focus(true); button.PointerExited += (_, _) => { if (button.FocusState == FocusState.Unfocused) Focus(false); };
        return button;
    }
    public static void Animate(DependencyObject target, string property, double to, int duration = 220, Action? completed = null)
    {
        var animation = new DoubleAnimation { To = to, Duration = TimeSpan.FromMilliseconds(App.Data.Settings.ReducedMotion ? 0 : duration),
            EnableDependentAnimation = true, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        Storyboard.SetTarget(animation, target); Storyboard.SetTargetProperty(animation, property);
        var board = new Storyboard(); board.Children.Add(animation); if (completed is not null) board.Completed += (_, _) => completed(); board.Begin();
    }
    public static Border Panel(UIElement child, Thickness? padding = null) => new() { Child = child, Padding = padding ?? new Thickness(16),
        CornerRadius = new CornerRadius(8), Background = Surface, BorderBrush = Edge, BorderThickness = new Thickness(1) };
    public static StackPanel Column(params UIElement[] children) { var panel = new StackPanel { Spacing = 12 }; foreach (var child in children) panel.Children.Add(child); return panel; }
    public static StackPanel Row(params UIElement[] children) { var panel = Column(children); panel.Orientation = Orientation.Horizontal; return panel; }
    public static Grid Flow(params UIElement[] children)
    {
        var grid = new Grid { ColumnSpacing = 10, RowSpacing = 10 };
        foreach (var child in children) grid.Children.Add(child);
        void Arrange(double width)
        {
            var count = Math.Max(1, Math.Min(children.Length, (int)(Math.Max(180, width) / 180)));
            if (grid.ColumnDefinitions.Count == count) return;
            grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear();
            for (var i = 0; i < count; i++) grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            for (var i = 0; i < children.Length; i++) { if (i % count == 0) grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); Grid.SetColumn((FrameworkElement)children[i], i % count); Grid.SetRow((FrameworkElement)children[i], i / count); }
        }
        Arrange(900); grid.SizeChanged += (_, e) => Arrange(e.NewSize.Width); return grid;
    }
    public static ScrollViewer Scroll(UIElement child) => new() { Content = child, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 0, 24) };
    public static Grid Columns(int count, double spacing = 16) { var grid = new Grid { ColumnSpacing = spacing }; for (int i = 0; i < count; i++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); return grid; }
    public static void Put(Grid grid, UIElement child, int column, int row = 0) { Grid.SetColumn((FrameworkElement)child, column); Grid.SetRow((FrameworkElement)child, row); grid.Children.Add(child); }
    public static string Matchup(SportEvent ev) => ev.AwayTeam is not null && ev.HomeTeam is not null ? $"{ev.AwayTeam.Name} vs {ev.HomeTeam.Name}" : ev.Name;
    public static string Status(SportEvent ev) => ev.Status switch { EventStatus.Live => "LIVE", EventStatus.Halftime => "HALFTIME", EventStatus.Finished => "FINAL", EventStatus.Canceled => "CANCELED", EventStatus.Delayed => "DELAYED", _ => ev.StartTime.LocalDateTime.ToString("ddd · h:mm tt") };
    public static string Score(SportEvent ev) => $"{ev.AwayTeam?.Abbreviation} {ev.ScoreAway?.ToString() ?? "—"} — {ev.HomeTeam?.Abbreviation} {ev.ScoreHome?.ToString() ?? "—"}";
    public static Color TeamColor(Team? team)
    {
        var raw = team?.Color?.TrimStart('#');
        if (raw?.Length == 6 && uint.TryParse(raw, System.Globalization.NumberStyles.HexNumber, null, out var value))
            return Color.FromArgb(255, (byte)(value >> 16), (byte)(value >> 8), (byte)value);
        return Color.FromArgb(255, 38, 46, 57);
    }
    public static Image TeamLogo(Team? team, double size)
    {
        var original = team?.LogoUrl; var alternate = original?.Replace("/teamlogos/mlb/500/", "/teamlogos/mlb/500-dark/");
        var image = Image(alternate, size, size);
        if (original != alternate) image.ImageFailed += (_, _) => { if (Uri.TryCreate(original, UriKind.Absolute, out var uri)) image.Source = new BitmapImage(uri); };
        return image;
    }
    public static Grid TeamArtwork(SportEvent ev, bool showScore = true)
    {
        var art = Columns(3, 8); art.Height = 142; art.SizeChanged += (_, args) => { if (args.NewSize.Width > 1) art.Height = args.NewSize.Width / 2.65; }; art.ColumnDefinitions[1].Width = GridLength.Auto; art.Padding = new Thickness(22, 20, 22, 20);
        art.Background = new LinearGradientBrush { StartPoint = new Point(0, .5), EndPoint = new Point(1, .5), GradientStops = {
            new GradientStop { Color = TeamColor(ev.AwayTeam), Offset = 0 }, new GradientStop { Color = Color.FromArgb(255, 17, 23, 29), Offset = .5 }, new GradientStop { Color = TeamColor(ev.HomeTeam), Offset = 1 } } };
        Put(art, TeamLogo(ev.AwayTeam, 60), 0);
        var score = Text(showScore && ev.Status is EventStatus.Live or EventStatus.Halftime or EventStatus.Finished ? $"{ev.ScoreAway?.ToString() ?? "—"}  —  {ev.ScoreHome?.ToString() ?? "—"}" : "VS", 23, false, true);
        score.TextWrapping = TextWrapping.NoWrap; score.HorizontalAlignment = HorizontalAlignment.Center; score.VerticalAlignment = VerticalAlignment.Center; Put(art, score, 1);
        Put(art, TeamLogo(ev.HomeTeam, 60), 2);
        var status = Text(Status(ev), 11, false, true); status.VerticalAlignment = VerticalAlignment.Bottom;
        status.Margin = new Thickness(0, 0, 0, -8); status.Foreground = ev.Status is EventStatus.Live or EventStatus.Halftime ? new SolidColorBrush(Color.FromArgb(255, 255, 60, 65)) : Muted;
        Put(art, status, 0); Grid.SetColumnSpan(status, 3); return art;
    }
    public static Button EventCard(SportEvent ev, Action action, bool hideScore = false)
    {
        var art = TeamArtwork(ev, !hideScore); var border = new Border { Child = art, CornerRadius = new CornerRadius(8) };
        var title = Text(Matchup(ev), 16, false, true); title.MaxLines = 1; title.Margin = new Thickness(4, 4, 4, 0);
        var meta = Text($"{ev.League} · {ev.GameStatusDetail ?? Status(ev)}", 12, true); meta.Margin = new Thickness(4, 0, 4, 0);
        return Tile(Column(border, title, meta), Matchup(ev), action);
    }
    public static Grid SectionHeader(string title, string? action, Action? click)
    {
        var header = new Grid(); var label = Heading(title); label.VerticalAlignment = VerticalAlignment.Center; header.Children.Add(label);
        if (action is not null) { var button = Button(action.ToUpperInvariant(), click); button.Background = new SolidColorBrush(Colors.Transparent); button.BorderThickness = new Thickness(0); button.HorizontalAlignment = HorizontalAlignment.Right; button.FontSize = 11; button.Margin = new Thickness(0, -10, 0, 8); header.Children.Add(button); }
        return header;
    }
    public static Grid Hero(SportEvent ev, Action watch, Action info, string? imageUrl = null)
    {
        var grid = new Grid { MinHeight = 258 };
        grid.Children.Add(new CinematicArtwork(imageUrl ?? ev.VenueImageUrl));
        var status = Text($"{ev.League}  ·  {Status(ev)}", 13, true, true);
        var title = Text(Matchup(ev), 32, false, true); title.FontFamily = TitleFont; title.MaxLines = 2; title.MaxWidth = 650; grid.SizeChanged += (_, args) => title.FontSize = args.NewSize.Height < 170 ? 26 : args.NewSize.Height < 215 ? 30 : args.NewSize.Width >= 1000 ? 42 : 32;
        var context = Text($"{(ev.Status == EventStatus.NotStarted ? ev.StartTime.LocalDateTime.ToString("ddd, MMM d · h:mm tt") : Score(ev))}  ·  {ev.GameStatusDetail}", 16, true);
        var actions = Row(); if (ev.Status is EventStatus.Live or EventStatus.Halftime) actions.Children.Add(Button("▶  Watch Live", watch, true)); actions.Children.Add(Button("More Info", info, ev.Status is not (EventStatus.Live or EventStatus.Halftime)));
        var content = Column(status, title, context, Text(ev.Venue ?? "", 12, true), actions); content.Spacing = 7;
        grid.SizeChanged += (_, args) => { var compact = args.NewSize.Height < 170; content.Spacing = compact ? 4 : 7; status.FontSize = compact ? 11 : 13; context.FontSize = compact ? 13 : 16; foreach (var button in actions.Children.OfType<Button>()) { button.MinHeight = compact ? 32 : 40; button.Padding = new Thickness(15, compact ? 6 : 10, 15, compact ? 6 : 10); } };
        content.VerticalAlignment = VerticalAlignment.Center; content.Margin = new Thickness(4, 4, 0, 4); grid.Children.Add(content); return grid;
    }
    public static UIElement SportMark(string league, double size = 38)
    {
        var asset = league switch { "NFL" => "nfl", "NBA" => "nba", "MLB" => "mlb", "NHL" => "nhl", "MLS" => "mls", "EPL" => "epl", "Champions League" => "ucl", "La Liga" => "laliga", "Serie A" => "seriea", _ => null };
        if (league is "Soccer" or "Tennis") return Asset($"sport_{league.ToLowerInvariant()}.svg", size, size);
        if (league is "NCAAF" or "NCAAB") return Asset("sport_ncaa.svg", size, size);
        if (asset is not null) return Asset($"league_mark_{asset}.png", size, size);
        // Vector sport marks remain crisp at every DPI; distinct ball icons avoid
        // passing a specific soccer competition's logo off as the entire sport.
        var symbol = league switch { "Soccer" => "⚽", "Tennis" => "◉", "UFC" => "UFC", "NCAAF" => "NCAA\nFB", "NCAAB" => "NCAA\nBB", _ => league };
        var text = Text(symbol, league == "UFC" ? 18 : 11, false, true);
        text.TextAlignment = TextAlignment.Center;
        text.VerticalAlignment = VerticalAlignment.Center;
        if (league == "UFC") text.FontStyle = Windows.UI.Text.FontStyle.Italic;
        return new Viewbox { Width = size, Height = size, Stretch = Stretch.Uniform, Child = text };
    }
    public static Button SportTile(string league, Action action)
    {
        var label = Text(league, 11, false); label.HorizontalAlignment = HorizontalAlignment.Center;
        var stack = Column(SportMark(league), label); stack.Spacing = 6; stack.HorizontalAlignment = HorizontalAlignment.Center; stack.Margin = new Thickness(10);
        return Tile(stack, league, action, true);
    }
    public static UIElement Empty(string title, string detail, string? action = null, Action? click = null)
    {
        var panel = Column(Text(title, 19, false, true), Text(detail, 14, true)); panel.Margin = new Thickness(4, 14, 4, 20);
        if (action is not null) panel.Children.Add(Button(action, click)); return panel;
    }
    private static readonly SemaphoreSlim DialogGate = new(1, 1);
    public static async Task<ContentDialogResult> ShowDialog(ContentDialog dialog)
    {
        if (!await DialogGate.WaitAsync(0)) return ContentDialogResult.None;
        try { return dialog.XamlRoot is not null ? await dialog.ShowAsync() : ContentDialogResult.None; }
        catch (OperationCanceledException) { return ContentDialogResult.None; }
        finally { DialogGate.Release(); }
    }
    public static async Task Dialog(FrameworkElement owner, string title, UIElement content)
    {
        var dialog = new ContentDialog { XamlRoot = owner.XamlRoot, Title = title, Content = content, CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close, RequestedTheme = ElementTheme.Dark };
        await ShowDialog(dialog);
    }
}
