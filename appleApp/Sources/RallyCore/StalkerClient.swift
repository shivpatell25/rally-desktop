import Foundation

/// Stalker/Ministra middleware client. 1:1 port of `StalkerApi` +
/// `StalkerIptvRepositoryImpl` + `AuthInterceptor` protocol behavior:
/// MAG250 headers, handshake→profile auth, portal path auto-discovery,
/// get_all_channels with get_ordered_list fallback, create_link resolution,
/// short EPG now/next. 15-min channel TTL, 2-min guide TTL.
public final class StalkerClient: @unchecked Sendable {
    private struct CachedChannels: Sendable { var channels: [IptvChannel]; var at: Date }
    private struct CachedGuide: Sendable { var guide: ChannelGuide; var at: Date }

    private let session: URLSession
    private let settings: SettingsStore
    private let lock = NSLock()
    private var channels: CachedChannels?
    private var guides: [String: CachedGuide] = [:]
    private let authLock = NSLock()

    private static let channelTTL: TimeInterval = 15 * 60
    private static let guideTTL: TimeInterval = 2 * 60

    public init(session: URLSession = .shared, settings: SettingsStore) {
        self.session = session
        self.settings = settings
    }

    // MARK: - Auth

    @discardableResult
    public func authenticate(force: Bool = false) async -> Bool {
        if !force, !(await token().isEmpty) { return true }
        guard !(await portal().isEmpty) else { return false }
        await setToken("")
        if await tryAuth() { return true }
        // Portal path auto-discovery (mirrors Android candidate list).
        let current = await portal()
        let base = current
            .replacingOccurrences(of: "/c$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "/stalker_portal$", with: "", options: .regularExpression)
        for candidate in [current, base + "/c", base + "/stalker_portal", base + "/stalker_portal/c"].uniquified() {
            await setPortal(candidate)
            if await tryAuth() { return true }
        }
        await setPortal(current)
        return false
    }

    private func tryAuth() async -> Bool {
        guard let hs = try? await get(type: "stb", action: "handshake",
                                      extra: ["token": "", "prehash": "0"]) else { return false }
        guard let raw = str(hs, keys: ["token", "random"]), !raw.isEmpty else { return false }
        let bearer = raw.lowercased().hasPrefix("bearer ") ? raw : "Bearer \(raw)"
        await setToken(bearer)
        // get_profile verifies session activation; status 1/2/error/failed = reject.
        guard let profile = try? await get(type: "stb", action: "get_profile", extra: [
            "hd": "1",
            "ver": "ImageDescription: 0.2.18-r23-250; ImageDate: Wed Sep 18 12:40:14 EEST 2013; PORTAL version: 5.6.0; API Version: JS API version: 343; STB API version: 146; Player Engine version: 0x58c",
            "num_banks": "2", "stb_type": "MAG250", "client_type": "STB", "image_version": "218",
            "video_out": "hdmi", "auth_second_step": "1", "hw_version": "1.7-BD-00", "not_valid_token": "0",
        ]) else { await setToken(""); return false }
        if let rejected = statusOf(profile), rejected {
            await setToken("")
            return false
        }
        return true
    }

    private func statusOf(_ js: Any) -> Bool? {
        guard let obj = js as? [String: Any], let raw = obj["status"] else { return nil }
        if let n = raw as? Int { return (n == 1 || n == 2) }
        if let n = raw as? Double { return (n == 1 || n == 2) }
        if let s = raw as? String {
            if let n = Int(s) { return (n == 1 || n == 2) }
            let l = s.lowercased()
            return (l == "error" || l == "failed")
        }
        return nil
    }

    // MARK: - Channels

    public func getChannels() async -> [IptvChannel] {
        await ensureOwner()
        if let c = lock.withLock({ channels }), Date().timeIntervalSince(c.at) < Self.channelTTL, !c.channels.isEmpty {
            return c.channels
        }
        if await token().isEmpty, !(await authenticate()) { return lock.withLock { channels?.channels ?? [] } }
        var fresh = await fetchChannels()
        if fresh.isEmpty {
            _ = await authenticate(force: true)
            fresh = await fetchChannels()
        }
        if !fresh.isEmpty { lock.withLock { channels = CachedChannels(channels: fresh, at: Date()) } }
        return fresh.isEmpty ? lock.withLock({ channels?.channels ?? [] }) : fresh
    }

    public func refreshChannels() async -> [IptvChannel] {
        lock.withLock { channels = nil }
        return await getChannels()
    }

    private func fetchChannels() async -> [IptvChannel] {
        var all: [[String: Any]] = []
        if let js = try? await get(type: "itv", action: "get_all_channels") {
            all = channelObjects(js)
        }
        if all.isEmpty {
            // Paged fallback; total_items drives pagination.
            var page = 1
            while page <= 50 {
                guard let js = try? await get(type: "itv", action: "get_ordered_list",
                                              extra: ["p": String(page), "fav": "0", "sortby": "number"]) else { break }
                let (objs, total) = channelObjectsWithTotal(js)
                all.append(contentsOf: objs)
                if let total, all.count >= total { break }
                if objs.isEmpty { break }
                page += 1
            }
        }
        let genres = (try? await get(type: "itv", action: "get_genres")).map(genreMap) ?? [:]
        return all.compactMap { mapChannel($0, genres: genres) }
    }

    func mapChannel(_ obj: [String: Any], genres: [String: String]) -> IptvChannel? {
        guard let id = str(obj, keys: ["id", "ch_id"]) else { return nil }
        let name = str(obj, keys: ["name"]) ?? "Channel \(id)"
        let number = str(obj, keys: ["number", "num"]) ?? id
        let genreId = str(obj, keys: ["tv_genre_id"]) ?? ""
        return IptvChannel(
            id: id, number: number, name: name,
            category: genres[genreId] ?? "Live TV",
            logoUrl: str(obj, keys: ["logo"]),
            streamUrl: str(obj, keys: ["cmd"]),
            supportsCatchUp: truthy(obj, keys: ["tv_archive", "allow_timeshift", "archive"]),
            archiveDurationHours: intVal(obj, keys: ["tv_archive_duration", "archive_hours"])
                ?? intVal(obj, keys: ["archive_days"]).map { $0 * 24 }
        )
    }

    // MARK: - Stream URL

    /// create_link resolution with prefix cleanup (`ffmpeg `, `ffrt `, `auto `).
    public func resolveStreamUrl(channelId: String) async -> String {
        if (channelId.hasPrefix("http://") || channelId.hasPrefix("https://")) && !channelId.contains("localhost") {
            return cleanStreamUrl(channelId)
        }
        var cmd = channelId
        if !cmd.contains("localhost") && !cmd.hasPrefix("ffmpeg") && !cmd.hasPrefix("ffrt") && !cmd.hasPrefix("auto") {
            if let cached = lock.withLock({ channels?.channels.first(where: { $0.id == channelId })?.streamUrl }),
               !cached.isEmpty { cmd = cached }
        }
        if await token().isEmpty { _ = await authenticate() }
        var js: Any? = try? await get(type: "itv", action: "create_link", extra: ["cmd": cmd])
        if js == nil {
            _ = await authenticate(force: true)
            js = try? await get(type: "itv", action: "create_link", extra: ["cmd": cmd])
        }
        if let obj = js as? [String: Any], let c = obj["cmd"] as? String { return cleanStreamUrl(c) }
        if let s = js as? String { return cleanStreamUrl(s) }
        return cleanStreamUrl(cmd)
    }

    public func cleanStreamUrl(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ffmpeg ", "ffrt ", "auto "] where url.lowercased().hasPrefix(prefix) {
            url = String(url.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return url
    }

    // MARK: - EPG

    public func getGuide(channelId: String) async -> ChannelGuide? {
        if let g = lock.withLock({ guides[channelId] }), Date().timeIntervalSince(g.at) < Self.guideTTL { return g.guide }
        guard !(await portal().isEmpty) else { return nil }
        if await token().isEmpty, !(await authenticate()) { return nil }
        guard let js = try? await get(type: "itv", action: "get_short_epg",
                                      extra: ["ch_id": channelId, "size": "4"]),
              let guide = parseGuide(js) else { return nil }
        lock.withLock { guides[channelId] = CachedGuide(guide: guide, at: Date()) }
        return guide
    }

    func parseGuide(_ js: Any) -> ChannelGuide? {
        var entries: [[String: Any]] = []
        func collect(_ el: Any?) {
            guard let el else { return }
            if let arr = el as? [Any] { arr.forEach(collect); return }
            guard let obj = el as? [String: Any] else { return }
            for key in ["data", "epg", "programs", "items"] {
                if let nested = obj[key] { collect(nested); return }
            }
            entries.append(obj)
        }
        collect(js)
        let programs = entries.compactMap { obj -> EpgProgram? in
            guard let title = str(obj, keys: ["name", "title", "program", "programme"]) else { return nil }
            return EpgProgram(title: title,
                description: str(obj, keys: ["descr", "description", "desc"]),
                startTime: instant(str(obj, keys: ["start_timestamp", "start", "begin", "time"])),
                endTime: instant(str(obj, keys: ["stop_timestamp", "end_timestamp", "end", "stop"])))
        }.sorted { ($0.startTime ?? .distantFuture) < ($1.startTime ?? .distantFuture) }
        guard !programs.isEmpty else { return nil }
        let now = Date()
        let idx = programs.firstIndex {
            guard let s = $0.startTime, let e = $0.endTime else { return false }
            return s <= now && now < e
        } ?? 0
        return ChannelGuide(now: programs[idx], next: programs.indices.contains(idx + 1) ? programs[idx + 1] : nil)
    }

    // MARK: - Transport

    /// GET portal/server/load.php with MAG250 headers. Returns the `js` payload.
    func get(type: String, action: String, extra: [String: String] = [:]) async throws -> Any {
        let portal = await portal()
        guard var comps = URLComponents(string: portal + "/server/load.php") else { throw URLError(.badURL) }
        var items = [URLQueryItem(name: "JsHttpRequest", value: "1-xml"),
                     URLQueryItem(name: "type", value: type),
                     URLQueryItem(name: "action", value: action)]
        if action == "handshake" { items += [URLQueryItem(name: "token", value: ""), URLQueryItem(name: "prehash", value: "0")] }
        if action == "get_ordered_list" {
            if extra["fav"] == nil { items.append(URLQueryItem(name: "fav", value: "0")) }
            if extra["sortby"] == nil { items.append(URLQueryItem(name: "sortby", value: "number")) }
        }
        for (k, v) in extra {
            if action == "get_ordered_list" && (k == "fav" || k == "sortby") { continue }
            items.append(URLQueryItem(name: k, value: v))
        }
        comps.queryItems = items
        let sn = await serial(), devId = await device()
        if !sn.isEmpty { comps.queryItems?.append(URLQueryItem(name: "sn", value: sn)) }
        if !devId.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "device_id", value: devId))
            comps.queryItems?.append(URLQueryItem(name: "device_id2", value: devId))
        }
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 12)
        let mac = await mac()
        var xua = "Model: MAG250; Link: Ethernet"
        if !sn.isEmpty { xua += "; SerialNumber: \(sn)" }
        if !devId.isEmpty { xua += "; DeviceId: \(devId); DeviceId2: \(devId)" }
        if !mac.isEmpty { xua += "; Mac: \(mac)" }
        req.setValue(xua, forHTTPHeaderField: "X-User-Agent")
        req.setValue("Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(referer(for: portal), forHTTPHeaderField: "Referer")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if !mac.isEmpty { req.setValue("mac=\(mac); stb_lang=en; timezone=GMT", forHTTPHeaderField: "Cookie") }
        let tok = await token()
        if !tok.isEmpty && action != "handshake" { req.setValue(tok, forHTTPHeaderField: "Authorization") }
        let (data, _) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data)
        if let obj = json as? [String: Any], let js = obj["js"] { return js }
        return json
    }

    private func referer(for portal: String) -> String {
        guard let comps = URLComponents(string: portal), let host = comps.host else { return portal + "/" }
        var ref = "\(comps.scheme ?? "http")://\(host)"
        let defaultPort = comps.scheme == "https" ? 443 : 80
        if let port = comps.port, port != defaultPort { ref += ":\(port)" }
        let path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty { ref += "/\(path)" }
        if !ref.hasSuffix("/c") { ref += "/c" }
        return ref + "/"
    }

    // MARK: - JSON helpers

    func str(_ obj: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = obj[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            if let n = obj[k] as? Int { return String(n) }
            if let n = obj[k] as? Double { return String(Int(n)) }
        }
        return nil
    }
    private func str(_ js: Any, keys: [String]) -> String? {
        guard let obj = js as? [String: Any] else { return nil }
        return str(obj, keys: keys)
    }
    private func truthy(_ obj: [String: Any], keys: [String]) -> Bool {
        for k in keys {
            let raw: String?
            if let s = obj[k] as? String { raw = s } else if let n = obj[k] as? Int { raw = String(n) } else { continue }
            let l = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if l == "1" || l == "true" || l == "yes" { return true }
            if let n = Int(l), n > 0 { return true }
        }
        return false
    }
    private func intVal(_ obj: [String: Any], keys: [String]) -> Int? {
        for k in keys {
            if let s = obj[k] as? String, let n = Int(s) { return n }
            if let n = obj[k] as? Int { return n }
        }
        return nil
    }
    func instant(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let n = Int64(raw) {
            let ms: Int64 = n < 10_000_000_000 ? n * 1000 : n
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func channelObjects(_ js: Any) -> [[String: Any]] { channelObjectsWithTotal(js).0 }
    func channelObjectsWithTotal(_ js: Any) -> ([[String: Any]], Int?) {
        if let arr = js as? [Any] { return (arr.compactMap { $0 as? [String: Any] }, nil) }
        guard let obj = js as? [String: Any] else { return ([], nil) }
        var total: Int?
        if let t = obj["total_items"] as? String { total = Int(t) }
        else if let t = obj["total_items"] as? Int { total = t }
        if let data = obj["data"] {
            if let arr = data as? [Any] { return (arr.compactMap { $0 as? [String: Any] }, total) }
            if let map = data as? [String: Any] { return (map.values.compactMap { $0 as? [String: Any] }, total) }
        }
        let skip = ["total_items", "max_page_items", "selected_item", "cur_page"]
        return (obj.filter { !skip.contains($0.key) }.values.compactMap { $0 as? [String: Any] }, total)
    }
    private func genreMap(_ js: Any) -> [String: String] {
        let objs: [[String: Any]]
        if let arr = js as? [Any] { objs = arr.compactMap { $0 as? [String: Any] } }
        else if let obj = js as? [String: Any] { objs = obj.values.compactMap { $0 as? [String: Any] } }
        else { return [:] }
        var out: [String: String] = [:]
        for o in objs {
            if let id = str(o, keys: ["id", "tv_genre_id"]), let title = str(o, keys: ["title", "name"]) { out[id] = title }
        }
        return out
    }

    private func ensureOwner() async {
        let identity = "\(await portal().lowercased())|\(await mac().uppercased())"
        let current: String = await MainActor.run { settings.channelCacheIdentity }
        if current != identity {
            lock.withLock { channels = nil; guides.removeAll() }
            await MainActor.run { settings.channelCacheIdentity = identity }
            await setToken("")
        }
    }

    // MARK: - Settings access (main-actor isolated store)
    private func portal() async -> String { await MainActor.run { settings.portalUrl } }
    private func setPortal(_ v: String) async { await MainActor.run { settings.portalUrl = v } }
    private func mac() async -> String { await MainActor.run { settings.macAddress } }
    private func serial() async -> String { await MainActor.run { settings.serialNumber } }
    private func device() async -> String { await MainActor.run { settings.deviceId } }
    private func token() async -> String { await MainActor.run { settings.authToken } }
    private func setToken(_ v: String) async { await MainActor.run { settings.authToken = v } }
}

private extension Array where Element == String {
    func uniquified() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
