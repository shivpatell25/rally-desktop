import Foundation

/// Stremio addon protocol types. Mirrors `data/remote/stremio/StremioApi.kt`.
public struct StremioManifest: Codable, Sendable {
    public var id: String?
    public var name: String?
    public var description: String?
    public var version: String?
    public var types: [String]?
    public var catalogs: [StremioCatalogDesc]?
}

public struct StremioCatalogDesc: Codable, Sendable {
    public var type: String?
    public var id: String?
    public var name: String?
}

public struct StremioCatalogResponse: Codable, Sendable {
    public var metas: [StremioMetaItem]?
}

public struct StremioMetaItem: Codable, Sendable {
    public var id: String
    public var type: String?
    public var name: String?
    public var poster: String?
    public var banner: String?
    public var description: String?
    public var genres: [String]?
}

public struct StremioStreamResponse: Codable, Sendable {
    public var streams: [StremioStream]?
}

public struct StremioStream: Codable, Sendable {
    public var name: String?
    public var title: String?
    public var description: String?
    public var url: String?
    public var externalUrl: String?
    public var ytId: String?
    public var behaviorHints: StremioBehaviorHints?
}

public struct StremioBehaviorHints: Codable, Sendable {
    public var proxyHeaders: StremioProxyHeaders?
    public var notWebReady: Bool?
}

public struct StremioProxyHeaders: Codable, Sendable {
    public var request: [String: String]?
}

public struct StremioStreamOption: Sendable, Equatable {
    public var title: String
    public var description: String?
    public var streamUrl: String
    public var quality: String?
    public var addonName: String?
    /// Allowlisted request headers only — mirrors Android header sanitization.
    public var headers: [String: String]?
    /// False when the addon supplied an HTML watch page rather than playable media.
    public var isDirectPlayable: Bool
    public init(title: String, description: String? = nil, streamUrl: String, quality: String? = nil,
                addonName: String? = nil, headers: [String: String]? = nil, isDirectPlayable: Bool = true) {
        self.title = title; self.description = description; self.streamUrl = streamUrl
        self.quality = quality; self.addonName = addonName; self.headers = headers
        self.isDirectPlayable = isDirectPlayable
    }
}

