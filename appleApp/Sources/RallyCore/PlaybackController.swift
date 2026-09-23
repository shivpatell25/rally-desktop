import AppKit
import AVFoundation
import Foundation

/// Playback slot controller. v1: AVFoundation for ESPN HLS + direct HLS addons.
/// VLC (VLCKit) lands next: it takes over non-standard IPTV/Stremio transports
/// (odd codecs, TS, RTMP-ish) that AVPlayer rejects. Cap stays 4 tiles @720p30,
/// mirroring Android low-memory Multi-View tracks/buffers.
@MainActor
public final class PlaybackController: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var error: String?
    public let player = AVPlayer()
    private var layer: AVPlayerLayer?

    public init() {}

    public func play(url: URL, headers: [String: String]? = nil) {
        error = nil
        var item: AVPlayerItem
        if let headers, !headers.isEmpty {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
    }

    /// Hosts video in a plain NSView (the VLC drawable stays untouched, so
    /// switching engines never fights over one layer).
    public func attach(to view: NSView) {
        view.wantsLayer = true
        if layer?.superlayer !== view.layer {
            layer?.removeFromSuperlayer()
            let fresh = AVPlayerLayer(player: player)
            fresh.frame = view.bounds
            fresh.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(fresh)
            layer = fresh
        }
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func resume() {
        player.play()
        isPlaying = true
    }

    public func position() -> (fraction: Double, clock: String)? {
        guard let item = player.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 else { return nil }
        let pos = player.currentTime().seconds
        let s = max(0, Int(pos))
        return (pos / item.duration.seconds, String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60))
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }
}
