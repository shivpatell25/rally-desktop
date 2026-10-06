// In-app update check against GitHub Releases on the shared desktop train
// (shivpatell25/rally-desktop — same tags as macOS). Self-signed side-load:
// the checker reports availability and hands the installer URL to the UI;
// Windows never installs silently.
namespace Rally.Core;

public sealed record RallyRelease(string Tag, string PageUrl, string? AssetUrl, long? AssetSize, string? Notes);

public enum UpdateCheckState { Current, Available, Failed }
public sealed record UpdateCheckResult(UpdateCheckState State, RallyRelease? Release = null);

public static class RallyInfo
{
    // Same train as macOS (packaging/package.sh version argument).
    public const string CurrentVersion = "0.8.2";
}

public sealed class UpdateChecker(HttpClient? http = null)
{
    public const string ReleasesUrl = "https://api.github.com/repos/shivpatell25/rally-desktop/releases/latest";
    private readonly HttpClient _http = http ?? new HttpClient() { Timeout = TimeSpan.FromSeconds(15) };

    public async Task<RallyRelease?> CheckAsync(CancellationToken ct = default) => (await CheckStatusAsync(ct)).Release;

    public async Task<UpdateCheckResult> CheckStatusAsync(CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, ReleasesUrl);
            req.Headers.UserAgent.ParseAdd("Rally/Windows");
            req.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var res = await _http.SendAsync(req, ct).ConfigureAwait(false);
            res.EnsureSuccessStatusCode();
            using var doc = System.Text.Json.JsonDocument.Parse(
                await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            var root = doc.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object) throw new System.Text.Json.JsonException();
            if (root.TryGetProperty("draft", out var draft) && draft.ValueKind == System.Text.Json.JsonValueKind.True)
                return new(UpdateCheckState.Current);
            var tag = root.TryGetProperty("tag_name", out var t) ? t.GetString() ?? "" : "";
            if (tag.Length == 0) throw new System.Text.Json.JsonException();
            if (CompareVersions(tag, RallyInfo.CurrentVersion) <= 0) return new(UpdateCheckState.Current);
            var page = root.TryGetProperty("html_url", out var h) ? h.GetString() : null;
            string? assetUrl = null;
            long? assetSize = null;
            if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                var arch = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
                foreach (var a in assets.EnumerateArray())
                {
                    var name = a.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
                    var lower = name.ToLowerInvariant();
                    if (!lower.Contains("windows") || !lower.Contains(arch) || !(lower.EndsWith(".zip") || lower.EndsWith(".exe") || lower.EndsWith(".msix"))) continue;
                    assetUrl = a.TryGetProperty("browser_download_url", out var u) ? u.GetString() : null;
                    assetSize = a.TryGetProperty("size", out var s) && s.TryGetInt64(out var sz) ? sz : null;
                    break;
                }
            }
            var notes = root.TryGetProperty("body", out var b) ? b.GetString() : null;
            return new(UpdateCheckState.Available, new RallyRelease(tag, page ?? "https://github.com/shivpatell25/rally-desktop/releases", assetUrl, assetSize, notes));
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { return new(UpdateCheckState.Failed); }
    }

    // 1:1 with compareVersions in RallyUpdateManager.kt: stable > rc > beta,
    // numeric suffixes, core padded to 3.
    public static int CompareVersions(string first, string second)
    {
        static (List<int> Core, int Channel, int ChannelNum) Parts(string v)
        {
            var s = v.Trim().TrimStart('v', 'V').ToLowerInvariant();
            var channel = 3;
            var channelNum = 0;
            var dash = s.IndexOf('-');
            string core = s;
            if (dash >= 0)
            {
                core = s[..dash];
                var suffix = s[(dash + 1)..];
                if (suffix.StartsWith("rc")) { channel = 2; int.TryParse(new string(suffix.Skip(2).TakeWhile(char.IsDigit).ToArray()), out channelNum); }
                else if (suffix.StartsWith("beta")) { channel = 1; int.TryParse(new string(suffix.Skip(4).TakeWhile(char.IsDigit).ToArray()), out channelNum); }
                else { channel = 0; int.TryParse(new string(suffix.TakeWhile(char.IsDigit).ToArray()), out channelNum); }
            }
            var nums = core.Split('.').Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0).ToList();
            while (nums.Count < 3) nums.Add(0);
            return (nums, channel, channelNum);
        }
        var a = Parts(first);
        var b = Parts(second);
        for (var i = 0; i < 3; i++)
        {
            if (a.Core[i] != b.Core[i]) return a.Core[i].CompareTo(b.Core[i]);
        }
        if (a.Channel != b.Channel) return a.Channel.CompareTo(b.Channel);
        return a.ChannelNum.CompareTo(b.ChannelNum);
    }
}
