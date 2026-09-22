import Foundation

/// Xtream Codes client. 1:1 port of `XtreamApi` + `XtreamIptvRepositoryImpl` +
/// `XtreamUrlBuilder`: player_api auth (user_info), live categories + streams,
/// short EPG, `/live/user/pass/<id>.m3u8` URLs. 15-min channel TTL, 5-min auth
/// TTL, all keyed by server|user|pass identity. Memory-only catalog — never
/// touches the Stalker cache.
public final class XtreamClient: @unchecked Sendable {
    private let session: URLSession
    private let settings: SettingsStore
    private let lock = NSLock()
    private var cachedChannels: [IptvChannel] = []
    private var cachedAt = Date.distantPast
    private var authenticatedUntil = Date.distantPast
    private var cacheIdentity = ""
    private var guides: [String: (guide: ChannelGuide, at: Date)] = [:]

    private static let channelTTL: TimeInterval = 15 * 60
    private static let guideTTL: TimeInterval = 2 * 60
    private static let authTTL: TimeInterval = 5 * 60
    private let channelDisk: ChannelDiskStore

    public init(session: URLSession = .shared, settings: SettingsStore, cacheDirectory: URL? = nil) {
        self.session = session
        self.settings = settings
        self.channelDisk = ChannelDiskStore(directory: cacheDirectory)
    }

    struct Account: Equatable {
        var server: String
        var username: String
        var password: String
        var identity: String { "\(server)|\(username)|\(password)" }
    }

    func account() async -> Account? {
        await MainActor.run {
            let server = settings.xtreamServerUrl, user = settings.xtreamUsername, pass = settings.xtreamPassword
            guard !server.isEmpty, !user.isEmpty, !pass.isEmpty else { return nil }
            return Account(server: server, username: user, password: pass)
        }
    }

    // MARK: - URL builder (mirrors XtreamUrlBuilder, no credential logging)

    func playerApi(_ a: Account, action: String? = nil) -> URL? {
        guard var comps = URLComponents(string: a.server) else { return nil }
        comps.path = "/player_api.php"
        var items = [URLQueryItem(name: "username", value: a.username),
                     URLQueryItem(name: "password", value: a.password)]
        if let action, !action.isEmpty { items.append(URLQueryItem(name: "action", value: action)) }
        comps.queryItems = items
        return comps.url
    }

    func liveStream(_ a: Account, streamId: String, ext: String = "m3u8") -> URL? {
        guard var comps = URLComponents(string: a.server) else { return nil }
        comps.path = "/live/\(a.username)/\(a.password)/\(streamId.trimmingCharacters(in: .whitespacesAndNewlines)).\(ext)"
        comps.queryItems = nil
        return comps.url
    }

    // MARK: - Auth

    @discardableResult
    public func authenticate() async -> Bool {
        guard let a = await account() else { return false }
        let now = Date()
        if lock.withLock({ cacheIdentity == a.identity && now < authenticatedUntil }) { return true }
        guard let url = playerApi(a), let root = await requestJson(url) as? [String: Any],
              let info = root["user_info"] as? [String: Any] else { return false }
        let auth = str(info, keys: ["auth"])
        let status = str(info, keys: ["status"])
        let accepted = auth == nil || auth == "1" || auth?.lowercased() == "true"
        let active = status == nil || status?.isEmpty == true || status?.lowercased() == "active" || status == "1"
        guard accepted && active else {
            lock.withLock { authenticatedUntil = .distantPast }
            return false
        }
        lock.withLock { cacheIdentity = a.identity; authenticatedUntil = Date().addingTimeInterval(Self.authTTL) }
        return true
    }

    // MARK: - Channels

    public func getChannels() async -> [IptvChannel] {
        guard let a = await account() else { return [] }
        let now = Date()
        if lock.withLock({ cacheIdentity == a.identity && !cachedChannels.isEmpty && now.timeIntervalSince(cachedAt) < Self.channelTTL }) {
            return lock.withLock { cachedChannels }
        }
        if lock.withLock({ cachedChannels.isEmpty }),
           let disk = channelDisk.loadFresh(identity: a.identity), !disk.isEmpty {
            lock.withLock { cachedChannels = disk; cachedAt = Date(); cacheIdentity = a.identity }
            return disk
        }
        guard await authenticate() else {
            let memory = lock.withLock { cacheIdentity == a.identity ? cachedChannels : [] }
            return memory.isEmpty ? (channelDisk.loadAny(identity: a.identity) ?? []) : memory
        }
        let fresh = await fetchChannels(a)
        if fresh.isEmpty {
            let memory = lock.withLock { cachedChannels }
            return memory.isEmpty ? (channelDisk.loadAny(identity: a.identity) ?? []) : memory
        }
        return fresh
    }

    public func refreshChannels() async -> [IptvChannel] {
        lock.withLock { cachedChannels = []; cachedAt = .distantPast; authenticatedUntil = .distantPast; cacheIdentity = ""; guides.removeAll() }
        return await getChannels()
    }

