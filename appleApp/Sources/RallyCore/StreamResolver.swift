import Foundation

/// Candidate ranking. Mirrors `SelectBestStreamUseCase` ordering:
/// exact-game first, then preflight-verified, then quality rank blended with
/// stream-health score, Stremio-first, confidence, title. Health is URL-keyed
/// (see `SettingsStore.streamHealth`); pass a lookup so sorting stays pure.
public struct PlayCandidate: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case stremio, iptv }
    public var id: String
    public var title: String
    public var url: String
    public var headers: [String: String]?
    public var kind: Kind
    public var exactMatch: Bool
    public var rank: Int
    public var channel: IptvChannel?
    public var addonName: String?
    public var preflightPassed: Bool?
    public var preflightLatencyMs: Int64?
    public var preflightContentType: String?
    public var matchConfidence: Float
    public var matchEvidence: String?
    public init(id: String = UUID().uuidString, title: String, url: String, headers: [String: String]? = nil,
                kind: Kind, exactMatch: Bool, rank: Int, channel: IptvChannel? = nil, addonName: String? = nil,
                preflightPassed: Bool? = nil, preflightLatencyMs: Int64? = nil, preflightContentType: String? = nil,
                matchConfidence: Float = 0, matchEvidence: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.headers = headers; self.kind = kind
        self.exactMatch = exactMatch; self.rank = rank; self.channel = channel; self.addonName = addonName
        self.preflightPassed = preflightPassed; self.preflightLatencyMs = preflightLatencyMs
        self.preflightContentType = preflightContentType
        self.matchConfidence = matchConfidence; self.matchEvidence = matchEvidence
    }
}

public enum StreamResolver {
    public static func candidates(event: SportEvent, channels: [IptvChannel], stremioOptions: [StremioStreamOption],
                                  health: (String) -> Int = { _ in 0 }) -> [PlayCandidate] {
        var out: [PlayCandidate] = []
        // Addon results are already scoped to the event by `findStreams(for:)`,
        // so every direct-playable option is an exact match (Android `toCandidate`).
        for opt in stremioOptions where opt.isDirectPlayable {
            let quality = parseQualityFromChannelName([opt.title, opt.description, opt.quality]
                .compactMap { $0 }.joined(separator: " "))
            out.append(PlayCandidate(title: opt.title, url: opt.streamUrl, headers: opt.headers, kind: .stremio,
                exactMatch: true, rank: StreamSelector.qualityRank(quality), addonName: opt.addonName,
                matchConfidence: 0.98, matchEvidence: "Exact event match"))
        }
        for ch in channels {
            let guideText = [ch.guide?.now?.title, ch.guide?.next?.title].compactMap { $0 }.joined(separator: " ")
            let guideTitle = ch.guide?.now?.title ?? ""
            let exactFromGuide = !guideTitle.isEmpty && StreamSelector.textMatchesEvent(guideTitle, event: event)
            let exactFromName = StreamSelector.textMatchesEvent(ch.name, event: event)
            let isRedZone = ch.name.range(of: "redzone", options: .caseInsensitive) != nil
                || ch.name.range(of: "red zone", options: .caseInsensitive) != nil
            let exact = !isRedZone && (exactFromGuide || exactFromName)
            guard exact || ch.name.range(of: event.league, options: .caseInsensitive) != nil else { continue }
            let quality = parseQualityFromChannelName([ch.name, guideTitle].joined(separator: " "))
            let evidence: String = exactFromGuide ? "Now playing: \(guideTitle)"
                : exactFromName ? "Dedicated matchup channel"
                : guideTitle.isEmpty ? "Unverified channel" : "Now playing: \(guideTitle)"
            out.append(PlayCandidate(title: ch.name, url: ch.streamUrl ?? ch.id, headers: nil, kind: .iptv,
                exactMatch: exact, rank: StreamSelector.qualityRank(quality), channel: ch,
                matchConfidence: exact ? 0.9 : 0.25, matchEvidence: evidence))
        }
        let ranked = sort(out, health: health)
        // Addons often return the same URL across matched metas — collapse
        // duplicates (keep best rank) and cap the picker list.
        var seen = Set<String>()
        return ranked.filter { seen.insert($0.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted }
            .prefix(40).map { $0 }
    }

    public static func sort(_ cands: [PlayCandidate], health: (String) -> Int = { _ in 0 }) -> [PlayCandidate] {
        cands.sorted {
            if $0.exactMatch != $1.exactMatch { return $0.exactMatch }
            if ($0.preflightPassed != false) != ($1.preflightPassed != false) { return $0.preflightPassed != false }
            let lhs = $0.rank + health($0.url), rhs = $1.rank + health($1.url)
            if lhs != rhs { return lhs > rhs }
            if ($0.kind == .stremio) != ($1.kind == .stremio) { return $0.kind == .stremio }
            if $0.matchConfidence != $1.matchConfidence { return $0.matchConfidence > $1.matchConfidence }
            return $0.title < $1.title
        }
    }

    /// Primary must be an exact match that hasn't failed verification —
    /// mirrors `candidates.firstOrNull { exact && preflight != false }`.
    public static func primary(from candidates: [PlayCandidate]) -> PlayCandidate? {
        candidates.first { $0.exactMatch && $0.preflightPassed != false }
    }

    public static func channelCandidates(_ channels: [IptvChannel]) -> [PlayCandidate] {
        channels.map { ch in
            PlayCandidate(title: ch.name, url: ch.streamUrl ?? ch.id, kind: .iptv,
                exactMatch: true, rank: StreamSelector.qualityRank(parseQualityFromChannelName(ch.name)), channel: ch)
        }
    }
}
