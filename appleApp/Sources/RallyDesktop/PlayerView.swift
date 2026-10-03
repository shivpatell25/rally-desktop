import AppKit
import RallyCore
import SwiftUI
import VLCKit

/// Hosts a libVLC drawable. The engine starts playback once the view exists.
struct VLCVideoView: NSViewRepresentable {
    var onReady: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = RallyVideoHost()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        DispatchQueue.main.async { onReady(view.surface) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Displays a caller-owned NSView so one drawable survives relayouts.
struct VideoHost: NSViewRepresentable {
    var host: NSView
    func makeNSView(context: Context) -> NSView { host }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class PlayerState: ObservableObject {
    @Published var candidates: [PlayCandidate] = []
    @Published var primary: PlayCandidate?
    @Published var isLoading = true
    @Published var error: String?
    @Published var candidateNote: [String: String] = [:]
    @Published var trace: [String] = []
    @Published var isPlaying = false
    @Published var paused = false
    @Published var muted = false
    @Published var plays: [GamePlay] = []
    @Published var liveContext: [String: String] = [:]
    @Published var activeEvent: SportEvent?
    @Published var leaders: [PlayerLeader] = []
    @Published var clips: [HighlightClip] = []
    @Published var tables: [PlayerStatTable] = []
    @Published var teamStats: [TeamStatComparison] = []
    @Published var homeWinPct: Double?
    @Published var awayWinPct: Double?
    @Published var detailLoading = false
    @Published var positionText = "0:00:00"
    @Published var positionFraction: Double = 0
    @Published var showDiagnostics = false
    @Published var recoveryAttempts = 0
    @Published var stallCount = 0
    @Published var adaptiveReason: String?
    @Published var profileName = "Standard"
    /// Highlights use a separate native player while the live session continues.
    @Published var clipOverlay: HighlightClip?
    /// AVPlayer route for header-gated HLS (Cookie/Authorization libVLC
    /// cannot inject). Own host view; the VLC drawable is never shared.
    let avController = PlaybackController()
    @Published var canSeek = false
    @Published var audioTracks: [PlaybackTrack] = []
    @Published var captionTracks: [PlaybackTrack] = []
    @Published var qualities: [PlaybackQuality] = []
    @Published var qualityLabel = "Auto"
    @Published var buffering = false
    @Published var volume: Double = 1
    @Published var avActive = false
    let engine = VlcEngine()
    let mediaSession = MediaPlaybackSession()
    private let slotId = UUID().uuidString
    private var transportURL: URL?
    private var transportHeaders: [String: String] = [:]
    private var startedAt = Date()
    private var sessionRevision = 0
    private var requestGeneration = UUID()
    private var progress = PlaybackProgress()
    private var recovering = false
    private var sleepActivity: NSObjectProtocol?
    private var detailTask: Task<Void, Never>?
    let clipController = PlaybackController()
    private var primaryMuteBeforeClip = false
    /// Candidates that already failed this session (Android blacklist).
    private var failedTargets: Set<String> = []

    private func log(_ line: String) {
        let stamped = "[Player] \(line)"
        trace.append(stamped)
        if trace.count > 30 { trace.removeFirst(trace.count - 30) }
        NSLog("%@", stamped)
    }

    func load(event: SportEvent?, channel: IptvChannel?, store: RallyStore, drawable: NSView, source: PlayCandidate? = nil) async {
        sessionRevision += 1
        requestGeneration = UUID()
        progress.reset()
        engine.stop(slotId: slotId); avController.stop()
        let revision = sessionRevision
        detailTask?.cancel()
        plays = []; liveContext = [:]; leaders = []; clips = []; tables = []; teamStats = []
        activeEvent = event
        isLoading = true
        error = nil
        isPlaying = false
        paused = false
        primary = nil
        defer { if revision == sessionRevision { isLoading = false } }
        if source == nil { await store.ensureChannels() }
        guard !Task.isCancelled, revision == sessionRevision else { return }
        candidateNote = [:]
        failedTargets.removeAll()
        recoveryAttempts = 0
        stallCount = 0
        adaptiveReason = nil
        var cands: [PlayCandidate] = []
        if let source { cands = [source] }
        else if let event {
            let addons = store.settings.stremioAddonUrls
            log("event=\(event.id) addons=\(addons.count) channels=\(store.channels.count)")
            let options = await withTaskGroup(of: [StremioStreamOption].self) { group in
                for base in addons {
                    group.addTask { await store.stremioClient.findStreams(for: event, addonBase: base) }
                }
                var out: [StremioStreamOption] = []
                for await opts in group { out.append(contentsOf: opts) }
                return out
            }
            log("stremio options=\(options.count) (playable=\(options.filter { $0.isDirectPlayable }.count))")
            guard !Task.isCancelled, revision == sessionRevision else { return }
            cands = StreamResolver.candidates(event: event, channels: store.channels, stremioOptions: options)
        } else if let channel {
            log("direct channel=\(channel.id)")
            cands = StreamResolver.channelCandidates([channel])
        }
        candidates = cands
        log("candidates=\(cands.count) stremio=\(cands.filter { $0.kind == .stremio }.count) iptv=\(cands.filter { $0.kind == .iptv }.count)")
        await preflightTopCandidates(store: store)
        guard !Task.isCancelled, revision == sessionRevision else { return }
        if let event, let path = EspnClient.path(forLeague: event.league) {
            detailLoading = true
            detailTask = Task {
                let detail = await store.espnClient.fetchSummary(sport: path.sport, league: path.path, eventId: event.id, awayAbbr: event.awayTeam?.abbreviation, homeAbbr: event.homeTeam?.abbreviation)
                guard !Task.isCancelled, revision == sessionRevision else { return }
                if let current = detail.event { activeEvent = current }
                plays = detail.plays
                liveContext = detail.liveContext
                leaders = detail.leaders
                clips = detail.clips
                tables = detail.playerTables
                teamStats = detail.teamStats
                homeWinPct = detail.homeWinPct
                awayWinPct = detail.awayWinPct
                detailLoading = false
                log("detail leaders=\(detail.leaders.count) clips=\(detail.clips.count)")
            }
        }
        guard !candidates.isEmpty else {
            error = "No playable sources found"
            log("empty: check addon URLs and IPTV provider in Settings")
            return
        }
        // Autoplay the verified exact match; fall back to top rank when
        // nothing verified yet (desktop keeps v1 autoplay).
        await play(StreamResolver.primary(from: candidates) ?? candidates[0], store: store, drawable: drawable)
    }

    /// Probes the top-5 Stremio candidates by rank (Android `SelectBestStreamUseCase`).
    /// Verified rows sort up; failed rows are labeled so playback skips dead URLs.
    private func preflightTopCandidates(store: RallyStore) async {
        let settings = store.settings
        let targets = candidates.filter { $0.kind == .stremio }
            .sorted { $0.rank > $1.rank }.prefix(5)
        await withTaskGroup(of: (String, StreamPreflightResult).self) { group in
            for cand in targets {
                group.addTask { (cand.id, await StreamPreflightProbe.shared.probe(url: cand.url, headers: cand.headers ?? [:])) }
            }
            for await (id, result) in group {
                if let i = candidates.firstIndex(where: { $0.id == id }) {
                    candidates[i].preflightPassed = result.passed
                    candidates[i].preflightLatencyMs = result.latencyMs
                    candidates[i].preflightContentType = result.contentType
                    candidateNote[id] = result.passed ? "Verified \(result.latencyMs) ms" : "Unreachable: \(result.detail)"
                }
            }
        }
        candidates = StreamResolver.sort(candidates) { settings.streamHealth(target: $0).score }
    }
    /// Explicit single attempt (user-picked source): no auto-walk.
    func switchTo(_ candidate: PlayCandidate, store: RallyStore, drawable: NSView) async {
        requestGeneration = UUID(); progress.reset(); failedTargets.remove(candidate.id)
        error = nil
        _ = await attempt(candidate, store: store, drawable: drawable)
    }

    /// Plays an ESPN highlight clip as a one-off Stremio-kind candidate.
    func playClip(_ clip: HighlightClip, store: RallyStore, drawable: NSView) async {
        requestGeneration = UUID(); progress.reset()
        guard let url = clip.streamUrl, !url.isEmpty else {
            error = "Highlight has no playable stream"
            return
        }
        error = nil
        _ = await attempt(PlayCandidate(title: clip.title, url: url, kind: .stremio,
                                        exactMatch: true, rank: 0, addonName: "ESPN"),
                          store: store, drawable: drawable)
    }

    /// Opens a highlight in the overlay player; the live slot keeps playing.
    func openClipOverlay(_ clip: HighlightClip) {
        guard let urlString = clip.streamUrl, let url = URL(string: urlString), url.host != nil else {
            candidateNote[clip.id] = "Highlight has no playable stream"
            return
        }
        primaryMuteBeforeClip = muted
        avController.player.isMuted = true
        engine.setMuted(slotId: slotId, muted: true)
        clipController.play(url: url)
        clipOverlay = clip
    }

    func closeClipOverlay() {
        clipController.stop()
        avController.player.isMuted = primaryMuteBeforeClip
        engine.setMuted(slotId: slotId, muted: primaryMuteBeforeClip)
        muted = primaryMuteBeforeClip
        clipOverlay = nil
    }

    /// Restart replays the current source from scratch.
    func restart(store: RallyStore, drawable: NSView) async {
        requestGeneration = UUID(); progress.reset()
        guard let p = primary else {
            await retry(store: store, drawable: drawable)
            return
        }
        error = nil
        candidateNote[p.id] = nil
        log("restarting \(p.title)")
        await play(p, store: store, drawable: drawable)
    }

    /// A manual retry starts a fresh bounded source recovery pass.
    func retry(store: RallyStore, drawable: NSView) async {
        requestGeneration = UUID(); progress.reset()
        failedTargets.removeAll(); candidateNote = [:]; error = nil
        guard let candidate = primary ?? candidates.first else { error = "No playable sources found"; return }
        await play(candidate, store: store, drawable: drawable)
    }

    /// Autoplay entry with bounded auto-recovery (Android
    /// `recoverFromPlaybackFailure`): blacklist failures, try at most 3
    /// candidates, terminal error only after exhausting them.
    private func play(_ candidate: PlayCandidate, store: RallyStore, drawable: NSView) async {
        error = nil
        recoveryAttempts = 0
        let intent = requestGeneration
        var next: PlayCandidate? = candidate
        var attempts = 0
        while let cand = next, attempts < 3, !Task.isCancelled, intent == requestGeneration {
            attempts += 1
            if await attempt(cand, store: store, drawable: drawable) { return }
            guard intent == requestGeneration, !Task.isCancelled else { return }
            recoveryAttempts += 1
            next = StreamResolver.sort(candidates.filter {
                !failedTargets.contains($0.id) && $0.id != cand.id
            }) { store.settings.streamHealth(target: $0).score }.first
        }
        guard intent == requestGeneration else { return }
        if !isPlaying, error == nil { error = "All sources failed" }
        log("autoplay done playing=\(isPlaying) attempts=\(attempts)")
    }

    private func tuning(for store: RallyStore) -> (profile: PlaybackProfile, tuning: PlaybackTuning) {
        let profile = PlaybackProfile.resolve(lowLatency: store.settings.lowLatencyMode)
        profileName = profile.name
        let tuning = PlaybackTuning(lowLatency: store.settings.lowLatencyMode,
                                    audioNormalization: store.settings.audioNormalizationEnabled,
                                    networkCachingMs: profile.networkCachingMs)
        return (profile, tuning)
    }

    /// Single engine attempt. Returns false on failure (blacklisted); the
    /// caller decides whether to walk on.
    private func attempt(_ candidate: PlayCandidate, store: RallyStore, drawable: NSView) async -> Bool {
        let revision = sessionRevision, intent = requestGeneration
        guard !Task.isCancelled else { return false }
        isLoading = true; isPlaying = false; buffering = true
        engine.stop(slotId: slotId); avController.stop()
        let wasPaused = paused
        defer { if intent == requestGeneration { isLoading = false } }
        error = nil
        candidateNote[candidate.id] = "Resolving…"
        var urlString = candidate.url
        // Resolve provider-issued URLs (Stalker cmd / bare xtream ids).
        if candidate.kind == .iptv, let ch = candidate.channel {
            if store.settings.iptvProvider == .stalker {
                urlString = await store.stalkerClient.resolveStreamUrl(channelId: ch.id)
            } else if store.settings.iptvProvider == .xtream {
                urlString = await store.xtreamClient.resolveStreamUrl(channelId: ch.id)
            }
            if urlString != ch.id, urlString != ch.streamUrl {
                if let i = candidates.firstIndex(where: { $0.id == candidate.id }) {
                    candidates[i].url = urlString
                }
            }
        }
        guard !Task.isCancelled, revision == sessionRevision, intent == requestGeneration else { return false }
        guard let url = URL(string: urlString), let host = url.host else {
            candidateNote[candidate.id] = "Bad stream URL"
            error = "Bad stream URL"
            store.settings.recordStreamFailure(target: candidate.url)
            failedTargets.insert(candidate.id)
            log("bad url kind=\(candidate.kind)")
            return false
        }
        log("try kind=\(candidate.kind) host=\(host) exact=\(candidate.exactMatch)")
        startedAt = Date()
        qualities = []; qualityLabel = "Auto"
        let safeHeaders = StreamRequestHeaders.sanitized(candidate.headers ?? candidate.channel?.streamHeaders ?? channelHeaders(store, candidate))
        transportURL = url; transportHeaders = safeHeaders
        engine.stop(slotId: slotId)
        avController.stop()
        paused = false
        let isHlsRoute = PlaybackRoute.usesAVPlayer(headers: safeHeaders, url: url)
        if isHlsRoute {
            avController.play(url: url, headers: safeHeaders, lowLatency: store.settings.lowLatencyMode)
            avActive = true
            buffering = true
            let ready = await avController.waitUntilReady()
            guard !Task.isCancelled, revision == sessionRevision, intent == requestGeneration else { return false }
            if ready {
                primary = candidate; isPlaying = true; stallCount = 0; buffering = false
                avController.player.volume = Float(volume); avController.player.isMuted = muted
                if wasPaused { avController.pause(); paused = true }
                progress.reset(keepBudget: true)
                candidateNote[candidate.id] = "Playing (AVKit)"
                store.settings.recordStreamSuccess(target: candidate.url, startupMs: Int64(Date().timeIntervalSince(startedAt) * 1000))
                return true
            }
            avController.stop()
            // Try the same transport with VLC before rejecting this source.
            log("AVKit rejected stream; trying compatibility playback")
        }
        avActive = false
        do {
            _ = engine.reserve(slotId: slotId)
            let (_, tuning) = tuning(for: store)
            let playable = try await engine.prepareURL(slotId: slotId, url: url, headers: safeHeaders)
            guard !Task.isCancelled, revision == sessionRevision, intent == requestGeneration else { return false }
            try engine.play(slotId: slotId, title: candidate.title, url: playable,
                            headers: safeHeaders.isEmpty ? nil : safeHeaders,
                            tuning: tuning, drawable: drawable)
            let deadline = Date().addingTimeInterval(12)
            while (!engine.isPlaying(slotId: slotId) || engine.isBuffering(slotId: slotId)) && !engine.hasError(slotId: slotId) && Date() < deadline && !Task.isCancelled && intent == requestGeneration {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard revision == sessionRevision, intent == requestGeneration else { return false }
            guard engine.isPlaying(slotId: slotId), !Task.isCancelled else {
                throw NSError(domain: "Rally.Playback", code: 1, userInfo: [NSLocalizedDescriptionKey: "The source did not start playback."])
            }
            primary = candidate
            Task {
                let options = await PlaybackController.loadQualities(url: url, headers: safeHeaders)
                if primary?.id == candidate.id && revision == sessionRevision && intent == requestGeneration { qualities = options }
            }
            isPlaying = true
            buffering = false
            engine.setVolume(slotId: slotId, value: volume); engine.setMuted(slotId: slotId, muted: muted)
            if wasPaused { engine.pause(slotId: slotId); paused = true }
            progress.reset(keepBudget: true)
            stallCount = 0
            candidateNote[candidate.id] = "Playing"
            let ms = Int64(Date().timeIntervalSince(startedAt) * 1000)
            store.settings.recordStreamSuccess(target: candidate.url, startupMs: ms)
            log("playing startupMs=\(ms) profile=\(profileName) norm=\(store.settings.audioNormalizationEnabled)")
            return true
        } catch {
            guard intent == requestGeneration, !Task.isCancelled else { return false }
            isPlaying = false
            buffering = false
            candidateNote[candidate.id] = "Failed: \(error.localizedDescription)"
            self.error = "Playback failed: \(error.localizedDescription)"
            store.settings.recordStreamFailure(target: candidate.url)
            failedTargets.insert(candidate.id)
            log("failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Stall watchdog (1s timer): an engine that stopped on its own while
    /// playing counts a stall; with adaptive quality on, repeated stalls step
    /// down once with a reason instead of spinning forever.
    func watchdog(store: RallyStore, drawable: NSView) async {
        guard primary != nil, (isPlaying || error == nil), !paused, !isLoading, !recovering else { return }
        if avActive && avController.ended { isPlaying = false; return }
        let seconds = avActive ? avController.player.currentTime().seconds : engine.elapsedSeconds(slotId: slotId)
        let failed = avActive ? avController.error != nil : engine.hasError(slotId: slotId)
        guard failed || progress.stalled(position: seconds, paused: paused) else { return }
        guard let current = primary else { return }
        recovering = true
        defer { recovering = false }
        stallCount += 1
        store.settings.recordStreamStall(target: current.url)
        if progress.consumeReconnect() {
            recoveryAttempts += 1
            adaptiveReason = "Reconnecting a stalled broadcast"
            _ = await attempt(current, store: store, drawable: drawable)
        } else {
            failedTargets.insert(current.id)
            if let next = candidates.first(where: { !failedTargets.contains($0.id) }) {
                adaptiveReason = "Trying another available source"
                await play(next, store: store, drawable: drawable)
            } else { error = "The broadcast stopped. Retry or pick another source."; isPlaying = false; buffering = false }
        }
    }
    private func channelHeaders(_ store: RallyStore, _ candidate: PlayCandidate) -> [String: String]? {
        guard candidate.kind == .iptv else { return nil }
        if store.settings.iptvProvider == .stalker {
            let mac = store.settings.macAddress
            var headers = ["User-Agent": "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"]
            if !mac.isEmpty { headers["Cookie"] = "mac=\(mac); stb_lang=en; timezone=GMT" }
            let token = store.settings.authToken
            if !token.isEmpty { headers["Authorization"] = StreamRequestHeaders.normalizedBearerToken(token) }
            return headers
        }
        return nil
    }

    func togglePause() {
        if avActive {
            if paused { avController.resume() } else { avController.pause() }
            paused = !paused
        } else if paused {
            engine.resume(slotId: slotId)
            paused = false
        } else {
            engine.pause(slotId: slotId)
            paused = true
        }
        mediaSession.update(paused: paused, elapsed: avController.player.currentTime().seconds)
        log(paused ? "paused" : "resumed")
    }

    func seek(_ fraction: Double) {
        if avActive { avController.seek(fraction: fraction) } else { engine.seek(slotId: slotId, fraction: fraction) }
    }
    func seekRelative(_ seconds: Double) {
        if avActive { avController.seekRelative(seconds) } else { engine.seekRelative(slotId: slotId, seconds: seconds) }
    }
    func fromStart() { if avActive { avController.watchFromStart() } else { seek(0) } }
    func liveEdge() { if avActive { avController.goLive() } else { seek(1) } }
    func selectTrack(_ id: Int, captions: Bool) {
        if avActive { avController.selectTrack(id, captions: captions) }
        else { engine.selectTrack(slotId: slotId, id: id, captions: captions) }
        refreshStats()
    }
    func setVolume(_ value: Double) {
        volume = value
        if avActive { avController.player.volume = Float(value) } else { engine.setVolume(slotId: slotId, value: value) }
    }
    func teardown() {
        sessionRevision += 1; requestGeneration = UUID()
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
        detailTask?.cancel(); detailTask = nil
        mediaSession.stop()
        engine.release(slotId: slotId)
        avController.stop()
        avActive = false
        clipController.stop()
        clipOverlay = nil
        isPlaying = false
        paused = false
    }

    func toggleMute() {
        if avActive {
            avController.player.isMuted = !avController.player.isMuted
            muted = avController.player.isMuted
        } else {
            engine.setMuted(slotId: slotId, muted: !muted)
            muted = engine.isMuted(slotId: slotId)
        }
        log(muted ? "muted" : "unmuted")
    }

    func selectQuality(_ quality: PlaybackQuality?, store: RallyStore, drawable: NSView) async {
        requestGeneration = UUID(); progress.reset()
        let generation = requestGeneration
        if avActive { avController.setQuality(quality) }
        else if let candidate = primary, let url = transportURL {
            let position = positionFraction, wasPaused = paused, revision = sessionRevision
            buffering = true
            do {
                engine.stop(slotId: slotId)
                let playable = try await engine.prepareURL(slotId: slotId, url: url, headers: transportHeaders)
                guard !Task.isCancelled, revision == sessionRevision, generation == requestGeneration else { return }
                let (_, tuning) = tuning(for: store)
                try engine.play(slotId: slotId, title: candidate.title, url: playable,
                                headers: transportHeaders, tuning: tuning, drawable: drawable, maxHeight: quality?.height ?? 0)
                let deadline = Date().addingTimeInterval(12)
                while (!engine.isPlaying(slotId: slotId) || engine.isBuffering(slotId: slotId)) && !engine.hasError(slotId: slotId) && Date() < deadline && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard revision == sessionRevision, generation == requestGeneration else { return }
                engine.seek(slotId: slotId, fraction: position)
                if wasPaused { engine.pause(slotId: slotId) }
                if !engine.isPlaying(slotId: slotId) && !wasPaused { error = "This quality could not start. Pick Auto or another source." }
            } catch { if generation == requestGeneration { self.error = error.localizedDescription } }
            guard generation == requestGeneration else { return }
            buffering = false
        }
        qualityLabel = quality.map { "\($0.height)p" } ?? "Auto"
    }

    func refreshStats() {
        let awake = isPlaying && !paused
        if awake && sleepActivity == nil { sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Watching Rally") }
        if !awake, let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
        if avActive {
            if let pos = avController.position() {
                positionFraction = pos.fraction
                positionText = pos.clock
            }
            canSeek = avController.seekRange != nil
            buffering = avController.isBuffering
            if primary != nil && !buffering {
                paused = avController.player.timeControlStatus == .paused && avController.error == nil
                isPlaying = avController.isPlaying || paused
            }
            muted = avController.player.isMuted
            volume = Double(avController.player.volume)
            mediaSession.update(paused: paused, elapsed: avController.player.currentTime().seconds)
            avController.refreshTracks()
            audioTracks = avController.audioTracks; captionTracks = avController.captionTracks
            qualities = avController.qualities
            return
        }
        if let pos = engine.position(slotId: slotId) {
            positionFraction = pos.fraction
            positionText = pos.clock
        }
        buffering = engine.isBuffering(slotId: slotId)
        canSeek = engine.seekable(slotId: slotId)
        audioTracks = engine.tracks(slotId: slotId, captions: false)
        captionTracks = engine.tracks(slotId: slotId, captions: true)
    }
}

struct PlayerView: View {
    @EnvironmentObject var store: RallyStore
    @StateObject var state = PlayerState()
    @State var host = RallyVideoHost()
    @State private var started = false
    @State var controlsVisible = true
    @State var pickerVisible = false
    @State var gameMode = false
    @State var gameVideoHovered = false
    @State var gameStatsExpanded = false
    @State var momentsTab = 0
    @State var topTab = 0
    @State var infoTab = 0
    @State var requestedPlayID: String?
    @State var playerTeamIndex = 0
    @FocusState var liveFocus: String?
    @State var diagVisible = false
    @State private var lastMove = Date()
    let initialEvent: SportEvent?
    var event: SportEvent? { state.activeEvent ?? initialEvent }
    var isHighlightPlayback: Bool { clip != nil && (state.primary == nil || state.primary?.url == clip?.streamUrl) }
    let channel: IptvChannel?
    var clip: HighlightClip?
    var startWithPicker = false
    var source: PlayCandidate?
    init(event: SportEvent?, channel: IptvChannel?, clip: HighlightClip? = nil, startWithPicker: Bool = false, source: PlayCandidate? = nil) {
        initialEvent = event; self.channel = channel; self.clip = clip; self.startWithPicker = startWithPicker; self.source = source
    }
    var body: some View {
        ZStack {
            if gameMode { gameViewLayout } else { watchLayout }
            if gameMode && pickerVisible { pickerPanel }
            if gameMode && diagVisible { diagnosticsPanel }
            if gameMode, let error = state.error, !state.isLoading { playbackErrorOverlay(error) }
        }
        .onAppear {
            gameMode = LaunchArgs.gameMode || (event != nil && !isHighlightPlayback)
            #if DEBUG
            let playback = state
            RallyAuditHost.playerInfo = { [weak playback] in
                guard let state = playback else { return "" }
                return "player engine=\(state.avActive ? "AVKit" : "VLC") playing=\(state.isPlaying) paused=\(state.paused) loading=\(state.isLoading) buffering=\(state.buffering) clock=\(state.positionText) muted=\(state.muted) volume=\(state.volume) error=\(state.error ?? "none")"
            }
            #endif
        }
        .background { RallyEscapeHandler { handlePlayerCommand(.dismiss) }.frame(width: 0, height: 0) }
        .background(Color.black)
        .onReceive(NotificationCenter.default.publisher(for: .rallyPlayerCommand)) { note in
            if let command = note.object as? PlayerCommand { handlePlayerCommand(command) }
        }
        .onExitCommand { handlePlayerCommand(.dismiss) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                state.refreshStats()
                await state.watchdog(store: store, drawable: host.surface)
            }
        }
        .task(id: event?.id) {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let current = event, let path = EspnClient.path(forLeague: current.league) else { continue }
                if let events = try? await store.espnClient.fetchScoreboard(sport: path.sport, league: path.path, domainLeague: current.league),
                   let updated = events.first(where: { $0.id == current.id }) { state.activeEvent = updated }
                let detail = await store.espnClient.fetchSummary(sport: path.sport, league: path.path, eventId: current.id,
                    awayAbbr: current.awayTeam?.abbreviation, homeAbbr: current.homeTeam?.abbreviation)
                if detail.isAvailable {
                    if let current = detail.event { state.activeEvent = current }
                    state.plays = detail.plays; state.liveContext = detail.liveContext
                    state.leaders = detail.leaders; state.teamStats = detail.teamStats; state.tables = detail.playerTables; state.clips = detail.clips
                }
            }
        }
        .task {
            host.wantsLayer = true
            if !started {
                started = true
                do {
                    let direct = source ?? clip.flatMap { clip in clip.streamUrl.map {
                        PlayCandidate(title: clip.title, url: $0, kind: .stremio, exactMatch: true, rank: 0, addonName: "ESPN")
                    } }
                    await state.load(event: event, channel: channel, store: store, drawable: host.surface, source: direct)
                    guard !Task.isCancelled else { return }
                    state.mediaSession.activate(title: event?.rallyMatchup ?? channel?.name ?? source?.title ?? "Rally", live: clip == nil) { [weak state = state] command in
                        guard let state else { return }
                        switch command {
                        case .togglePlay: state.togglePause()
                        case .play: if state.paused { state.togglePause() }
                        case .pause: if !state.paused { state.togglePause() }
                        case .seekBack: state.seekRelative(-10)
                        case .seekForward: state.seekRelative(10)
                        default: break
                        }
                    }
                    if startWithPicker {
                        pickerVisible = true
                        controlsVisible = true
                    }
                }
            }
        }
        .onDisappear {
            state.teardown()
            #if DEBUG
            RallyAuditHost.playerInfo = { "" }
            #endif
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                if !gameMode && !state.paused && !pickerVisible && !diagVisible && Date().timeIntervalSince(lastMove) > 3 { controlsVisible = false }
            }
        }
    }

    private var watchLayout: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                playbackSurface.frame(width: geo.size.width, height: geo.size.height)
                VStack {
                    hudTop
                    Spacer()
                    hudBottom
                }.opacity(controlsVisible || pickerVisible || diagVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible || pickerVisible || diagVisible)
                    .rallyAnimation(.easeOut(duration: 0.18), value: controlsVisible)
                if pickerVisible { pickerPanel }
                if diagVisible { diagnosticsPanel }
                if let error = state.error, !state.isLoading { playbackErrorOverlay(error) }
            }.onContinuousHover { phase in
                if case .active = phase { lastMove = Date(); controlsVisible = true }
            }.onTapGesture { controlsVisible = true; lastMove = Date() }
        }
    }

    var hudTop: some View {
        HStack(spacing: 14) {
            if let image = tvArt("rally_mark_ui") { Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28) }
            Button { store.show(nil) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Back (Escape)")
            VStack(alignment: .leading, spacing: 3) {
                Text(isHighlightPlayback ? (clip?.title ?? "Highlight") : (channel?.name ?? event?.rallyMatchup ?? source?.title ?? "Rally"))
                    .font(RallyFont.font(size: 14, weight: .semibold)).lineLimit(1)
                Text(isHighlightPlayback ? "Game Highlight" : (event?.gameStatusDetail ?? channel?.category ?? state.primary?.addonName ?? (state.primary == nil ? "Finding a source…" : "Broadcast")))
                    .font(.caption).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
            }
            Spacer()
            if let event, !isHighlightPlayback {
                Text(scoreLine(event)).font(RallyFont.font(size: 14, weight: .bold)).monospacedDigit().lineLimit(1)
                StatusBadge(status: event.status)
            }
        }.foregroundStyle(RallyTheme.textPrimary).padding(.horizontal, 20).padding(.vertical, 12)
            .background(.black.opacity(0.65))
    }

    var hudBottom: some View {
        VStack(spacing: 12) {
            desktopTransport
            HStack(spacing: 8) {
                playerButton(state.paused ? "Play" : "Pause", primary: true) { state.togglePause() }
                if event != nil { playerButton("Game View") { gameMode = true } }
                playerButton("Restart") { state.fromStart() }.disabled(!state.canSeek)
                playerButton("Multiview") { openMultiView() }
                audioMenu.fixedSize()
                captionsMenu.fixedSize()
                sourceMenu.fixedSize()
                qualityMenu.fixedSize()
                playerButton("Diagnostics") { diagVisible.toggle() }
            }.menuStyle(.borderlessButton).font(RallyFont.font(size: 12)).foregroundStyle(.white)
        }.padding(.horizontal, 24).padding(.vertical, 18).background(.black.opacity(0.65))
    }

    func playerButton(_ label: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(RallyFont.font(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(primary ? Color.black : RallyTheme.textPrimary)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(primary ? RallyTheme.offWhite : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func scoreLine(_ event: SportEvent) -> String {
        let away = event.awayTeam?.abbreviation ?? event.awayTeam?.name ?? "AWY"
        let home = event.homeTeam?.abbreviation ?? event.homeTeam?.name ?? "HME"
        if let a = event.scoreAway, let h = event.scoreHome { return "\(away) \(a)  ·  \(home) \(h)" }
        return "\(away) at \(home)"
    }

    func specsLine(_ p: PlayCandidate) -> String {
        var parts: [String] = []
        let q = parseQualityFromChannelName(p.addonName ?? p.title)
        if let r = q.resolution { parts.append(r) }
        if q.isHdr { parts.append("HDR") }
        if let f = q.fps { parts.append(f) }
        parts.append(p.kind == .stremio ? "Stremio" : "IPTV")
        return parts.joined(separator: " · ")
    }

    private func playbackErrorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(RallyFont.font(size: 16, weight: .semibold))
                .foregroundStyle(.white).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                playerButton("Try Again", primary: true) {
                    Task { await retryPlayback() }
                }
                if !state.candidates.isEmpty {
                    playerButton("Choose Source") { pickerVisible = true }
                }
                playerButton("Back") { store.show(nil) }
            }
        }
        .padding(28)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RallyTheme.glassBorder, lineWidth: 1))
        .padding(60)
    }

    // MARK: Source picker (mirrors AppleTvStreamPicker)

    private var pickerPanel: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    playerButton("‹ Matchup") { pickerVisible = false }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose a broadcast").font(RallyFont.font(size: 24, weight: .bold)).foregroundStyle(.white)
                        Text(event?.rallyMatchup ?? channel?.name ?? "Available video options")
                            .font(RallyFont.font(size: 13)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    }
                }
                .padding(20)
                if state.isLoading && state.candidates.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView("Finding sources…")
                        ForEach(state.trace.suffix(3), id: \.self) { line in
                            Text(line).font(.caption2).foregroundStyle(RallyTheme.textTertiary)
                        }
                    }
                    .padding()
                } else if state.candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No broadcast is available yet").font(RallyFont.font(size: 18, weight: .semibold)).foregroundStyle(.white)
                        Text("Broadcasts can appear closer to game time. Check again later or review Sources in Settings.")
                            .font(.callout).foregroundStyle(RallyTheme.textSecondary)
                        HStack {
                            playerButton("Retry") {
                                Task { await retryPlayback() }
                            }
                            playerButton("Open Settings") { store.show(.settings) }
                        }
                    }
                    .padding(20)
                } else {
                    Text("Available broadcasts")
                        .font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textTertiary)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(state.candidates) { cand in
                                sourceCard(cand)
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 20)
                    }
                }
            }
            .frame(width: 430)
            .background(RallyTheme.background.opacity(0.96))
            .overlay(Rectangle().stroke(RallyTheme.glassBorder, lineWidth: 1).opacity(0.6), alignment: .leading)
        }
    }

    private func sourceCard(_ cand: PlayCandidate) -> some View {
        Button {
            Task {
                await state.switchTo(cand, store: store, drawable: host.surface)
                pickerVisible = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cand.title).font(RallyFont.font(size: 15, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(2)
                    if let addon = cand.addonName {
                        Text(addon).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if cand.exactMatch {
                            Text("Exact matchup").font(RallyFont.font(size: 10, weight: .bold))
                                .foregroundStyle(RallyTheme.textPrimary)
                        }
                        Text(specsLine(cand)).font(RallyFont.font(size: 10, weight: .semibold))
                            .foregroundStyle(RallyTheme.textSecondary)
                        if let note = state.candidateNote[cand.id] {
                            Text(note).font(RallyFont.font(size: 10)).foregroundStyle(RallyTheme.textSecondary)
                        }
                    }
                }
                Spacer()
                if cand.id == state.primary?.id {
                    Image(systemName: "play.fill").foregroundStyle(RallyTheme.textPrimary)
                } else {
                    Text("Play  ›").font(RallyFont.font(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            .background(RallyTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyTheme.glassBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cand.url.isEmpty)
    }

    // MARK: Diagnostics (trace + specs)

    var diagnosticsPanel: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("DIAGNOSTICS").font(RallyFont.font(size: 15, weight: .bold)).tracking(1.4).foregroundStyle(.white)
                    Spacer()
                    Button("Close") { diagVisible = false }.font(.caption)
                }
                if let p = state.primary {
                    diagRow("Source", p.title)
                    diagRow("Delivery", p.kind == .stremio ? "Adaptive web stream" : "TV provider stream")
                    diagRow("Specs", specsLine(p))
                    let h = store.settings.streamHealth(target: p.url)
                    diagRow("Health", "\(healthLabel(h.score)) · \(h.score)")
                    diagRow("Profile", "\(state.profileName) · \(store.settings.lowLatencyMode ? "low-latency" : "standard latency")")
                    diagRow("Recovery", "\(state.recoveryAttempts) retries · \(state.stallCount) stalls")
                    if let reason = state.adaptiveReason {
                        diagRow("Adaptive", reason)
                    }
                    if let evidence = p.matchEvidence, !evidence.isEmpty {
                        diagRow("Match", evidence)
                    }
                    if p.preflightPassed == true, let ms = p.preflightLatencyMs {
                        diagRow("Verified", "\(ms) ms before playback")
                    }
                }
                Divider().opacity(0.3)
                ForEach(state.trace.suffix(8), id: \.self) { line in
                    Text(line).font(RallyFont.font(size: 10).monospaced()).foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                }
                Spacer()
            }
            .padding(20)
            .frame(width: 380)
            .background(RallyTheme.background.opacity(0.96))
            .overlay(Rectangle().stroke(RallyTheme.glassBorder, lineWidth: 1).opacity(0.6), alignment: .leading)
        }
    }

    func diagRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
            Spacer()
            Text(value).font(RallyFont.font(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        }
    }

    func healthLabel(_ score: Int) -> String {
        if score >= 55 { return "Excellent" }
        if score >= 15 { return "Good" }
        if score >= -20 { return "Fair" }
        return "Poor"
    }
}