/// URLSession client for a single Stremio addon manifest.
/// Addons are explicitly configured by the user, matching Android defaults.
public actor StremioClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private var manifests: [String: (Date, StremioManifest)] = [:]
    private var eventStreams: [String: (Date, [StremioStreamOption])] = [:]
    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    public func fetchManifest(from manifestUrl: String) async throws -> StremioManifest {
        if let cached = manifests[manifestUrl], Date().timeIntervalSince(cached.0) < 1800 { return cached.1 }
        guard let url = URL(string: manifestUrl) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let manifest = try decoder.decode(StremioManifest.self, from: data)
        manifests[manifestUrl] = (Date(), manifest)
        return manifest
    }

    public func fetchCatalog(_ addonBase: String, catalog: StremioCatalogDesc) async throws -> [StremioMetaItem] {
        let base = addonBase.hasSuffix("/manifest.json")
            ? String(addonBase.dropLast("/manifest.json".count)) : addonBase
        guard let type = catalog.type, let id = catalog.id else { return [] }
        guard let url = URL(string: "\(base)/catalog/\(type)/\(id).json") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try decoder.decode(StremioCatalogResponse.self, from: data).metas ?? []
    }

    public func fetchStreams(addonBase: String, type: String, metaId: String, addonName: String? = nil) async throws -> [StremioStreamOption] {
        let base = addonBase.hasSuffix("/manifest.json")
            ? String(addonBase.dropLast("/manifest.json".count)) : addonBase
        guard let encoded = metaId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~:"))), let url = URL(string: "\(base)/stream/\(type)/\(encoded).json") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let streams = try decoder.decode(StremioStreamResponse.self, from: data).streams ?? []
        return streams.compactMap { toOption(stream: $0, addonName: addonName) }
    }

    /// Event discovery: manifest → catalogs → metas matching the event →
    /// streams. Mirrors `StremioRepositoryImpl.getStreamsForEvent` (4-way cap).
    public func findStreams(for event: SportEvent, addonBase: String) async -> [StremioStreamOption] {
        let key = event.id + "|" + addonBase
        if let cached = eventStreams[key], !cached.1.isEmpty, Date().timeIntervalSince(cached.0) < 90 { return cached.1 }
        let results = await withTaskGroup(of: [StremioStreamOption].self) { group in
            group.addTask { await self.resolve(event: event, addon: addonBase) }
            group.addTask { try? await Task.sleep(nanoseconds: 20_000_000_000); return [] }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
        if !results.isEmpty { eventStreams[key] = (Date(), results) }
        return results
    }

    private func resolve(event: SportEvent, addon: String) async -> [StremioStreamOption] {
        guard let manifest = try? await fetchManifest(from: Self.manifestURL(addon)), !Task.isCancelled else { return [] }
        let catalogs = Self.targetCatalogs(manifest.catalogs ?? [], event: event)
        var metas: [StremioMetaItem] = []
        for offset in stride(from: 0, to: catalogs.count, by: 4) {
            guard !Task.isCancelled else { return [] }
            let batch = catalogs[offset..<min(catalogs.count, offset + 4)]
            metas += await withTaskGroup(of: [StremioMetaItem].self) { group in
                for catalog in batch {
                    group.addTask {
                        var matching = ((try? await self.fetchCatalog(addon, catalog: catalog)) ?? []).filter { Self.matches($0, event: event) }
                        if matching.isEmpty {
                            let queries = [event.homeTeam?.name, event.awayTeam?.name].compactMap { $0 }.compactMap { Self.keywords($0).first }
                            for query in queries {
                                guard !Task.isCancelled else { return [] }
                                matching += ((try? await self.searchCatalog(addon, catalog: catalog, query: query)) ?? []).filter { Self.matches($0, event: event) }
                                if !matching.isEmpty { break }
                            }
                        }
                        return matching
                    }
                }
                var result: [StremioMetaItem] = []
                for await values in group { result += values }
                return result
            }
        }
        var seen = Set<String>()
        return await options(metas.filter { seen.insert($0.id).inserted }, addon: addon, name: manifest.name)
    }

    public nonisolated static func targetCatalogs(_ catalogs: [StremioCatalogDesc], event: SportEvent) -> [StremioCatalogDesc] {
        let league = event.league.lowercased(), sport = event.sport.lowercased()
        let live = catalogs.filter { catalog in
            let text = "\(catalog.id ?? "") \(catalog.name ?? "")".lowercased()
            return ["live", "today", "schedule"].contains { text.contains($0) }
        }
        let sports = catalogs.filter { catalog in
            let text = "\(catalog.id ?? "") \(catalog.name ?? "")".lowercased()
            if ["epl", "la liga", "champions league", "serie a", "mls"].contains(league) || sport.contains("soccer") {
                return (text.contains("football") && !text.contains("american")) || ["soccer", "epl", "mls"].contains { text.contains($0) }
            }
            let tokens: [String]
            if league == "nfl" { tokens = ["american_football", "nfl"] }
            else if league.contains("ncaa") && sport.contains("football") { tokens = ["american_football", "college", "ncaa"] }
            else if sport.contains("football") { tokens = ["american_football", "nfl", "college"] }
            else if sport.contains("basket") { tokens = ["basket", "nba", "ncaab"] }
            else if sport.contains("base") { tokens = ["base", "mlb"] }
            else if sport.contains("hock") { tokens = ["hock", "nhl"] }
            else if sport.contains("fight") { tokens = ["fight", "ufc", "box", "mma"] }
            else if sport.contains("motor") { tokens = ["motor", "f1", "nascar", "racing"] }
            else { tokens = [league] }
            return tokens.contains { text.contains($0) }
        }
        var targets = live + sports
        if targets.isEmpty || catalogs.count <= 3 { targets += catalogs.filter { ["sport", "tv", "events"].contains($0.type ?? "") } }
        var seen = Set<String>()
        return targets.filter { seen.insert($0.id ?? "").inserted }
    }
    private nonisolated static func keywords(_ text: String) -> [String] {
        let stop: Set<String> = ["at", "vs", "versus", "the", "and", "state", "university", "college", "club", "fc", "sc", "united", "city", "real", "athletic", "st", "men", "women"]
        return StreamSelector.normalizeMatchText(text).split(separator: " ").map(String.init).filter { $0.count >= 3 && !stop.contains($0) }
    }
    private nonisolated static func matches(_ meta: StremioMetaItem, event: SportEvent) -> Bool {
        let text = "\(meta.name ?? "") \(meta.description ?? "")".lowercased()
        let home = keywords(event.homeTeam?.name ?? ""), away = keywords(event.awayTeam?.name ?? "")
        if home.contains(where: { text.contains($0) }) && away.contains(where: { text.contains($0) }) { return true }
        if let h = event.homeTeam?.abbreviation.lowercased(), let a = event.awayTeam?.abbreviation.lowercased(), h.count >= 3, a.count >= 3, text.contains(h), text.contains(a) { return true }
        let title = StreamSelector.normalizeMatchText(meta.name ?? ""), name = StreamSelector.normalizeMatchText(event.name)
        return !title.isEmpty && !name.isEmpty && (title.contains(name) || name.contains(title))
    }
    private nonisolated static func manifestURL(_ addon: String) -> String {
        addon.hasSuffix("manifest.json") ? addon : addon.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/manifest.json"
    }
    private func options(_ metas: [StremioMetaItem], addon: String, name: String?) async -> [StremioStreamOption] {
        var result: [StremioStreamOption] = []
        for offset in stride(from: 0, to: metas.count, by: 4) {
            guard !Task.isCancelled else { break }
            result += await withTaskGroup(of: [StremioStreamOption].self) { group in
                for meta in metas[offset..<min(metas.count, offset + 4)] {
                    group.addTask { (try? await self.fetchStreams(addonBase: addon, type: meta.type ?? "sport", metaId: meta.id, addonName: name)) ?? [] }
                }
                var result: [StremioStreamOption] = []
                for await values in group { result += values }
                return result
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.streamUrl).inserted }
    }
    public func searchStreams(query: String, addons: [String]) async -> [StremioStreamOption] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return [] }
        return await withTaskGroup(of: [StremioStreamOption].self) { race in
            race.addTask {
                await withTaskGroup(of: [StremioStreamOption].self) { group in
                    for addon in addons {
                        group.addTask { await self.searchAddon(addon, query: query) }
                    }
                    var result: [StremioStreamOption] = [], seen = Set<String>()
                    for await options in group { result += options.filter { seen.insert($0.streamUrl).inserted } }
                    return Array(result.prefix(20))
                }
            }
            race.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return [] }
            let first = await race.next() ?? []
            race.cancelAll()
            return first
        }
    }
    private func searchAddon(_ addon: String, query: String) async -> [StremioStreamOption] {
        guard let manifest = try? await fetchManifest(from: Self.manifestURL(addon)), !Task.isCancelled else { return [] }
        return await withTaskGroup(of: [StremioStreamOption].self) { group in
            for catalog in (manifest.catalogs ?? []).prefix(4) {
                group.addTask {
                    let metas = (try? await self.searchCatalog(addon, catalog: catalog, query: query)) ?? []
                    return await self.options(Array(metas.prefix(8)), addon: addon, name: manifest.name)
                }
            }
            var result: [StremioStreamOption] = []
            for await values in group { result += values }
            return result
        }
    }
    private func searchCatalog(_ addon: String, catalog: StremioCatalogDesc, query: String) async throws -> [StremioMetaItem] {
        guard let type = catalog.type, let id = catalog.id else { return [] }
        let base = addon.hasSuffix("/manifest.json") ? String(addon.dropLast(14)) : addon.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard let url = URL(string: "\(base)/catalog/\(type)/\(id)/search=\(encoded).json") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await session.data(for: request),
           (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
           let result = try? decoder.decode(StremioCatalogResponse.self, from: data), let metas = result.metas, !metas.isEmpty { return metas }
        return try await fetchCatalog(addon, catalog: catalog).filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) || ($0.description ?? "").localizedCaseInsensitiveContains(query) }
    }

    private func toOption(stream: StremioStream, addonName: String?) -> StremioStreamOption? {
        guard let url = [stream.url, stream.externalUrl].compactMap({ $0 }).first(where: { !$0.isEmpty }), let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
        let lower = url.lowercased()
        let availability = [stream.title, stream.name, stream.description].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !lower.contains("youtube.com"), !availability.contains("🔒"), !availability.contains("upgrade to"), !availability.contains("premium required") else { return nil }
        let isHtml = stream.url == nil || lower.hasSuffix(".html") || lower.contains("external/")
        let title = [stream.title, stream.name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? ""
        let quality = parseQualityFromChannelName(availability)
        return StremioStreamOption(
            title: title.isEmpty ? (addonName ?? "Stream") : title,
            description: stream.description,
            streamUrl: url,
            quality: quality.resolution.map { $0 + (quality.isHdr ? " HDR" : "") },
            addonName: addonName,
            headers: allowlistedHeaders(stream.behaviorHints?.proxyHeaders?.request),
            isDirectPlayable: !isHtml && stream.ytId == nil
        )
    }

    /// Only headers safe to forward to a player. Mirrors Android sanitization.
    private func allowlistedHeaders(_ input: [String: String]?) -> [String: String]? {
        guard let input, !input.isEmpty else { return nil }
        let allowed: Set<String> = ["user-agent", "referer", "origin", "cookie", "authorization"]
        var out: [String: String] = [:]
        for (k, v) in input where allowed.contains(k.lowercased()) { out[k] = v }
        return out.isEmpty ? nil : out
    }
}
