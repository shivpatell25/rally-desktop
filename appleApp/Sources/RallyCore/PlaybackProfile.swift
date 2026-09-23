import Foundation

/// Device playback profile. Mirrors `PlaybackCapabilities.resolvePlaybackProfile`
/// in spirit: constrained hardware gets smaller buffers, fewer tiles, and no
/// speculative prefetch. macOS has no per-model table, so the tier follows
/// installed memory (the same signal Android's low-RAM path uses).
public struct PlaybackProfile: Sendable, Equatable {
    public enum Tier: String, Sendable { case standard, constrained }
    public var tier: Tier
    /// libVLC network-caching in ms (Android low-latency 2500/10000 vs 6000/20000).
    public var networkCachingMs: Int
    public var maxTiles: Int
    public var name: String

    public static func resolve(memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
                               lowLatency: Bool = false) -> PlaybackProfile {
        let constrained = memoryBytes < 8 * 1024 * 1024 * 1024
        if constrained {
            return PlaybackProfile(tier: .constrained,
                                   networkCachingMs: lowLatency ? 1000 : 2500,
                                   maxTiles: 2, name: "Constrained")
        }
        return PlaybackProfile(tier: .standard,
                               networkCachingMs: lowLatency ? 1500 : 4000,
                               maxTiles: 4, name: "Standard")
    }
}

/// Media options derived from the playback toggles. Unknown options are
/// ignored by libVLC, so enabling these can never break a working stream.
public struct PlaybackTuning: Sendable, Equatable {
    public var lowLatency: Bool
    public var audioNormalization: Bool
    public var networkCachingMs: Int

    public init(lowLatency: Bool = false, audioNormalization: Bool = false, networkCachingMs: Int = 4000) {
        self.lowLatency = lowLatency
        self.audioNormalization = audioNormalization
        self.networkCachingMs = networkCachingMs
    }

    /// libVLC media options. network-caching bounds live latency; the
    /// compressor filter levels ad breaks and hot IPTV feeds (DynamicsProcessing
    /// equivalent — conservative broadcast preset).
    public var mediaOptions: [String: String] {
        var out = ["network-caching": String(networkCachingMs)]
        if audioNormalization {
            out["audio-filter"] = "compressor"
            out["compressor-rms-peak"] = "0.0"
            out["compressor-attack"] = "50.0"
            out["compressor-release"] = "200.0"
            out["compressor-threshold"] = "-20.0"
            out["compressor-ratio"] = "4.0"
            out["compressor-knee"] = "6.0"
            out["compressor-makeup-gain"] = "6.0"
        }
        return out
    }
}

/// Adaptive fallback policy: after repeated stalls, step down to the next
/// ranked candidate once and say why (Android adaptive tier loop + reason).
public enum AdaptivePolicy {
    public static let stallThreshold = 3

    public static func fallback(afterStalls stalls: Int, candidates: [PlayCandidate],
                                currentId: String, failedIds: Set<String>) -> (candidate: PlayCandidate, reason: String)? {
        guard stalls >= stallThreshold, candidates.count > 1 else { return nil }
        let ordered = StreamResolver.sort(candidates)
        guard let currentIdx = ordered.firstIndex(where: { $0.id == currentId }),
              currentIdx + 1 < ordered.count else { return nil }
        for next in ordered[(currentIdx + 1)...] {
            if !failedIds.contains(next.id) {
                return (next, "\(stalls) stalls — stepped down to \(next.title)")
            }
        }
        return nil
    }
}