@MainActor
final class MultiViewState: ObservableObject {
    enum LayoutMode: String, CaseIterable { case grid, focus, single }
    struct Tile: Identifiable {
        var id = UUID().uuidString
        var title: String
        var candidate: PlayCandidate
        var event: SportEvent?
        var audioOn = false
        var status: Status = .loading
        var note: String?
        var useAV = false
        var isStats = false
        enum Status: Equatable { case loading, playing, failed }
    }
    @Published var tiles: [Tile] = []
    @Published var layout: LayoutMode = .grid
    @Published var soloId: String?
    @Published var immersive = false
    @Published var audioFollowsFocus = false
    @Published var gameDetails: [String: EspnClient.GameDetail] = [:]
    @Published var statsLoading = false
    private var hosts: [String: RallyVideoHost] = [:]
    private var startedTiles = Set<String>()
    private var progressByTile: [String: PlaybackProgress] = [:]
    private var sleepActivity: NSObjectProtocol?
    let engine = VlcEngine()
    private var nativePlayers: [String: PlaybackController] = [:]
    private var loadTasks: [String: Task<Void, Never>] = [:]
    func nativePlayer(for tile: Tile) -> PlaybackController {
        if let player = nativePlayers[tile.id] { return player }
        let player = PlaybackController(); nativePlayers[tile.id] = player
        return player
    }

