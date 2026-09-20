import Foundation

/// v1 candidate ranking. Mirrors `SelectBestStreamUseCase` ordering spirit —
/// exact-game matches first, then evidence-based quality rank — without the
/// preflight probe and fallback chain (next slice).
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
    public init(id: String = UUID().uuidString, title: String, url: String, headers: [String: String]? = nil,
                kind: Kind, exactMatch: Bool, rank: Int, channel: IptvChannel? = nil, addonName: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.headers = headers; self.kind = kind
        self.exactMatch = exactMatch; self.rank = rank; self.channel = channel; self.addonName = addonName
    }
}

public enum StreamResolver {
    public static func candidates(event: SportEvent, channels: [IptvChannel], stremioOptions: [StremioStreamOption]) -> [PlayCandidate] {
        var out: [PlayCandidate] = []
        for opt in stremioOptions where opt.isDirectPlayable {
            let text = [opt.title, opt.description ?? ""].joined(separator: " ")
            let quality = parseQualityFromChannelName(opt.quality ?? opt.title)
            out.append(PlayCandidate(title: opt.title, url: opt.streamUrl, headers: opt.headers, kind: .stremio,
                exactMatch: StreamSelector.textMatchesEvent(text, event: event),
                rank: StreamSelector.qualityRank(quality), addonName: opt.addonName))
        }
        for ch in channels {
            let guideText = [ch.guide?.now?.title, ch.guide?.next?.title].compactMap { $0 }.joined(separator: " ")
            let exact = StreamSelector.textMatchesEvent(ch.name, event: event)
                || (!guideText.isEmpty && StreamSelector.textMatchesEvent(guideText, event: event))
            guard exact || ch.name.range(of: event.league, options: .caseInsensitive) != nil else { continue }
            let quality = parseQualityFromChannelName(ch.name)
            out.append(PlayCandidate(title: ch.name, url: ch.streamUrl ?? ch.id, headers: nil, kind: .iptv,
                exactMatch: exact, rank: StreamSelector.qualityRank(quality), channel: ch))
        }
        return out.sorted {
            if $0.exactMatch != $1.exactMatch { return $0.exactMatch }
            return $0.rank > $1.rank
        }
    }

    public static func channelCandidates(_ channels: [IptvChannel]) -> [PlayCandidate] {
        channels.map { ch in
            PlayCandidate(title: ch.name, url: ch.streamUrl ?? ch.id, kind: .iptv,
                exactMatch: true, rank: StreamSelector.qualityRank(parseQualityFromChannelName(ch.name)), channel: ch)
        }
    }
}
