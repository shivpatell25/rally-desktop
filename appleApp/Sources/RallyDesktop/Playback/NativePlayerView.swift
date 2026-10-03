import AVKit
import RallyCore
import SwiftUI

/// AVKit handles transient scrubbing, volume, fullscreen and PiP inside a
/// clipped AppKit host so its video layer stays within Rally's player canvas.
struct NativePlayerView: NSViewRepresentable {
    let controller: PlaybackController
    var showsControls = true
    func makeNSView(context: Context) -> NativePlaybackHost {
        let host = NativePlaybackHost()
        host.playerView.player = controller.player
        host.playerView.controlsStyle = showsControls ? .floating : .none
        return host
    }
    func updateNSView(_ host: NativePlaybackHost, context: Context) {
        if host.playerView.player !== controller.player { host.playerView.player = controller.player }
        let style: AVPlayerViewControlsStyle = showsControls ? .floating : .none
        if host.playerView.controlsStyle != style { host.playerView.controlsStyle = style }
    }
}

final class NativePlaybackHost: NSView {
    let playerView = AVPlayerView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("NativePlaybackHost is created in code") }
}