    /// Tile cap follows the device profile (constrained hardware: 2 tiles).
    var canAdd: Bool { tiles.count < maxTiles }
    var maxTiles: Int { PlaybackProfile.resolve().maxTiles }

    func add(candidate: PlayCandidate, event: SportEvent? = nil) {
        guard canAdd, !tiles.contains(where: { $0.candidate.id == candidate.id }), engine.reserve(slotId: candidate.id) else { return }
        var tile = Tile(title: event?.rallyMatchup ?? candidate.title, candidate: candidate, event: event)
        tile.audioOn = tiles.allSatisfy { !$0.audioOn }
        tiles.append(tile)
        applyAudioFocus()
    }

    func addStats() {
        guard canAdd, !tiles.contains(where: \.isStats) else { return }
        var tile = Tile(title: "Player Stats", candidate: PlayCandidate(title: "Player Stats", url: "", kind: .stremio, exactMatch: false, rank: 0), event: nil)
        tile.isStats = true; tile.status = .playing
        tiles.append(tile)
    }
    func host(for tile: Tile) -> RallyVideoHost {
        if let host = hosts[tile.id] { return host }
        let host = RallyVideoHost(); hosts[tile.id] = host; return host
    }
    func ensurePlaying(_ tile: Tile, tuning: PlaybackTuning, store: RallyStore) {
        guard !tile.isStats, !startedTiles.contains(tile.id) else { return }
        startedTiles.insert(tile.id)
        play(tile: tile, tuning: tuning, drawable: host(for: tile).surface, store: store)
    }
    func remove(_ tile: Tile) {
        tiles.removeAll { $0.id == tile.id }
        hosts.removeValue(forKey: tile.id); startedTiles.remove(tile.id); progressByTile.removeValue(forKey: tile.id)
        loadTasks.removeValue(forKey: tile.id)?.cancel()
        nativePlayers.removeValue(forKey: tile.id)?.stop()
        engine.release(slotId: tile.candidate.id)
        if soloId == tile.id { soloId = nil }
        if tile.audioOn, let first = tiles.first(where: { !$0.isStats }) {
            setAudio(tileId: first.id, on: true)
        }
    }

