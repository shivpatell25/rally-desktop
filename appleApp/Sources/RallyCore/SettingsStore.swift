import CryptoKit
import Foundation
import Security

/// 1:1 port of `PortalUrlNormalizer` — one source of truth for user-entered URLs.
public enum UrlNormalizer {
    public static func normalizePortal(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://" + value
        }
        value = repairRemoteColonTypo(value)
        if value.hasSuffix("/") { value = String(value.dropLast()) }
        for suffix in ["/server/load.php", "/load.php"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: value), comps.host != nil else { return "" }
        comps.path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.path = comps.path.isEmpty ? "" : "/" + comps.path
        return comps.string ?? ""
    }

    public static func normalizeAddon(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        guard var comps = URLComponents(string: value), comps.host != nil else { return nil }
        if !comps.path.hasSuffix("manifest.json") {
            comps.path = "/" + (comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/manifest.json")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return comps.string
    }

    public static func normalizeXtreamServer(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://" + value
        }
        for suffix in ["/player_api.php", "/get.php"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: value), comps.host != nil else { return "" }
        comps.query = nil; comps.fragment = nil
        return comps.string ?? ""
    }

    private static func repairRemoteColonTypo(_ value: String) -> String {
        guard let schemeEnd = value.range(of: "://") else { return value }
        let authStart = schemeEnd.upperBound
        let pathStart = value[authStart...].firstIndex(of: "/") ?? value.endIndex
        var authority = String(value[authStart..<pathStart])
        if authority.hasPrefix("[") || authority.contains("@") { return value }
        guard let colon = authority.lastIndex(of: ":"), colon != authority.startIndex else { return value }
        let suffix = String(authority[authority.index(after: colon)...])
        if suffix.isEmpty || suffix.allSatisfy({ $0.isNumber }) { return value }
        authority.replaceSubrange(colon...colon, with: ".")
        return String(value[..<authStart]) + authority + String(value[pathStart...])
    }
}

public struct StreamHealth: Codable, Sendable, Equatable {
    public var successes: Int
    public var failures: Int
    public var stalls: Int
    public var averageStartupMs: Int64
    public var lastUpdatedMs: Int64
    public init(successes: Int = 0, failures: Int = 0, stalls: Int = 0, averageStartupMs: Int64 = 0, lastUpdatedMs: Int64 = 0) {
        self.successes = successes; self.failures = failures; self.stalls = stalls
        self.averageStartupMs = averageStartupMs; self.lastUpdatedMs = lastUpdatedMs
    }
    /// 1:1 with `PreferencesManager.StreamHealth.score`.
    public var score: Int {
        min(120, max(-240, successes * 24 - failures * 55 - stalls * 12 - Int(averageStartupMs / 750)))
    }
}

