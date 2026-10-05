using System.Text.RegularExpressions;

namespace Rally.Core;

public static partial class SettingsValidator
{
    [GeneratedRegex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")]
    private static partial Regex MacPattern();

    public static string? Validate(IptvProvider provider, string portal, string mac,
        string server, string user, string password, IEnumerable<string> addons)
    {
        var portalNormalized = UrlNormalizer.NormalizePortal(portal).Trim();
        var macTrimmed = mac.Trim();
        if (provider == IptvProvider.Stalker)
        {
            if (portalNormalized.Length > 0 && macTrimmed.Length > 0 && !MacPattern().IsMatch(macTrimmed))
                return "That MAC address doesn't look right — use the XX:XX:XX:XX:XX:XX format from your provider.";
        }
        else if (provider == IptvProvider.Xtream)
        {
            var serverNormalized = UrlNormalizer.NormalizeXtreamServer(server).Trim();
            var userTrimmed = user.Trim();
            var any = serverNormalized.Length > 0 || userTrimmed.Length > 0 || password.Length > 0;
            if (any && (serverNormalized.Length == 0 || userTrimmed.Length == 0 || password.Length == 0))
                return "Xtream needs all three: server URL, username, and password — or leave all three empty.";
        }

        foreach (var addon in addons)
        {
            if (UrlNormalizer.NormalizeAddon(addon) is null)
                return "One addon URL doesn't resolve — check it ends in a manifest or a bare host.";
        }
        return null;
    }
}
