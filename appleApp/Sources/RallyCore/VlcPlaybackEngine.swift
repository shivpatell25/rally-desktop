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
    private var observers: [String: VlcBufferObserver] = [:]
    private var relays: [String: HTTPStreamProxy] = [:]

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
            observers.removeValue(forKey: slotId)
            players.removeValue(forKey: slotId)?.stop()
            relays.removeValue(forKey: slotId)?.stop()
        }
    }

    public func releaseAll() {
        lock.withLock {
            reserved.removeAll()
            players.values.forEach { $0.stop() }
            players.removeAll(); observers.removeAll()
            relays.values.forEach { $0.stop() }; relays.removeAll()
        }
    }

    public var tileCount: Int { lock.withLock { reserved.count } }

    /// VLC supports UA/Referer directly. Other provider headers need a local
    /// streaming relay so DASH segments and redirected playlists retain them.
    public func prepareURL(slotId: String, url: URL, headers: [String: String]) async throws -> URL {
        lock.withLock { relays.removeValue(forKey: slotId) }?.stop()
        guard headers.keys.contains(where: { !["user-agent", "referer"].contains($0.lowercased()) }) else { return url }
        let relay = HTTPStreamProxy(url: url, headers: headers)
        let local = try await relay.start()
        guard !Task.isCancelled, lock.withLock({ reserved.contains(slotId) }) else { relay.stop(); throw CancellationError() }
        lock.withLock { relays[slotId] = relay }
        return local
    }

    /// Starts playback on a reserved tile. Throws `.tileCapReached` for a new
    /// slotId past the cap, `.unreservedSlot` when the slot was released.
    @MainActor
    public func play(slotId: String, title: String, url: URL, headers: [String: String]? = nil, drawable: NSView? = nil) throws {
        try play(slotId: slotId, title: title, url: url, headers: headers, tuning: nil, drawable: drawable)
    }

    @MainActor
    public func play(slotId: String, title: String, url: URL, headers: [String: String]? = nil,
                     tuning: PlaybackTuning? = nil, drawable: NSView? = nil, maxHeight: Int = 0, renderVideo: Bool = true) throws {
        let known: Bool = lock.withLock { reserved.contains(slotId) }
        guard known else { throw Error.unreservedSlot }
        if lock.withLock({ players[slotId] == nil }) && tileCount > Self.maxTiles {
            throw Error.tileCapReached
        }
        let player: VLCMediaPlayer = lock.withLock {
            if let existing = players[slotId] { return existing }
            let created = renderVideo ? VLCMediaPlayer() : VLCMediaPlayer(options: ["--vout=dummy", "--quiet"])
            let observer = VlcBufferObserver(); created.delegate = observer
            observers[slotId] = observer
            players[slotId] = created
            return created
        }
        lock.withLock { observers[slotId] }?.setProgress(0)
        guard let media = VLCMedia(url: url) else { throw Error.mediaInitFailed }
        media.addOptions(["adaptive-maxheight": maxHeight])
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
        lock.withLock { relays.removeValue(forKey: slotId) }?.stop()
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
        player.audio?.isMuted = muted
    }

    @MainActor
    public func isMuted(slotId: String) -> Bool {
        lock.withLock({ players[slotId] })?.audio?.isMuted ?? false
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

    @MainActor public func seekable(slotId: String) -> Bool { lock.withLock { players[slotId] }?.isSeekable ?? false }
    @MainActor public func seek(slotId: String, fraction: Double) {
        guard let player = lock.withLock({ players[slotId] }), player.isSeekable else { return }
        player.position = min(1, max(0, fraction))
    }
    @MainActor public func seekRelative(slotId: String, seconds: Double) {
        guard let player = lock.withLock({ players[slotId] }), player.isSeekable else { return }
        let ms = max(0, Int(player.time.intValue) + Int(seconds * 1000))
        player.time = VLCTime(int: Int32(ms))
    }
    @MainActor public func elapsedSeconds(slotId: String) -> Double? {
        guard let player = lock.withLock({ players[slotId] }) else { return nil }
        return Double(player.time.intValue) / 1000
    }
    @MainActor public func tracks(slotId: String, captions: Bool) -> [PlaybackTrack] {
        guard let player = lock.withLock({ players[slotId] }) else { return [] }
        return (captions ? player.textTracks : player.audioTracks).enumerated().map {
            PlaybackTrack(id: $0.offset, title: $0.element.trackName, selected: $0.element.isSelected)
        }
    }
    @MainActor public func selectTrack(slotId: String, id: Int, captions: Bool) {
        guard let player = lock.withLock({ players[slotId] }) else { return }
        let tracks = captions ? player.textTracks : player.audioTracks
        if captions && id < 0 { player.deselectAllTextTracks() }
        else if tracks.indices.contains(id) { tracks[id].isSelectedExclusively = true }
    }
    @MainActor public func setVolume(slotId: String, value: Double) {
        lock.withLock { players[slotId] }?.audio?.volume = Int32(min(100, max(0, value * 100)))
    }
    @MainActor public func isBuffering(slotId: String) -> Bool {
        guard let state = lock.withLock({ players[slotId] })?.state else { return false }
        return state == .opening || (lock.withLock { observers[slotId] }?.buffering ?? false)
    }
    @MainActor public func hasError(slotId: String) -> Bool {
        lock.withLock { players[slotId] }?.state == .error
    }

    /// Headers supported directly by libVLC; other headers use prepareURL.
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

private final class VlcBufferObserver: NSObject, VLCMediaPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Float = 1
    var buffering: Bool { lock.withLock { progress < 1 } }
    func setProgress(_ value: Float) { lock.withLock { progress = value } }
    func mediaPlayerBufferingChanged(_ progress: Float) { setProgress(progress) }
}
