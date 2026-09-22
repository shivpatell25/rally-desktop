using Rally.Core;

namespace Rally.App.Services;

// Wraps UpdateChecker and hands the installer/release URL to the browser —
// Windows never installs silently (self-signed side-load train, same tags as macOS).
public sealed class UpdateService(HttpClient? http = null)
{
    private readonly UpdateChecker _checker = new(http);

    public Task<RallyRelease?> CheckAsync(CancellationToken ct = default) =>
        _checker.CheckAsync(ct);

    public async Task<bool> OpenReleaseAsync(RallyRelease release)
    {
        try
        {
            var url = release.AssetUrl ?? release.PageUrl;
            return await Windows.System.Launcher.LaunchUriAsync(new Uri(url)).AsTask().ConfigureAwait(false);
        }
        catch { return false; }
    }
}
