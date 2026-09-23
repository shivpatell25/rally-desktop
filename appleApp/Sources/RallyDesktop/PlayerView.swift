import AppKit
import RallyCore
import SwiftUI
import VLCKit

/// Hosts a libVLC drawable. The engine starts playback once the view exists.
struct VLCVideoView: NSViewRepresentable {
    var onReady: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        DispatchQueue.main.async { onReady(view) }
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
    /// Dedicated clip player: highlights play on their own engine slot so the
    /// live session underneath is never torn down (Android CurrentHighlightsChrome).
    @Published var clipOverlay: HighlightClip?
    let clipEngine = VlcEngine()
    let clipHost = NSView()
    private let clipSlotId = UUID().uuidString
    let engine = VlcEngine()
    private let slotId = UUID().uuidString
    private var startedAt = Date()
    /// Candidates that already failed this session (Android blacklist).
    private var failedTargets: Set<String> = []

    private func log(_ line: String) {
        let stamped = "[Player] \(line)"
        trace.append(stamped)
        if trace.count > 30 { trace.removeFirst(trace.count - 30) }
        NSLog("%@", stamped)
    }

    func load(event: SportEvent?, channel: IptvChannel?, store: RallyStore, drawable: NSView) async {
        isLoading = true
        error = nil
        candidateNote = [:]
        failedTargets.removeAll()
        recoveryAttempts = 0
        stallCount = 0
        adaptiveReason = nil
        var cands: [PlayCandidate] = []
        if let event {
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
            cands = StreamResolver.candidates(event: event, channels: store.channels, stremioOptions: options)
        } else if let channel {
            log("direct channel=\(channel.id)")
            cands = StreamResolver.channelCandidates([channel])
        }
        candidates = cands
        log("candidates=\(cands.count) stremio=\(cands.filter { $0.kind == .stremio }.count) iptv=\(cands.filter { $0.kind == .iptv }.count)")
        await preflightTopCandidates(store: store)
        if let event, let path = EspnClient.path(forLeague: event.league) {
            detailLoading = true
            Task {
                let detail = await store.espnClient.fetchSummary(sport: path.sport, league: path.path, eventId: event.id, awayAbbr: event.awayTeam?.abbreviation, homeAbbr: event.homeTeam?.abbreviation)
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
        error = nil
        _ = await attempt(candidate, store: store, drawable: drawable)
    }

    /// Plays an ESPN highlight clip as a one-off Stremio-kind candidate.
    func playClip(_ clip: HighlightClip, store: RallyStore, drawable: NSView) async {
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
        _ = clipEngine.reserve(slotId: clipSlotId)
        do {
            clipEngine.stop(slotId: clipSlotId)
            try clipEngine.play(slotId: clipSlotId, title: clip.title, url: url, drawable: clipHost)
            clipOverlay = clip
            log("clip overlay playing \(clip.title)")
        } catch {
            candidateNote[clip.id] = "Clip failed: \(error.localizedDescription)"
            log("clip overlay failed: \(error.localizedDescription)")
        }
    }

    func closeClipOverlay() {
        clipEngine.stop(slotId: clipSlotId)
        clipOverlay = nil
    }

    /// Restart replays the current source from scratch.
    func restart(store: RallyStore, drawable: NSView) async {
        guard let p = primary else {
            await retry(store: store, drawable: drawable)
            return
        }
        error = nil
        candidateNote[p.id] = nil
        log("restarting \(p.title)")
        await play(p, store: store, drawable: drawable)
    }

    /// Retry walks every candidate in rank order until one plays (v1 fallback chain).
    func retry(store: RallyStore, drawable: NSView) async {
        error = nil
        for cand in candidates {
            if candidateNote[cand.id] == nil || cand.id == primary?.id {
                await play(cand, store: store, drawable: drawable)
                if isPlaying { return }
            }
        }
        if !isPlaying, error == nil { error = "All sources failed" }
        log("retry done playing=\(isPlaying)")
    }

    /// Autoplay entry with bounded auto-recovery (Android
    /// `recoverFromPlaybackFailure`): blacklist failures, try at most 3
    /// candidates, terminal error only after exhausting them.
    private func play(_ candidate: PlayCandidate, store: RallyStore, drawable: NSView) async {
        error = nil
        recoveryAttempts = 0
        var next: PlayCandidate? = candidate
        var attempts = 0
        while let cand = next, attempts < 3 {
            attempts += 1
            if await attempt(cand, store: store, drawable: drawable) { return }
            recoveryAttempts += 1
            next = StreamResolver.sort(candidates.filter {
                !failedTargets.contains($0.id) && $0.id != cand.id
            }) { store.settings.streamHealth(target: $0).score }.first
        }
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
        error = nil
        candidateNote[candidate.id] = "Resolving…"
        var urlString = candidate.url
        // Resolve provider-issued URLs (Stalker cmd / bare xtream ids).
        if candidate.kind == .iptv, let ch = candidate.channel {
            if store.settings.iptvProvider == .stalker {
                urlString = await store.stalkerClient.resolveStreamUrl(channelId: ch.id)
            } else {
                urlString = await store.xtreamClient.resolveStreamUrl(channelId: ch.id)
            }
            if urlString != ch.id, urlString != ch.streamUrl {
                if let i = candidates.firstIndex(where: { $0.id == candidate.id }) {
                    candidates[i].url = urlString
                }
            }
        }
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
        do {
            _ = engine.reserve(slotId: slotId)
            let safeHeaders = StreamRequestHeaders.sanitized(candidate.headers ?? channelHeaders(store, candidate))
            let (_, tuning) = tuning(for: store)
            try engine.play(slotId: slotId, title: candidate.title, url: url,
                            headers: safeHeaders.isEmpty ? nil : safeHeaders,
                            tuning: tuning, drawable: drawable)
            primary = candidate
            isPlaying = true
            stallCount = 0
            candidateNote[candidate.id] = "Playing"
            let ms = Int64(Date().timeIntervalSince(startedAt) * 1000)
            store.settings.recordStreamSuccess(target: candidate.url, startupMs: ms)
            log("playing startupMs=\(ms) profile=\(profileName) norm=\(store.settings.audioNormalizationEnabled)")
            return true
        } catch {
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
        guard isPlaying, !paused else { return }
        guard !engine.isPlaying(slotId: slotId) else { stallCount = 0; return }
        stallCount += 1
        if let p = primary { store.settings.recordStreamStall(target: p.url) }
        log("stall #\(stallCount)")
        guard store.settings.adaptiveQualityEnabled, let p = primary else { return }
        if let (next, reason) = AdaptivePolicy.fallback(afterStalls: stallCount, candidates: candidates,
                                                        currentId: p.id, failedIds: failedTargets) {
            adaptiveReason = reason
            stallCount = 0
            log(reason)
            await play(next, store: store, drawable: drawable)
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
        if paused {
            engine.resume(slotId: slotId)
            paused = false
        } else {
            engine.pause(slotId: slotId)
            paused = true
        }
        log(paused ? "paused" : "resumed")
    }

    func teardown() {
        engine.release(slotId: slotId)
        clipEngine.stop(slotId: clipSlotId)
        clipEngine.release(slotId: clipSlotId)
        clipOverlay = nil
        isPlaying = false
        paused = false
    }

    func toggleMute() {
        engine.setMuted(slotId: slotId, muted: !muted)
        muted = engine.isMuted(slotId: slotId)
        log(muted ? "muted" : "unmuted")
    }

    func refreshStats() {
        if let pos = engine.position(slotId: slotId) {
            positionFraction = pos.fraction
            positionText = pos.clock
        }
        paused = !engine.isPlaying(slotId: slotId) && isPlaying
    }
}

struct PlayerView: View {
    @EnvironmentObject var store: RallyStore
    @StateObject var state = PlayerState()
    @State var host = NSView()
    @State private var started = false
    @State var controlsVisible = true
    @State var pickerVisible = false
    @State var gameMode = false
    @State var topTab = 0
    @State var infoTab = 0
    @FocusState var liveFocus: String?
    @State var diagVisible = false
    @State private var lastMove = Date()
    let event: SportEvent?
    let channel: IptvChannel?
    var clip: HighlightClip?
    var startWithPicker = false
    var body: some View {
        Group {
            if gameMode {
                gameViewLayout
            } else {
                watchLayout
            }
        }
        .onAppear { if LaunchArgs.gameMode { gameMode = true } }
        .background(Color.black)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                state.refreshStats()
                await state.watchdog(store: store, drawable: host)
            }
        }
        .onAppear {
            host.wantsLayer = true
            if !started {
                started = true
                Task {
                    await state.load(event: event, channel: channel, store: store, drawable: host)
                    if let clip, clip.streamUrl != nil {
                        await state.playClip(clip, store: store, drawable: host)
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
        }
        .onHover { hovering in
            controlsVisible = hovering || pickerVisible || diagVisible
        }
    }

    private var watchLayout: some View {
        ZStack {
            VideoHost(host: host)
            .background(Color.black)
            // Top + bottom scrims (mirrors PlaybackHud gradients).
            if controlsVisible || pickerVisible || diagVisible {
                VStack {
                    LinearGradient(colors: [Color.black.opacity(0.65), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                    Spacer()
                    LinearGradient(colors: [.clear, Color.black.opacity(0.9)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 220)
                }
                .allowsHitTesting(false)
            }
            VStack {
                if controlsVisible { hudTop }
                Spacer()
                if controlsVisible { hudBottom }
            }
            if pickerVisible { pickerPanel }
            if diagVisible { diagnosticsPanel }
            if let err = state.error, state.primary == nil, !state.isLoading {
                playbackErrorOverlay(err)
            }
        }
    }

    // MARK: HUD top (mirrors PlaybackHud header)

    var hudTop: some View {
        HStack {
            playerButton("‹ Back") { store.show(nil) }
            Spacer()
            if let mark = tvArt("rally_mark_ui") {
                Image(nsImage: mark).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
            }
            Text(channel?.name ?? event?.name ?? "Live Sports")
                .font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
    }

    // MARK: HUD bottom (mirrors PlaybackHud footer)

    var hudBottom: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let event {
                HStack(spacing: 7) {
                    if event.status == .live || event.status == .halftime {
                        Circle().fill(RallyTheme.liveRed).frame(width: 8, height: 8)
                        Text("LIVE").font(.system(size: 12, weight: .bold)).tracking(0.8)
                            .foregroundStyle(.white)
                        Text(event.gameStatusDetail ?? event.league)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RallyTheme.textSecondary)
                    } else {
                        Text(event.gameStatusDetail ?? Artwork.displayLeague(event.league))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RallyTheme.textSecondary)
                    }
                }
                if event.homeTeam != nil {
                    Text(scoreLine(event)).font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white).lineLimit(1)
                }
                Text([event.league, event.venue].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
            } else {
                Text(channel?.name ?? "Live stream").font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white).lineLimit(1)
                Text(channel?.category ?? "Live TV").font(.system(size: 13))
                    .foregroundStyle(RallyTheme.textSecondary)
            }
            HStack(spacing: 10) {
                if event != nil {
                    playerButton("Game View", primary: true) { gameMode = true }
                }
                playerButton("Fullscreen") { toggleFullscreen() }
                Button(state.paused ? "▶" : "❚❚") { state.togglePause() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RallyTheme.textPrimary)
                    .disabled(!state.isPlaying)
                    .keyboardShortcut(.space, modifiers: [])
                playerButton("Restart") {
                    Task { await state.restart(store: store, drawable: host) }
                }
                playerButton("Sources") { pickerVisible = true }
                playerButton("Diagnostics") { diagVisible.toggle() }
                playerButton("Multi-View (\(store.multiView.tiles.count))") { store.show(.multiView) }
                if let p = state.primary {
                    Text(specsLine(p)).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RallyTheme.textSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
                }
                Spacer()
                Text(state.positionText).font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(RallyTheme.textSecondary)
            }
        }
        .padding(.horizontal, 30).padding(.bottom, 27)
    }

    func playerButton(_ label: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary ? Color.black : RallyTheme.textPrimary)
                .padding(.horizontal, 20).padding(.vertical, 10)
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
            Text(message).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                playerButton("Try Again", primary: true) {
                    Task { await state.retry(store: store, drawable: host) }
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
                        Text("Choose a broadcast").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        Text(event?.name ?? channel?.name ?? "Available video options")
                            .font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
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
                        Text("No broadcast is available yet").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        Text("Broadcasts can appear closer to game time. Check again later or review Sources in Settings.")
                            .font(.callout).foregroundStyle(RallyTheme.textSecondary)
                        HStack {
                            playerButton("Retry") {
                                Task { await state.retry(store: store, drawable: host) }
                            }
                            playerButton("Open Settings") { store.show(.settings) }
                        }
                    }
                    .padding(20)
                } else {
                    Text("Recommended broadcasts · Verified for this matchup")
                        .font(.system(size: 12)).foregroundStyle(RallyTheme.textTertiary)
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
                await state.switchTo(cand, store: store, drawable: host)
                pickerVisible = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cand.title).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(2)
                    if let addon = cand.addonName {
                        Text(addon).font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if cand.exactMatch {
                            Text("Exact matchup").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(RallyTheme.rallyLime)
                        }
                        Text(specsLine(cand)).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RallyTheme.textSecondary)
                        if let note = state.candidateNote[cand.id] {
                            Text(note).font(.system(size: 10)).foregroundStyle(RallyTheme.textSecondary)
                        }
                    }
                }
                Spacer()
                Button("+ Tile") { store.multiView.add(candidate: cand) }
                    .font(.caption)
                    .disabled(!store.multiView.canAdd)
                if cand.id == state.primary?.id {
                    Image(systemName: "play.fill").foregroundStyle(RallyTheme.rallyCyan)
                } else {
                    Text("Play  ›").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            .background(LinearGradient(colors: [Color(red: 34/255, green: 51/255, blue: 73/255, opacity: 0.72),
                                                Color(red: 14/255, green: 25/255, blue: 39/255, opacity: 0.64)],
                                       startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyTheme.glassBorder, lineWidth: 1))
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
                    Text("DIAGNOSTICS").font(.system(size: 15, weight: .bold)).tracking(1.4).foregroundStyle(.white)
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
                    Text(line).font(.system(size: 10).monospaced()).foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
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
            Text(label).font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
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
        var audioOn = false
        var status: Status = .loading
        var note: String?
        enum Status: Equatable { case loading, playing, failed }
    }
    @Published var tiles: [Tile] = []
    @Published var layout: LayoutMode = .grid
    @Published var soloId: String?
    let engine = VlcEngine()

    /// Tile cap follows the device profile (constrained hardware: 2 tiles).
    var canAdd: Bool { tiles.count < PlaybackProfile.resolve().maxTiles }
    var maxTiles: Int { PlaybackProfile.resolve().maxTiles }

    func add(candidate: PlayCandidate) {
        guard canAdd, engine.reserve(slotId: candidate.id) else { return }
        var tile = Tile(title: candidate.title, candidate: candidate)
        tile.audioOn = tiles.allSatisfy { !$0.audioOn }
        tiles.append(tile)
        applyAudioFocus()
    }

    func remove(_ tile: Tile) {
        tiles.removeAll { $0.id == tile.id }
        engine.release(slotId: tile.candidate.id)
        if soloId == tile.id { soloId = nil }
        if tile.audioOn, let first = tiles.first {
            setAudio(tileId: first.id, on: true)
        }
    }

    /// Single-audio-focus: exactly one tile audible (Android single-audio).
    func setAudio(tileId: String, on: Bool) {
        for i in tiles.indices {
            tiles[i].audioOn = tiles[i].id == tileId ? on : false
        }
        applyAudioFocus()
    }

    private func applyAudioFocus() {
        for tile in tiles {
            engine.setMuted(slotId: tile.candidate.id, muted: !tile.audioOn)
        }
    }

    func play(tile: Tile, tuning: PlaybackTuning, drawable: NSView) {
        guard let url = URL(string: tile.candidate.url) else {
            setStatus(id: tile.id, status: .failed, note: "Bad stream URL")
            return
        }
        setStatus(id: tile.id, status: .loading, note: nil)
        do {
            let safeHeaders = StreamRequestHeaders.sanitized(tile.candidate.headers)
            try engine.play(slotId: tile.candidate.id, title: tile.title, url: url,
                            headers: safeHeaders.isEmpty ? nil : safeHeaders,
                            tuning: tuning, drawable: drawable)
            setStatus(id: tile.id, status: .playing, note: nil)
            applyAudioFocus()
        } catch {
            setStatus(id: tile.id, status: .failed, note: "Failed: \(error.localizedDescription)")
        }
    }

    func retry(tile: Tile, tuning: PlaybackTuning, drawable: NSView) {
        play(tile: tile, tuning: tuning, drawable: drawable)
    }

    private func setStatus(id: String, status: Tile.Status, note: String?) {
        guard let i = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[i].status = status
        tiles[i].note = note
    }

    func teardown() {
        engine.releaseAll()
        tiles.removeAll()
        soloId = nil
        layout = .grid
    }
}

struct MultiViewView: View {
    @EnvironmentObject var store: RallyStore
    @ObservedObject var state: MultiViewState
    @State private var reloadTick = 0
    private func tuning() -> PlaybackTuning {
        let profile = PlaybackProfile.resolve(lowLatency: store.settings.lowLatencyMode)
        return PlaybackTuning(lowLatency: store.settings.lowLatencyMode,
                              audioNormalization: store.settings.audioNormalizationEnabled,
                              networkCachingMs: profile.networkCachingMs)
    }
    private var visibleTiles: [MultiViewState.Tile] {
        if state.layout == .single, let id = state.soloId {
            return state.tiles.filter { $0.id == id }
        }
        return state.tiles
    }
    var body: some View {
        VStack(spacing: 8) {
            if state.tiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x2").font(.largeTitle)
                    Text("Multi-View").font(.headline)
                    Text("Open an event and add its sources as tiles (max \(state.maxTiles)).")
                        .font(.caption).foregroundStyle(RallyTheme.textTertiary)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Multi-View (\(state.tiles.count)/\(state.maxTiles))").font(.headline)
                    Spacer()
                    Picker("Layout", selection: $state.layout) {
                        Text("Grid").tag(MultiViewState.LayoutMode.grid)
                        Text("Focus").tag(MultiViewState.LayoutMode.focus)
                        Text("Single").tag(MultiViewState.LayoutMode.single)
                    }
                    .frame(maxWidth: 220)
                    .onChange(of: state.layout) { _ in
                        if state.layout != .single { state.soloId = nil }
                        else if state.soloId == nil { state.soloId = state.tiles.first?.id }
                    }
                }
                .padding(.horizontal, 8)
                if state.layout == .focus, let first = state.tiles.first {
                    tileCard(first, large: true)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(state.tiles.dropFirst()) { tile in tileCard(tile, large: false) }
                    }
                    .padding(.horizontal, 8)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                            count: visibleTiles.count > 1 && state.layout == .grid ? 2 : 1), spacing: 8) {
                        ForEach(visibleTiles) { tile in tileCard(tile, large: state.layout != .grid) }
                    }
                    .padding(8)
                }
            }
        }
        .background(RallyTheme.background)
        .navigationTitle("Multi-View")
        .onDisappear { state.teardown() }
    }

    private func tileCard(_ tile: MultiViewState.Tile, large: Bool) -> some View {
        VStack(spacing: 4) {
            VLCVideoView { [tile] view in state.play(tile: tile, tuning: tuning(), drawable: view) }
                .frame(minHeight: large ? 320 : 200)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: RallyTheme.cardCorner))
                .id("\(tile.id)-\(reloadTick)")
            HStack(spacing: 8) {
                Button { state.setAudio(tileId: tile.id, on: !tile.audioOn) } label: {
                    Text(tile.audioOn ? "🔊" : "🔇").font(.caption)
                }.buttonStyle(.plain)
                Text(tile.title).font(.caption).lineLimit(1)
                if tile.status == .failed, let note = tile.note {
                    Text(note).font(.caption2).foregroundStyle(RallyTheme.liveRed).lineLimit(1)
                }
                Spacer()
                if tile.status == .failed {
                    Button("Retry") {
                        reloadTick += 1
                    }.font(.caption).buttonStyle(.plain)
                }
                Button(state.soloId == tile.id ? "Unfocus" : "Solo") {
                    if state.soloId == tile.id { state.soloId = nil; state.layout = .grid }
                    else { state.soloId = tile.id; state.layout = .single }
                }.font(.caption).buttonStyle(.plain)
                Button("Remove") { state.remove(tile) }.font(.caption)
            }
        }
    }
}
