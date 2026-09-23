import AppKit
import Foundation
import VLCKit

/// libVLC playback engine. Takes over where AVPlayer stops: odd IPTV/Stremio
/// transports and codecs AVFoundation rejects. AVPlayer stays the fallback for
/// plain HLS (see `PlaybackController`).
///
/// Mirrors the Android Multi-View budget: at most 4 concurrent tiles.
public final class VlcEngine: @unchecked Sendable {
    public static let maxTiles = 4

    public enum Error: Swift.Error, Equatable {
        case tileCapReached
        case unreservedSlot
        case mediaInitFailed
    }

    private let lock = NSLock()
    private var reserved: Set<String> = []
    private var players: [String: VLCMediaPlayer] = [:]

    public init() {}

    /// Reserves a tile. Returns false when 4 tiles are already held.
    @discardableResult
    public func reserve(slotId: String) -> Bool {
        lock.withLock {
            if reserved.contains(slotId) { return true }
            guard reserved.count < Self.maxTiles else { return false }
            reserved.insert(slotId)
            return true
        }
    }

    public func release(slotId: String) {
        lock.withLock {
            reserved.remove(slotId)
            players.removeValue(forKey: slotId)?.stop()
        }
    }

    public func releaseAll() {
        lock.withLock {
            reserved.removeAll()
            players.values.forEach { $0.stop() }
            players.removeAll()
        }
    }

    public var tileCount: Int { lock.withLock { reserved.count } }

    /// Starts playback on a reserved tile. Throws `.tileCapReached` for a new
    /// slotId past the cap, `.unreservedSlot` when the slot was released.
    @MainActor
    public func play(slotId: String, title: String, url: URL, headers: [String: String]? = nil, drawable: NSView? = nil) throws {
        try play(slotId: slotId, title: title, url: url, headers: headers, tuning: nil, drawable: drawable)
    }

    @MainActor
    public func play(slotId: String, title: String, url: URL, headers: [String: String]? = nil,
                     tuning: PlaybackTuning? = nil, drawable: NSView? = nil) throws {
        let known: Bool = lock.withLock { reserved.contains(slotId) }
        guard known else { throw Error.unreservedSlot }
        if lock.withLock({ players[slotId] == nil }) && tileCount > Self.maxTiles {
            throw Error.tileCapReached
        }
        let player: VLCMediaPlayer = lock.withLock {
            if let existing = players[slotId] { return existing }
            let created = VLCMediaPlayer()
            players[slotId] = created
            return created
        }
        guard let media = VLCMedia(url: url) else { throw Error.mediaInitFailed }
        for (key, value) in vlcOptions(from: headers) { media.addOptions([key: value]) }
        if let tuning {
            for (key, value) in tuning.mediaOptions { media.addOptions([key: value]) }
        }
        player.media = media
        if let drawable { player.drawable = drawable }
        player.play()
    }

    @MainActor
    public func stop(slotId: String) {
        lock.withLock { players[slotId] }?.stop()
    }

    @MainActor
    public func pause(slotId: String) {
        lock.withLock { players[slotId] }?.pause()
    }

    @MainActor
    public func resume(slotId: String) {
        lock.withLock { players[slotId] }?.play()
    }

    @MainActor
    public func setMuted(slotId: String, muted: Bool) {
        guard let player = lock.withLock({ players[slotId] }) else { return }
        player.audio?.volume = muted ? 0 : 100
    }

    @MainActor
    public func isMuted(slotId: String) -> Bool {
        (lock.withLock({ players[slotId] })?.audio?.volume ?? 100) == 0
    }

    @MainActor
    public func isPlaying(slotId: String) -> Bool {
        lock.withLock { players[slotId] }?.isPlaying ?? false
    }
    /// Fraction 0-1 plus clock string for transport display.
    @MainActor
    public func position(slotId: String) -> (fraction: Double, clock: String)? {
        guard let player = lock.withLock({ players[slotId] }) else { return nil }
        let fraction = player.position
        let ms = player.time.intValue
        let s = max(0, ms / 1000)
        return (fraction, String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60))
    }

    /// Forwards what libVLC honors: User-Agent and Referer. libVLC exposes no
    /// media option that injects Cookie/Authorization request headers — those
    /// streams route to AVPlayer (`PlaybackController`) via `PlaybackRoute`.
    func vlcOptions(from headers: [String: String]?) -> [String: String] {
        guard let headers else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in headers {
            switch key.lowercased() {
            case "user-agent": out["http-user-agent"] = value
            case "referer": out["http-referrer"] = value
            default: break
            }
        }
        return out
    }
}
