import RallyCore
import SwiftUI

extension PlayerView {
    var playbackSurface: some View {
        ZStack(alignment: .topTrailing) {
            if state.avActive { NativePlayerView(controller: state.avController, showsControls: !gameMode || gameVideoHovered) }
            else { VideoHost(host: host) }
            if !gameMode, let image = tvArt("rally_mark_ui") {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 24, height: 24)
                    .opacity(0.7).padding(16).allowsHitTesting(false)
            }
            if state.isLoading || state.buffering {
                ProgressView(state.isLoading ? "Finding a broadcast…" : "Buffering…")
                    .padding(20).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    var nativePlaybackMenus: some View {
        HStack(spacing: 12) {
            sourceMenu
            qualityMenu
            audioMenu
            captionsMenu
        }.menuStyle(.borderlessButton).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textPrimary)
    }
    var sourceMenu: some View {
            Menu {
                ForEach(state.candidates) { candidate in
                    Button {
                        Task { await state.switchTo(candidate, store: store, drawable: host.surface) }
                    } label: {
                        Text((state.primary?.id == candidate.id ? "✓ " : "") + candidate.title)
                    }
                }
                if state.candidates.isEmpty { Text("No sources found") }
                Divider()
                Button("Source Details…") { pickerVisible = true }
            } label: { Label("Source", systemImage: "dot.radiowaves.left.and.right") }
    }
    var qualityMenu: some View {
            Menu {
                Button("Auto") { Task { await state.selectQuality(nil, store: store, drawable: host.surface) } }
                ForEach(state.qualities) { quality in
                    Button("\(String(quality.height))p") { Task { await state.selectQuality(quality, store: store, drawable: host.surface) } }
                }
                if state.qualities.isEmpty {
                    Text("This source publishes a single quality.")
                    ForEach(state.candidates.filter { $0.id != state.primary?.id }) { candidate in
                        Button(candidate.title) { Task { await state.switchTo(candidate, store: store, drawable: host.surface) } }
                    }
                }
            } label: { Label(state.qualityLabel, systemImage: "slider.horizontal.3") }
    }
    var audioMenu: some View {
            Menu {
                ForEach(state.audioTracks) { track in
                    Button((track.selected ? "✓ " : "") + track.title) { state.selectTrack(track.id, captions: false) }
                }
                if state.audioTracks.isEmpty { Text("No alternate audio published") }
            } label: { Label("Audio", systemImage: "speaker.wave.2") }
    }
    var captionsMenu: some View {
            Menu {
                Button("Off") { state.selectTrack(-1, captions: true) }
                ForEach(state.captionTracks) { track in
                    Button((track.selected ? "✓ " : "") + track.title) { state.selectTrack(track.id, captions: true) }
                }
                if state.captionTracks.isEmpty { Text("This broadcast has no captions") }
            } label: { Label("Captions", systemImage: "captions.bubble") }
    }
    var desktopTransport: some View {
        VStack(spacing: 10) {
            if state.canSeek && (!state.avActive || gameMode) {
                Slider(value: Binding(get: { state.positionFraction }, set: { state.positionFraction = $0; state.seek($0) }), in: 0...1)
                    .tint(.white).accessibilityLabel("Playback position")
            }
            HStack(spacing: 12) {
                if !state.avActive || gameMode {
                Button { state.togglePause() } label: { Image(systemName: state.paused ? "play.fill" : "pause.fill") }
                    .disabled(!state.isPlaying).help("Play / Pause (Space)")
                }
                if !gameMode {
                    Button { state.fromStart() } label: { Label("Restart", systemImage: "backward.end") }
                        .disabled(!state.canSeek).help(state.canSeek ? "Start of available recording" : "This broadcast has no DVR window")
                }
                if !isHighlightPlayback && (channel != nil || event?.status == .live || event?.status == .halftime) {
                    Button("Live Edge") { state.liveEdge() }.disabled(!state.canSeek)
                }
                Text(state.positionText).font(.caption.monospacedDigit()).foregroundStyle(RallyTheme.textSecondary)
                Spacer()
                if !state.avActive || gameMode {
                Button { state.toggleMute() } label: { Image(systemName: state.muted ? "speaker.slash" : "speaker.wave.2") }.help("Mute (M)")
                Slider(value: Binding(get: { state.volume }, set: { state.setVolume($0) }), in: 0...1).frame(width: 84).accessibilityLabel("Volume")
                Button { toggleFullscreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full Screen (⌃⌘F)")
                }
            }.buttonStyle(.plain).font(RallyFont.font(size: 12)).foregroundStyle(.white)
        }
    }
    func retryPlayback() async {
        if state.candidates.isEmpty { await state.load(event: event, channel: channel, store: store, drawable: host.surface, source: source) }
        else { await state.retry(store: store, drawable: host.surface) }
    }
    func handlePlayerCommand(_ command: PlayerCommand) {
        switch command {
        case .togglePlay: state.togglePause()
        case .play: if state.paused { state.togglePause() }
        case .pause: if !state.paused { state.togglePause() }
        case .seekBack: state.seekRelative(-10)
        case .seekForward: state.seekRelative(10)
        case .mute: state.toggleMute()
        case .fromStart: state.fromStart()
        case .liveEdge: state.liveEdge()
        case .source: pickerVisible = true
        case .dismiss:
            if pickerVisible { pickerVisible = false }
            else if diagVisible { diagVisible = false }
            else if state.clipOverlay != nil { state.closeClipOverlay() }
            else if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            else { store.show(nil) }
        }
        controlsVisible = true
    }
}