/// Settings + secrets. Mirrors `PreferencesManager` keys/defaults.
/// Plist-safe prefs in UserDefaults (stored @Published); token + Xtream
/// password in Keychain.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let defaultAddon = "https://sports.highfly.to/manifest.json"
    public static let defaultSportsOrder = ["NFL", "NCAAF", "NBA", "NCAAB", "MLB", "NHL", "EPL", "La Liga", "Champions League", "Serie A"]

    private let defaults: UserDefaults
    private static let keychainService = "com.shiv.rally.macos"

    @Published public var iptvProvider: IptvProvider {
        didSet { defaults.set(iptvProvider.rawValue, forKey: "iptv_provider") }
    }
    @Published public var portalUrl: String {
        didSet {
            let norm = UrlNormalizer.normalizePortal(portalUrl)
            defaults.set(norm, forKey: "portal_url")
            if norm != portalUrl { portalUrl = norm }
        }
    }
    @Published public var xtreamServerUrl: String {
        didSet {
            let norm = UrlNormalizer.normalizeXtreamServer(xtreamServerUrl)
            defaults.set(norm, forKey: "xtream_server_url")
            if norm != xtreamServerUrl { xtreamServerUrl = norm }
        }
    }
    @Published public var xtreamUsername: String {
        didSet { defaults.set(xtreamUsername.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "xtream_username") }
    }
    @Published public var serialNumber: String {
        didSet { defaults.set(serialNumber, forKey: "serial_number") }
    }
    @Published public var deviceId: String {
        didSet { defaults.set(deviceId, forKey: "device_id") }
    }
    @Published public var stremioAddonUrls: [String] {
        didSet {
            let clean = Array(Set(stremioAddonUrls.compactMap(UrlNormalizer.normalizeAddon))).sorted()
            defaults.set(try? JSONEncoder().encode(clean), forKey: "stremio_addon_urls_json")
            if clean != stremioAddonUrls { stremioAddonUrls = clean }
        }
    }
    @Published public var enabledLeagues: Set<String> {
        didSet { defaults.set(Array(enabledLeagues), forKey: "enabled_leagues") }
    }
    @Published public var favoriteTeams: Set<String> {
        didSet { defaults.set(Array(favoriteTeams), forKey: "favorite_teams") }
    }
    @Published public var favoriteTeamProfiles: [FavoriteTeam] {
        didSet {
            var seen = Set<String>()
            let deduped = favoriteTeamProfiles.filter { seen.insert($0.key).inserted }
            defaults.set(try? JSONEncoder().encode(deduped), forKey: "favorite_team_profiles_v2")
            if deduped != favoriteTeamProfiles { favoriteTeamProfiles = deduped }
        }
    }
    @Published public var liveGameAlertsEnabled: Bool {
        didSet { defaults.set(liveGameAlertsEnabled, forKey: "live_game_alerts_enabled") }
    }
    @Published public var redZoneAlertsEnabled: Bool {
        didSet { defaults.set(redZoneAlertsEnabled, forKey: "redzone_alerts_enabled") }
    }
    @Published public var lowLatencyMode: Bool {
        didSet { defaults.set(lowLatencyMode, forKey: "low_latency_mode") }
    }
    @Published public var audioNormalizationEnabled: Bool {
        didSet { defaults.set(audioNormalizationEnabled, forKey: "audio_normalization_enabled") }
    }
    @Published public var adaptiveQualityEnabled: Bool {
        didSet { defaults.set(adaptiveQualityEnabled, forKey: "adaptive_quality_enabled") }
    }
    @Published public var reducedMotion: Bool {
        didSet { defaults.set(reducedMotion, forKey: "reduced_motion") }
    }
    @Published public var largeText: Bool {
        didSet { defaults.set(largeText, forKey: "large_text") }
    }
    @Published public var setupComplete: Bool {
        didSet { defaults.set(setupComplete, forKey: "setup_complete") }
    }
    @Published public var channelCacheIdentity: String {
        didSet { defaults.set(channelCacheIdentity, forKey: "channel_cache_identity") }
    }
    @Published public var sportsOrder: [String] {
        didSet { defaults.set(sportsOrder.joined(separator: ","), forKey: "sports_order") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        iptvProvider = IptvProvider(rawValue: defaults.string(forKey: "iptv_provider") ?? "") ?? .stalker
        portalUrl = defaults.string(forKey: "portal_url") ?? ""
        xtreamServerUrl = defaults.string(forKey: "xtream_server_url") ?? ""
        xtreamUsername = defaults.string(forKey: "xtream_username") ?? ""
        serialNumber = defaults.string(forKey: "serial_number") ?? ""
        deviceId = defaults.string(forKey: "device_id") ?? ""
        if let data = defaults.data(forKey: "stremio_addon_urls_json"),
           let list = try? JSONDecoder().decode([String].self, from: data), !list.isEmpty {
            stremioAddonUrls = list
        } else if let legacy = defaults.string(forKey: "stremio_addon_url")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !legacy.isEmpty, let norm = UrlNormalizer.normalizeAddon(legacy) {
            stremioAddonUrls = [norm]
        } else {
            stremioAddonUrls = [Self.defaultAddon]
        }
        enabledLeagues = Set(defaults.stringArray(forKey: "enabled_leagues") ?? [])
        favoriteTeams = Set(defaults.stringArray(forKey: "favorite_teams") ?? [])
        if let data = defaults.data(forKey: "favorite_team_profiles_v2"),
           let list = try? JSONDecoder().decode([FavoriteTeam].self, from: data) {
            favoriteTeamProfiles = list
        } else {
            favoriteTeamProfiles = []
        }
        liveGameAlertsEnabled = defaults.object(forKey: "live_game_alerts_enabled") as? Bool ?? true
        redZoneAlertsEnabled = defaults.object(forKey: "redzone_alerts_enabled") as? Bool ?? true
        lowLatencyMode = defaults.object(forKey: "low_latency_mode") as? Bool ?? true
        audioNormalizationEnabled = defaults.object(forKey: "audio_normalization_enabled") as? Bool ?? true
        adaptiveQualityEnabled = defaults.object(forKey: "adaptive_quality_enabled") as? Bool ?? true
        reducedMotion = defaults.bool(forKey: "reduced_motion")
        largeText = defaults.bool(forKey: "large_text")
        setupComplete = defaults.bool(forKey: "setup_complete")
        channelCacheIdentity = defaults.string(forKey: "channel_cache_identity") ?? ""
        if let raw = defaults.string(forKey: "sports_order"), !raw.isEmpty {
            let saved = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            sportsOrder = saved + Self.defaultSportsOrder.filter { !saved.contains($0) }
        } else {
            sportsOrder = Self.defaultSportsOrder
        }
    }

    public var xtreamPassword: String {
        get { keychainGet("xtream_password") ?? "" }
        set { keychainSet(newValue, account: "xtream_password"); objectWillChange.send() }
    }
    public var authToken: String {
        get { keychainGet("auth_token") ?? "" }
        set { keychainSet(newValue, account: "auth_token"); objectWillChange.send() }
    }
    /// Auto-provisioned once, like Android (`00:1A:79:*`).
    public var macAddress: String {
        get {
            let saved = (defaults.string(forKey: "mac_address") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !saved.isEmpty { return saved }
            let mac = "00:1A:79:" + (0..<3).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
            defaults.set(mac, forKey: "mac_address")
            return mac
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "mac_address"); objectWillChange.send() }
    }

    public var hasCredentials: Bool { setupComplete || !portalUrl.isEmpty || !stremioAddonUrls.isEmpty }

    /// Credentials the user actually entered. The bundled default addon is
    /// excluded: a fresh install must hit onboarding (Android ships no default
    /// addon at all and contacts nothing until configured).
    public var hasUserCredentials: Bool {
        setupComplete || !portalUrl.isEmpty || !xtreamServerUrl.isEmpty || !xtreamUsername.isEmpty
            || stremioAddonUrls.contains { $0.lowercased() != Self.defaultAddon.lowercased() }
    }

    /// First-run gate (Android `startDest`): onboarding until setup is saved
    /// or the user already configured a source.
    public var needsOnboarding: Bool { !setupComplete && !hasUserCredentials }

    /// Toggles by `league:id`, mirroring `toggleFavoriteTeam` (also keeps the legacy name set).
    @discardableResult
    public func toggleFavoriteTeam(_ team: FavoriteTeam) -> Bool {
        if let i = favoriteTeamProfiles.firstIndex(where: { $0.key == team.key }) {
            favoriteTeamProfiles.remove(at: i)
            favoriteTeams.remove(team.name)
            return false
        }
        favoriteTeamProfiles.append(team)
        favoriteTeams.insert(team.name)
        return true
    }
    public func isFavoriteTeam(id: String, league: String) -> Bool {
        favoriteTeamProfiles.contains { $0.id == id && $0.league.caseInsensitiveCompare(league) == .orderedSame }
    }

    public func streamHealth(target: String) -> StreamHealth {
        guard let data = defaults.data(forKey: "stream_health_\(healthKey(target))"),
              let h = try? JSONDecoder().decode(StreamHealth.self, from: data) else { return StreamHealth() }
        return h
    }
    public func recordStreamSuccess(target: String, startupMs: Int64) {
        var h = streamHealth(target: target)
        h.successes = min(100, h.successes + 1)
        h.averageStartupMs = h.successes <= 1 ? startupMs : (h.averageStartupMs * Int64(h.successes - 1) + startupMs) / Int64(h.successes)
        h.lastUpdatedMs = Int64(Date().timeIntervalSince1970 * 1000)
        saveStreamHealth(target: target, health: h)
    }
    public func recordStreamFailure(target: String) {
        var h = streamHealth(target: target)
        h.failures = min(100, h.failures + 1)
        h.lastUpdatedMs = Int64(Date().timeIntervalSince1970 * 1000)
        saveStreamHealth(target: target, health: h)
    }
    public func recordStreamStall(target: String) {
        var h = streamHealth(target: target)
        h.stalls = min(200, h.stalls + 1)
        h.lastUpdatedMs = Int64(Date().timeIntervalSince1970 * 1000)
        saveStreamHealth(target: target, health: h)
    }
    private func saveStreamHealth(target: String, health: StreamHealth) {
        defaults.set(try? JSONEncoder().encode(health), forKey: "stream_health_\(healthKey(target))")
    }
    func healthKey(_ target: String) -> String {
        SHA256.hash(data: Data(target.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    public func clearCredentials() {
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        keychainDelete("auth_token"); keychainDelete("xtream_password")
        objectWillChange.send()
    }

    // MARK: - Keychain
    private func keychainGet(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func keychainSet(_ value: String, account: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = q; add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
    private func keychainDelete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