    /// Single-audio-focus: exactly one tile audible (Android single-audio).
    func setAudio(tileId: String, on: Bool) {
        guard tiles.contains(where: { $0.id == tileId && !$0.isStats }) else { return }
        for i in tiles.indices {
            tiles[i].audioOn = tiles[i].id == tileId ? on : false
        }
        applyAudioFocus()
    }

    private func applyAudioFocus() {
        for tile in tiles where !tile.isStats {
            engine.setMuted(slotId: tile.candidate.id, muted: true)
            nativePlayers[tile.id]?.player.isMuted = true
        }
        if let tile = tiles.first(where: { $0.audioOn && !$0.isStats }) {
            engine.setMuted(slotId: tile.candidate.id, muted: false)
            nativePlayers[tile.id]?.player.isMuted = false
        }
    }

    func play(tile: Tile, tuning: PlaybackTuning, drawable: NSView, store: RallyStore) {
        guard !tile.isStats else { return }
        loadTasks[tile.id]?.cancel()
        loadTasks[tile.id] = Task {
        var candidate = tile.candidate
        if let channel = candidate.channel {
            switch store.settings.iptvProvider {
            case .stalker:
                candidate.url = await store.stalkerClient.resolveStreamUrl(channelId: channel.id)
                candidate.headers = ["User-Agent": "Mozilla/5.0 (QtEmbedded; U; Linux; C)", "Cookie": "mac=\(store.settings.macAddress); stb_lang=en; timezone=America/New_York", "Authorization": "Bearer \(store.settings.authToken)"]
            case .xtream: candidate.url = await store.xtreamClient.resolveStreamUrl(channelId: channel.id)
            case .m3u: candidate.headers = channel.streamHeaders
            }
        }
        guard !Task.isCancelled, tiles.contains(where: { $0.id == tile.id }) else { return }
        guard let url = URL(string: candidate.url), url.host != nil else {
            setStatus(id: tile.id, status: .failed, note: "Bad stream URL")
            return
        }
        setStatus(id: tile.id, status: .loading, note: nil)
        do {
            let safeHeaders = StreamRequestHeaders.sanitized(candidate.headers)
            if PlaybackRoute.usesAVPlayer(headers: safeHeaders, url: url) {
                if let i = tiles.firstIndex(where: { $0.id == tile.id }) { tiles[i].useAV = true; tiles[i].candidate = candidate }
                let player = nativePlayer(for: tile)
                player.player.isMuted = true
                player.play(url: url, headers: safeHeaders, lowLatency: store.settings.lowLatencyMode)
                player.setQuality(PlaybackQuality(height: 720, bitrate: 0))
                let ready = await player.waitUntilReady()
                guard !Task.isCancelled else { return }
                if ready { setStatus(id: tile.id, status: .playing, note: nil); applyAudioFocus(); return }
                player.stop()
            }
            if let i = tiles.firstIndex(where: { $0.id == tile.id }) { tiles[i].useAV = false; tiles[i].candidate = candidate }
            let playable = try await engine.prepareURL(slotId: tile.candidate.id, url: url, headers: safeHeaders)
            guard !Task.isCancelled else { return }
            try engine.play(slotId: tile.candidate.id, title: tile.title, url: playable,
                            headers: safeHeaders.isEmpty ? nil : safeHeaders,
                            tuning: tuning, drawable: drawable, maxHeight: 720)
            engine.setMuted(slotId: tile.candidate.id, muted: true)
            let deadline = Date().addingTimeInterval(12)
            while (!engine.isPlaying(slotId: tile.candidate.id) || engine.isBuffering(slotId: tile.candidate.id)) && !engine.hasError(slotId: tile.candidate.id) && Date() < deadline && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            setStatus(id: tile.id, status: engine.isPlaying(slotId: tile.candidate.id) ? .playing : .failed,
                      note: engine.isPlaying(slotId: tile.candidate.id) ? nil : "The source did not start playback.")
            applyAudioFocus()
        } catch {
            setStatus(id: tile.id, status: .failed, note: "Failed: \(error.localizedDescription)")
        }
        }
    }

