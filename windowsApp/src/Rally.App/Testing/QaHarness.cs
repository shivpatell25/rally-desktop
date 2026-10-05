#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;
using System.Runtime.InteropServices.WindowsRuntime;
using Rally.App.Views;

namespace Rally.App.Testing;
internal static class QaHarness
{
    private static DispatcherTimer? _timer;
    private static long _modified;
    private static bool _busy;
    public static void Start(MainWindow window)
    {
        Directory.CreateDirectory("C:\\RallyQA");
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
        _timer.Tick += async (_, _) =>
        {
            if (_busy) return;
            var path = "C:\\RallyQA\\command.json";
            if (!File.Exists(path)) return; var modified = File.GetLastWriteTimeUtc(path).Ticks; if (modified == _modified) return; 
            _busy = true;
            try
            {
                string request; using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) using (var reader = new StreamReader(input)) request = reader.ReadToEnd();
                using var doc = JsonDocument.Parse(request); _modified = modified; var root = doc.RootElement;
                if (root.TryGetProperty("noLive", out var noLive)) { FixtureHandler.NoLive = noLive.GetBoolean(); await App.Data.GamesAsync(refresh: true); if (window.Navigator.Content is HomePage refreshed) await refreshed.RefreshForQa(); }
                if (root.TryGetProperty("provider", out var provider)) { var control = Descendants((DependencyObject)window.Content).OfType<ComboBox>().First(c => c.Header as string == "Provider"); control.SelectedIndex = provider.GetInt32(); }
                if (root.TryGetProperty("page", out var page))
                {
                    var name = page.GetString()!;
                    if (name is "event" or "game" or "player" or "multi")
                    {
                        var game = (await App.Data.GamesAsync()).First();
                        window.Navigate(name switch { "event" => typeof(EventDetailPage), "game" => typeof(GameViewPage), "multi" => typeof(MultiViewPage), _ => typeof(PlayerPage) }, name == "player" ? FixtureHandler.VideoUrl : game);
                    }
                    else window.NavigateTo(name);
                }
                if (root.TryGetProperty("guide", out var guide) && window.Navigator.Content is HomePage home) home.SetGuideForQa(guide.GetBoolean());
                if (root.TryGetProperty("fullscreen", out var fullscreen)) window.SetFullscreen(fullscreen.GetBoolean());
                if (root.TryGetProperty("size", out var size)) window.AppWindow.Resize(new Windows.Graphics.SizeInt32(size[0].GetInt32(), size[1].GetInt32()));
                if (root.TryGetProperty("invoke", out var invoke))
                {
                    var button = Roots(window).SelectMany(Descendants).OfType<Button>().FirstOrDefault(b => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(b) == invoke.GetString() || b.Content as string == invoke.GetString());
                    if (button is null) throw new InvalidOperationException("Button missing: " + invoke.GetString());
                    var peer = new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button); ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
                }
                if (root.TryGetProperty("videoCapture", out var videoCapture)) await window.CaptureVideoForQa(videoCapture.GetString()!);
                if (root.TryGetProperty("seek", out var seek)) App.Playback.Seek(seek.GetInt64());
                if (root.TryGetProperty("retry", out _)) await App.Playback.RetryAsync();
                if (root.TryGetProperty("waitPlaying", out _))
                {
                    var deadline = DateTimeOffset.UtcNow.AddSeconds(20);
                    while ((!App.Playback.IsPlaying || !App.Playback.HasVideoFrames) && DateTimeOffset.UtcNow < deadline) await Task.Delay(200);
                    if (!App.Playback.IsPlaying || !App.Playback.HasVideoFrames) throw new TimeoutException("Playback did not display video: " + App.Playback.Status);
                }
                if (root.TryGetProperty("idle", out var idle)) { if (idle.GetBoolean()) await window.IdleForQa(); else window.WakeForQa(); }
                if (root.TryGetProperty("multiCount", out var count) && window.Navigator.Content is MultiViewPage multi) await multi.AddForQa(count.GetInt32());
                if (root.TryGetProperty("multiRetry", out var multiRetry) && window.Navigator.Content is MultiViewPage retryMulti) await retryMulti.RetryForQa(multiRetry.GetInt32());
                if (root.TryGetProperty("waitMultiPlaying", out _) && window.Navigator.Content is MultiViewPage videoMulti) await videoMulti.WaitForVideoForQa();
                if (root.TryGetProperty("followAudio", out var followAudio)) { var control = Descendants((DependencyObject)window.Content).OfType<ToggleSwitch>().First(t => t.Header as string == "Focused Audio"); control.IsOn = followAudio.GetBoolean(); }
                if (root.TryGetProperty("multiFocus", out var multiFocus) && window.Navigator.Content is MultiViewPage audioMulti) audioMulti.FocusForQa(multiFocus.GetInt32(), root.TryGetProperty("selectAudio", out _));
                if (root.TryGetProperty("focus", out var focus))
                {
                    var direction = Enum.Parse<Microsoft.UI.Xaml.Input.FocusNavigationDirection>(focus.GetString()!);
                    if (Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(((FrameworkElement)window.Content).XamlRoot) is null)
                        foreach (var button in Descendants((DependencyObject)window.Content).OfType<Button>()) if (button.Focus(FocusState.Keyboard)) break;
                    var moved = Microsoft.UI.Xaml.Input.FocusManager.TryMoveFocus(direction, new Microsoft.UI.Xaml.Input.FindNextElementOptions { SearchRoot = window.Content });
                    if (!moved) throw new InvalidOperationException("Focus did not move: " + direction);
                }
                if (root.TryGetProperty("capture", out var capture))
                {
                    await Task.Delay(800); var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync((UIElement)window.Content).AsTask().WaitAsync(TimeSpan.FromSeconds(8));
                    var capturePath = capture.GetString()!; var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(capturePath)!); var file = await folder.CreateFileAsync(Path.GetFileName(capturePath), CreationCollisionOption.ReplaceExisting); using var stream = await file.OpenAsync(FileAccessMode.ReadWrite); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                    var pixels = await bitmap.GetPixelsAsync(); encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels.ToArray()); await encoder.FlushAsync();
                }
                var tree = Descendants((DependencyObject)window.Content).OfType<FrameworkElement>().Where(e => e is Button or TextBlock or Microsoft.UI.Xaml.Controls.Primitives.ToggleButton or ComboBox or TextBox).Select(e => new { type = e.GetType().Name, name = Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(e), text = e is TextBlock t ? t.Text : e is Button b ? b.Content as string : null, width = e.ActualWidth, height = e.ActualHeight, visible = e.Visibility.ToString(), focus = e is Control c ? c.FocusState.ToString() : "" });
                File.WriteAllText("C:\\RallyQA\\result.json", JsonSerializer.Serialize(new { success = true, nonce = root.TryGetProperty("nonce", out var nonce) ? nonce.GetString() : "", playback = App.Playback.Diagnostics(), multiview = (window.Navigator.Content as MultiViewPage)?.SnapshotForQa(), tree }));
            }
            catch (IOException) { }
            catch (JsonException) { }
            catch (Exception ex) { File.WriteAllText("C:\\RallyQA\\result.json", JsonSerializer.Serialize(new { success = false, error = ex.ToString() })); }
            finally { _busy = false; }
        };
        _timer.Start();
    }
    private static IEnumerable<DependencyObject> Roots(MainWindow window)
    {
        yield return (DependencyObject)window.Content;
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(((FrameworkElement)window.Content).XamlRoot))
            if (popup.Child is DependencyObject child) yield return child;
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
}
#endif
