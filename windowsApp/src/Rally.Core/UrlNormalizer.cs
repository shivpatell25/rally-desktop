using System.Text.RegularExpressions;

// 1:1 port of UrlNormalizer (SettingsStore.swift) / PortalUrlNormalizer.kt.
namespace Rally.Core;

public static class UrlNormalizer
{
    public static string NormalizePortal(string raw)
    {
        var value = raw.Trim();
        if (value.Length == 0) return "";
        if (!value.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !value.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            value = "http://" + value;
        value = RepairRemoteColonTypo(value);
        if (value.EndsWith("/")) value = value[..^1];
        foreach (var suffix in new[] { "/server/load.php", "/load.php" })
            if (value.EndsWith(suffix, StringComparison.Ordinal)) value = value[..^suffix.Length];
        value = value.Trim('/');
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) return "";
        var path = uri.AbsolutePath.Trim('/');
        return $"{uri.Scheme}://{uri.Authority}{(path.Length == 0 ? "" : "/" + path)}";
    }

    public static string? NormalizeAddon(string raw)
    {
        var value = raw.Trim();
        if (value.Length == 0) return null;
        if (!value.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !value.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            value = "https://" + value;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) return null;
        if (!uri.AbsolutePath.EndsWith("manifest.json", StringComparison.Ordinal))
        {
            var path = (uri.AbsolutePath.Trim('/') + "/manifest.json").Trim('/');
            var b = new UriBuilder(uri) { Path = "/" + path };
            return b.Uri.ToString();
        }
        return uri.ToString();
    }

    public static string NormalizeXtreamServer(string raw)
    {
        var value = raw.Trim();
        if (value.Length == 0) return "";
        if (!value.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !value.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            value = "http://" + value;
        foreach (var suffix in new[] { "/player_api.php", "/get.php" })
            if (value.EndsWith(suffix, StringComparison.Ordinal)) value = value[..^suffix.Length];
        value = value.Trim('/');
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) return "";
        var b = new UriBuilder(uri) { Query = "", Fragment = "" };
        return b.Uri.ToString().Trim('/');
    }

    private static string RepairRemoteColonTypo(string value)
    {
        var schemeEnd = value.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd < 0) return value;
        var authStart = schemeEnd + 3;
        var pathStart = value.IndexOf('/', authStart);
        if (pathStart < 0) pathStart = value.Length;
        var authority = value[authStart..pathStart];
        if (authority.StartsWith("[") || authority.Contains('@')) return value;
        var colon = authority.LastIndexOf(':');
        if (colon <= 0) return value;
        var suffix = authority[(colon + 1)..];
        if (suffix.Length == 0 || suffix.All(char.IsDigit)) return value;
        return value[..authStart] + authority[..colon] + "." + suffix + value[pathStart..];
    }
}