    func retry(tile: Tile, tuning: PlaybackTuning, drawable: NSView, store: RallyStore) {
        progressByTile[tile.id] = PlaybackProgress()
        play(tile: tile, tuning: tuning, drawable: drawable, store: store)
    }

    func checkProgress(tuning: PlaybackTuning, store: RallyStore) {
        let broadcasts = tiles.filter { !$0.isStats && $0.status == .playing }
        if !broadcasts.isEmpty && sleepActivity == nil { sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Watching Rally Multi-View") }
        if broadcasts.isEmpty, let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
        for tile in broadcasts {
            let native = nativePlayers[tile.id]
            if tile.useAV && native?.ended == true { continue }
            let seconds = tile.useAV ? native?.player.currentTime().seconds : engine.elapsedSeconds(slotId: tile.candidate.id)
            let paused = tile.useAV && native?.player.timeControlStatus == .paused && native?.error == nil
            var progress = progressByTile[tile.id] ?? PlaybackProgress()
            let failed = tile.useAV ? native?.error != nil : engine.hasError(slotId: tile.candidate.id)
            if failed || progress.stalled(position: seconds, paused: paused) {
                if progress.consumeReconnect() {
                    progress.reset(keepBudget: true)
                    play(tile: tile, tuning: tuning, drawable: host(for: tile).surface, store: store)
                } else { setStatus(id: tile.id, status: .failed, note: "This broadcast stopped. Retry or choose another source.") }
            }
            progressByTile[tile.id] = progress
        }
    }

    private func setStatus(id: String, status: Tile.Status, note: String?) {
        guard let i = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[i].status = status
        tiles[i].note = note
    }

    #if DEBUG
    var auditStatus: String {
        "layout=\(layout) immersive=\(immersive) tiles=\(tiles.count) audioFollow=\(audioFollowsFocus) games=\(gameDetails.count)\n" + tiles.map { tile in
            let clock = nativePlayers[tile.id]?.player.currentTime().seconds ?? engine.elapsedSeconds(slotId: tile.candidate.id) ?? -1
            let muted = tile.useAV ? nativePlayers[tile.id]?.player.isMuted ?? true : engine.isMuted(slotId: tile.candidate.id)
            return "\(tile.title) stats=\(tile.isStats) status=\(tile.status) audio=\(tile.audioOn) muted=\(muted) clock=\(clock)"
        }.joined(separator: "\n")
    }
    #endif

    func teardown() {
        loadTasks.values.forEach { $0.cancel() }; loadTasks = [:]
        nativePlayers.values.forEach { $0.stop() }; nativePlayers = [:]
        engine.releaseAll()
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
        progressByTile = [:]
        tiles.removeAll()
        soloId = nil
        layout = .grid; immersive = false; hosts = [:]; startedTiles = []; gameDetails = [:]
    }
}

struct MultiViewView: View {
    @EnvironmentObject var store: RallyStore
    @ObservedObject var state: MultiViewState
    @State private var choosingSource = false
    @FocusState private var focusedTile: String?
    private var statsEvents: [SportEvent] {
        MultiViewGames.statsEvents(selected: state.tiles.compactMap(\.event), titles: state.tiles.map(\.title), schedule: store.scheduleEvents + store.events)
    }
    private func tuning() -> PlaybackTuning {
        let profile = PlaybackProfile.resolve(lowLatency: store.settings.lowLatencyMode)
        return PlaybackTuning(lowLatency: store.settings.lowLatencyMode, audioNormalization: store.settings.audioNormalizationEnabled, networkCachingMs: profile.networkCachingMs)
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black
                VStack(spacing: state.immersive ? 0 : 12) {
                    if !state.immersive { toolbar }
                    if state.tiles.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "rectangle.split.2x2").font(.largeTitle)
                            Text("Watch up to \(state.maxTiles) broadcasts together.").font(RallyFont.font(size: 18))
                            Button("Choose Sources") { choosingSource = true }.buttonStyle(RallyActionStyle(primary: true))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { grid in
                            let frames = MultiViewGeometry.frames(count: state.tiles.count, width: grid.size.width, height: grid.size.height, immersive: state.immersive, focus: state.layout == .focus)
                            ZStack(alignment: .topLeading) {
                                ForEach(Array(state.tiles.enumerated()), id: \.element.id) { index, tile in
                                    let frame = frames[index]
                                    let solo = state.layout == .single && state.soloId == tile.id
                                    tileCard(tile).frame(width: solo ? grid.size.width : frame.width, height: solo ? grid.size.height : frame.height)
                                        .offset(x: solo ? 0 : frame.minX, y: solo ? 0 : frame.minY)
                                        .opacity(state.layout == .single && !solo ? 0 : 1)
                                        .allowsHitTesting(state.layout != .single || solo)
                                        .zIndex(solo ? 1 : 0)
                                }
                            }.frame(width: grid.size.width, height: grid.size.height, alignment: .topLeading).clipped()
                        }
                    }
                }.padding(state.immersive ? 0 : 20)
                if state.immersive {
                    HStack { Text("MULTIVIEW").font(RallyFont.font(size: 11, weight: .semibold)).tracking(1.4); Spacer(); Button("Exit Immersive") { state.immersive = false }.buttonStyle(RallyActionStyle()) }.padding(16).background(.black.opacity(0.5))
                }
            }.foregroundStyle(.white)
        }.sheet(isPresented: $choosingSource) { MultiViewSourcePicker(state: state).environmentObject(store) }
            .background { RallyEscapeHandler { if state.immersive { state.immersive = false } else { store.show(nil) } }.frame(width: 0, height: 0) }
            .onChange(of: focusedTile) { id in if state.audioFollowsFocus, let id { state.setAudio(tileId: id, on: true) } }
            .task(id: statsEvents.map(\.id).joined(separator: ",") + String(state.tiles.contains(where: \.isStats))) {
                guard state.tiles.contains(where: \.isStats) else { return }
                if state.tiles.contains(where: { $0.title.range(of: #"red\s*zone"#, options: .regularExpression.union(.caseInsensitive)) != nil }) { await store.refreshSchedule() }
                while !Task.isCancelled {
                    state.statsLoading = true
                    for event in statsEvents {
                        guard let path = EspnClient.path(forLeague: event.league) else { continue }
                        let detail = await store.espnClient.fetchSummary(sport: path.sport, league: path.path, eventId: event.id, awayAbbr: event.awayTeam?.abbreviation, homeAbbr: event.homeTeam?.abbreviation)
                        guard !Task.isCancelled else { return }
                        if detail.isAvailable { state.gameDetails[event.id] = detail }
                    }
                    state.statsLoading = false
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                }
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    state.checkProgress(tuning: tuning(), store: store)
                }
            }
            .onDisappear { state.teardown() }
    }
    private var toolbar: some View {
        HStack(spacing: 14) {
            if let image = tvArt("rally_mark_ui") { Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28) }
            Text("Multi-View").font(RallyFont.font(size: 20, weight: .semibold))
            Spacer()
            Menu {
                Button("Grid") { state.layout = .grid; state.soloId = nil }
                Button("Focus") { state.layout = .focus; state.soloId = nil }
                Toggle("Audio Follows Focus", isOn: $state.audioFollowsFocus)
            } label: { Label("Layout", systemImage: "rectangle.split.2x2") }.fixedSize()
            Button("Add Broadcast") { choosingSource = true }.disabled(!state.canAdd)
            Button("Add Stats") { state.addStats() }.disabled(!state.canAdd || state.tiles.contains(where: \.isStats))
            Button("Immersive") { state.immersive = true }
            Button { store.show(nil) } label: { Image(systemName: "xmark") }.help("Close Multi-View")
        }.font(RallyFont.font(size: 12)).buttonStyle(.plain).menuStyle(.borderlessButton)
    }
    private func tileCard(_ tile: MultiViewState.Tile) -> some View {
        ZStack(alignment: .bottom) {
            if tile.isStats { statsCard }
            else {
                ZStack {
                    VideoHost(host: state.host(for: tile)).opacity(tile.useAV ? 0 : 1)
                    NativePlayerView(controller: state.nativePlayer(for: tile), showsControls: false).opacity(tile.useAV ? 1 : 0).allowsHitTesting(false)
                    if tile.status == .loading { ProgressView("Connecting…").padding(12).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)) }
                    if tile.status == .failed { VStack(spacing: 8) { Text(tile.note ?? "Playback failed").font(RallyFont.font(size: 12)); Button("Retry") { state.retry(tile: tile, tuning: tuning(), drawable: state.host(for: tile).surface, store: store) } }.padding(16) }
                }.aspectRatio(16.0 / 9.0, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    .task { state.ensurePlaying(tile, tuning: tuning(), store: store) }
            }
            HStack(spacing: 10) {
                if !tile.isStats {
                    Button { state.setAudio(tileId: tile.id, on: !tile.audioOn) } label: { Image(systemName: tile.audioOn ? "speaker.wave.2.fill" : "speaker.slash") }.help("Listen to this broadcast")
                    Text(tile.title).lineLimit(1)
                } else { Text("PLAYER STATS").tracking(1) }
                Spacer()
                Button(state.soloId == tile.id ? "Grid" : "Solo") { if state.soloId == tile.id { state.soloId = nil; state.layout = .grid } else { state.soloId = tile.id; state.layout = .single } }
                if !tile.isStats { Button("Open") { store.show(.player(event: tile.event, channel: tile.candidate.channel, source: tile.candidate)) } }
                Button { state.remove(tile) } label: { Image(systemName: "xmark") }.help("Remove tile")
            }.font(RallyFont.font(size: 11)).buttonStyle(.plain).padding(10).background(.black.opacity(0.6))
        }.clipShape(RoundedRectangle(cornerRadius: state.immersive ? 0 : 8))
            .overlay(RoundedRectangle(cornerRadius: state.immersive ? 0 : 8).stroke(tile.audioOn && !state.immersive ? .white.opacity(0.55) : .clear, lineWidth: 1))
            .focusable().focused($focusedTile, equals: tile.id)
    }
    private var statsCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if state.statsLoading && state.gameDetails.isEmpty { ProgressView("Loading player stats…") }
                if statsEvents.isEmpty { Text("Add a game broadcast to see its players. RedZone includes today’s daytime NFL games.").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary) }
                ForEach(statsEvents) { event in
                    HStack(spacing: 8) { RallyTeamLogo(team: event.awayTeam, size: 24); Text(event.rallyMatchup).font(RallyFont.font(size: 14, weight: .semibold)); RallyTeamLogo(team: event.homeTeam, size: 24) }
                    if let detail = state.gameDetails[event.id] { RallyPlayersPanel(tables: detail.playerTables, compact: true) }
                    else { Text("No player statistics published yet.").font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary) }
                    Divider().opacity(0.2)
                }
            }.padding(16).padding(.bottom, 40)
        }.background(RallyTheme.background)
    }
}
