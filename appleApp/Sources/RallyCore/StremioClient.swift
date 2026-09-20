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
/// Default addon: https://sports.highfly.to/manifest.json
public final class StremioClient: Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder
    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    public func fetchManifest(from manifestUrl: String) async throws -> StremioManifest {
        guard let url = URL(string: manifestUrl) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        return try decoder.decode(StremioManifest.self, from: data)
    }

    public func fetchCatalog(_ addonBase: String, catalog: StremioCatalogDesc) async throws -> [StremioMetaItem] {
        let base = addonBase.hasSuffix("/manifest.json")
            ? String(addonBase.dropLast("/manifest.json".count)) : addonBase
        guard let type = catalog.type, let id = catalog.id else { return [] }
        guard let url = URL(string: "\(base)/catalog/\(type)/\(id).json") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return (try? decoder.decode(StremioCatalogResponse.self, from: data).metas) ?? []
    }

    public func fetchStreams(addonBase: String, type: String, metaId: String, addonName: String? = nil) async throws -> [StremioStreamOption] {
        let base = addonBase.hasSuffix("/manifest.json")
            ? String(addonBase.dropLast("/manifest.json".count)) : addonBase
        guard let url = URL(string: "\(base)/stream/\(type)/\(metaId).json") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        let streams = (try? decoder.decode(StremioStreamResponse.self, from: data).streams) ?? []
        return streams.compactMap { toOption(stream: $0, addonName: addonName) }
    }

    /// Event discovery: manifest → catalogs → metas matching the event →
    /// streams. Mirrors `StremioRepositoryImpl.getStreamsForEvent` (4-way cap).
    public func findStreams(for event: SportEvent, addonBase: String) async -> [StremioStreamOption] {
        guard let manifest = try? await fetchManifest(from: addonBase.hasSuffix(".json") ? addonBase : addonBase + "/manifest.json"),
              let catalogs = manifest.catalogs, !catalogs.isEmpty else { return [] }
        let addonName = manifest.name
        let metas = await withTaskGroup(of: [StremioMetaItem].self) { group in
            for catalog in catalogs.prefix(6) {
                group.addTask { (try? await self.fetchCatalog(addonBase, catalog: catalog)) ?? [] }
            }
            var out: [StremioMetaItem] = []
            for await items in group { out.append(contentsOf: items) }
            return out
        }
        let matches = metas.filter {
            guard let name = $0.name, !name.isEmpty else { return false }
            let probe = SportEvent(id: $0.id, name: name, homeTeam: event.homeTeam, awayTeam: event.awayTeam,
                startTime: event.startTime, status: event.status, sport: event.sport, league: event.league)
            return StreamSelector.textMatchesEvent(name, event: probe)
        }
        if matches.isEmpty { return [] }
        return await withTaskGroup(of: [StremioStreamOption].self) { group in
            for meta in matches.prefix(6) {
                group.addTask {
                    (try? await self.fetchStreams(addonBase: addonBase, type: meta.type ?? "sport",
                        metaId: meta.id, addonName: addonName)) ?? []
                }
            }
            var out: [StremioStreamOption] = []
            for await opts in group { out.append(contentsOf: opts) }
            return out
        }
    }

    private func toOption(stream: StremioStream, addonName: String?) -> StremioStreamOption? {
        guard let url = stream.url, !url.isEmpty else { return nil }
        let lower = url.lowercased()
        let isHtml = lower.contains("youtube.com/watch") || lower.hasSuffix(".html") || lower.contains("external/")
        let title = [stream.name, stream.title].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return StremioStreamOption(
            title: title.isEmpty ? (addonName ?? "Stream") : title,
            description: stream.description,
            streamUrl: url,
            quality: stream.name,
            addonName: addonName,
            headers: allowlistedHeaders(stream.behaviorHints?.proxyHeaders?.request),
            isDirectPlayable: !isHtml && stream.ytId == nil
        )
    }

    /// Only headers safe to forward to a player. Mirrors Android sanitization.
    private func allowlistedHeaders(_ input: [String: String]?) -> [String: String]? {
        guard let input, !input.isEmpty else { return nil }
        let allowed: Set<String> = ["user-agent", "referer", "origin", "cookie"]
        var out: [String: String] = [:]
        for (k, v) in input where allowed.contains(k.lowercased()) { out[k] = v }
        return out.isEmpty ? nil : out
    }
}
