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

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }
}
