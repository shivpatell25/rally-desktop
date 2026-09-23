import Foundation

/// Save-time validation for provider settings. 1:1 with
/// `SettingsViewModel.saveConfiguration`: nothing persists until the draft
/// validates, so typos fail inline instead of at playback.
public enum SettingsValidator {
    private static let macPattern = "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"

    /// Returns the blocking error copy, or nil when the draft may be saved.
    /// Empty-everything is valid (clears the provider back to unconfigured).
    public static func validate(provider: IptvProvider,
                                portal: String, mac: String,
                                server: String, user: String, pass: String,
                                addons: [String]) -> String? {
        let portalNorm = UrlNormalizer.normalizePortal(portal).trimmingCharacters(in: .whitespacesAndNewlines)
        let macTrimmed = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .stalker {
            if !portalNorm.isEmpty, !macTrimmed.isEmpty,
               macTrimmed.range(of: macPattern, options: .regularExpression) == nil {
                return "That MAC address doesn't look right — use the XX:XX:XX:XX:XX:XX format from your provider."
            }
        } else {
            let serverNorm = UrlNormalizer.normalizeXtreamServer(server).trimmingCharacters(in: .whitespacesAndNewlines)
            let userTrimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
            let anyXtream = !serverNorm.isEmpty || !userTrimmed.isEmpty || !pass.isEmpty
            if anyXtream && (serverNorm.isEmpty || userTrimmed.isEmpty || pass.isEmpty) {
                return "Xtream needs all three: server URL, username, and password — or leave all three empty."
            }
        }
        for addon in addons {
            if UrlNormalizer.normalizeAddon(addon) == nil {
                return "One addon URL doesn't resolve — check it ends in a manifest or a bare host."
            }
        }
        return nil
    }
}
