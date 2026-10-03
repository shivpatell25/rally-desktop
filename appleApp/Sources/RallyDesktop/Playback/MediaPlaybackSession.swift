import MediaPlayer
import Foundation

@MainActor
final class MediaPlaybackSession {
    private var targets: [(MPRemoteCommand, Any)] = []
    func activate(title: String, live: Bool, handler: @escaping (PlayerCommand) -> Void) {
        stop()
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.togglePlayPauseCommand, PlayerCommand.togglePlay), (center.playCommand, .play), (center.pauseCommand, .pause), (center.skipBackwardCommand, .seekBack), (center.skipForwardCommand, .seekForward)] {
            command.isEnabled = true
            let token = command.addTarget { _ in Task { @MainActor in handler(action) }; return .success }
            targets.append((command, token))
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.preferredIntervals = [10]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: "Rally", MPNowPlayingInfoPropertyIsLiveStream: live]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }
    func update(paused: Bool, elapsed: Double) {
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
        if elapsed.isFinite { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
    }
    func stop() {
        for (command, token) in targets { command.removeTarget(token) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