    private func fetchChannels(_ a: Account) async -> [IptvChannel] {
        async let cats = requestJson(playerApi(a, action: "get_live_categories"))
        async let streams = requestJson(playerApi(a, action: "get_live_streams"))
        let categories = parseList(await cats).reduce(into: [:]) { (m: inout [String: String], o) in
            m[str(o, keys: ["category_id", "id"]) ?? ""] = str(o, keys: ["category_name", "name"]) ?? "Live TV"
        }
        let channels = parseList(await streams).compactMap { o -> IptvChannel? in
            guard let streamId = str(o, keys: ["stream_id", "id"]) else { return nil }
            let direct = str(o, keys: ["direct_source"]).flatMap { $0.hasPrefix("http://") || $0.hasPrefix("https://") ? $0 : nil }
            return IptvChannel(
                id: "xtream:\(streamId)",
                number: str(o, keys: ["num"]) ?? streamId,
                name: str(o, keys: ["name", "stream_name"]) ?? "Channel \(streamId)",
                category: categories[str(o, keys: ["category_id"]) ?? ""] ?? str(o, keys: ["category_name"]) ?? "Live TV",
                logoUrl: str(o, keys: ["stream_icon"]),
                streamUrl: direct,
                supportsCatchUp: boolVal(o, key: "tv_archive"),
                archiveDurationHours: intVal(o, key: "tv_archive_duration")
            )
        }.uniquified()
        lock.withLock { cachedChannels = channels; cachedAt = Date(); cacheIdentity = a.identity }
        if !channels.isEmpty { channelDisk.save(channels, identity: a.identity) }
        return channels
    }

    // MARK: - Stream URL + guide

    public func resolveStreamUrl(channelId: String) async -> String {
        if channelId.hasPrefix("http://") || channelId.hasPrefix("https://") { return channelId }
        guard let a = await account() else { return channelId }
        if let direct = lock.withLock({ cachedChannels.first(where: { $0.id == channelId })?.streamUrl }), !direct.isEmpty {
            return direct
        }
        let streamId = channelId.replacingOccurrences(of: "^xtream:", with: "", options: .regularExpression)
        return liveStream(a, streamId: streamId)?.absoluteString ?? channelId
    }

    public func getGuide(channelId: String) async -> ChannelGuide? {
        guard await account() != nil else { return nil }
        if let g = lock.withLock({ guides[channelId] }), Date().timeIntervalSince(g.at) < Self.guideTTL { return g.guide }
        guard await authenticate(), let a = await account(),
              let base = playerApi(a, action: "get_short_epg")?.absoluteString else {
            return lock.withLock { guides[channelId]?.guide }
        }
        let streamId = channelId.replacingOccurrences(of: "^xtream:", with: "", options: .regularExpression)
        let url = URL(string: base + "&stream_id=\(streamId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? streamId)&limit=10")!
        guard let guide = parseGuide(await requestJson(url)) else {
            return lock.withLock { guides[channelId]?.guide }
        }
        lock.withLock { guides[channelId] = (guide, Date()) }
        return guide
    }

    func parseGuide(_ root: Any?) -> ChannelGuide? {
        let entries = parseList(root).compactMap { o -> EpgProgram? in
            guard let title = str(o, keys: ["title", "name"]), !title.isEmpty else { return nil }
            return EpgProgram(title: title, description: str(o, keys: ["description"]),
                startTime: instant(str(o, keys: ["start_timestamp", "start"])),
                endTime: instant(str(o, keys: ["stop_timestamp", "end"])))
        }
        guard !entries.isEmpty else { return nil }
        let now = Date()
        let current = entries.first { ($0.startTime ?? .distantFuture) <= now && now < ($0.endTime ?? .distantPast) }
        let next = entries.first { now < ($0.startTime ?? .distantPast) }
        return ChannelGuide(now: current ?? entries.first, next: next ?? entries.dropFirst().first)
    }

    // MARK: - Transport + JSON

    private func requestJson(_ url: URL?) async -> Any? {
        guard let url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func parseList(_ root: Any?) -> [[String: Any]] {
        if let arr = root as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
        guard let obj = root as? [String: Any] else { return [] }
        for key in ["data", "live_streams", "epg_listings"] {
            if let arr = obj[key] as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
        }
        return []
    }

    func str(_ obj: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = obj[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            if let n = obj[k] as? Int { return String(n) }
            if let n = obj[k] as? Double { return String(Int(n)) }
        }
        return nil
    }
    private func boolVal(_ obj: [String: Any], key: String) -> Bool {
        guard let s = str(obj, keys: [key]) else { return false }
        return s == "1" || s.lowercased() == "true" || s.lowercased() == "yes"
    }
    private func intVal(_ obj: [String: Any], key: String) -> Int? {
        str(obj, keys: [key]).flatMap(Int.init)
    }
    func instant(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let n = Int64(raw) {
            let ms: Int64 = n < 10_000_000_000 ? n * 1000 : n
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        if let d = ISO8601DateFormatter().date(from: raw) { return d }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: raw)
    }
}

private extension Array where Element == IptvChannel {
    func uniquified() -> [IptvChannel] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
