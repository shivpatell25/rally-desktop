using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Composition;
using System.Numerics;
namespace Rally.App.Design;

/// <summary>Transparent alpha fade preserves the one window-wide ambient
/// surface. No opaque overlay rectangles create a visible hero lane.</summary>
public sealed class CinematicArtwork : Grid
{
    private LoadedImageSurface? _image, _mask;
    private SpriteVisual? _visual;
    private readonly string? _url;
    public CinematicArtwork(string? url)
    {
        _url = url; IsHitTestVisible = false;
        Loaded += (_, _) => Attach();
        Unloaded += (_, _) => { ElementCompositionPreview.SetElementChildVisual(this, null); _visual?.Dispose(); _visual = null; _image?.Dispose(); _mask?.Dispose(); _image = _mask = null; };
        SizeChanged += (_, _) => Resize();
    }
    private void Attach()
    {
        if (_visual is not null || !Uri.TryCreate(_url, UriKind.Absolute, out var uri)) return;
        var compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        _image = LoadedImageSurface.StartLoadFromUri(uri); _mask = LoadedImageSurface.StartLoadFromUri(new Uri("ms-appx:///Assets/hero-opacity-mask.png"));
        var imageBrush = compositor.CreateSurfaceBrush(_image); imageBrush.Stretch = CompositionStretch.UniformToFill;
        var maskBrush = compositor.CreateSurfaceBrush(_mask); maskBrush.Stretch = CompositionStretch.Fill;
        var fade = compositor.CreateMaskBrush(); fade.Source = imageBrush; fade.Mask = maskBrush;
        _visual = compositor.CreateSpriteVisual(); _visual.Brush = fade; _visual.Opacity = .8f;
        ElementCompositionPreview.SetElementChildVisual(this, _visual); Resize();
    }
    private void Resize()
    {
        if (_visual is null) return;
        _visual.Size = new Vector2((float)(ActualWidth * .78), (float)ActualHeight);
        _visual.Offset = new Vector3((float)(ActualWidth * .22), 0, 0);
    }
}
