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
    @Published var positionText = "0:00:00"
    @Published var positionFraction: Double = 0
    @Published var showDiagnostics = false
    let engine = VlcEngine()
    private let slotId = UUID().uuidString
    private var startedAt = Date()

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
        defer { isLoading = false }
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
        guard let first = cands.first else {
            error = "No playable sources found"
            log("empty: check addon URLs and IPTV provider in Settings")
            return
        }
        await play(first, store: store, drawable: drawable)
    }

    func switchTo(_ candidate: PlayCandidate, store: RallyStore, drawable: NSView) async {
        await play(candidate, store: store, drawable: drawable)
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

    private func play(_ candidate: PlayCandidate, store: RallyStore, drawable: NSView) async {
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
            log("bad url kind=\(candidate.kind)")
            return
        }
        log("try kind=\(candidate.kind) host=\(host) exact=\(candidate.exactMatch)")
        startedAt = Date()
        do {
            _ = engine.reserve(slotId: slotId)
            try engine.play(slotId: slotId, title: candidate.title, url: url,
                            headers: candidate.headers ?? channelHeaders(store, candidate), drawable: drawable)
            primary = candidate
            isPlaying = true
            candidateNote[candidate.id] = "Playing"
            let ms = Int64(Date().timeIntervalSince(startedAt) * 1000)
            store.settings.recordStreamSuccess(target: candidate.url, startupMs: ms)
            log("playing startupMs=\(ms)")
        } catch {
            candidateNote[candidate.id] = "Failed: \(error.localizedDescription)"
            self.error = "Playback failed: \(error.localizedDescription)"
            store.settings.recordStreamFailure(target: candidate.url)
            log("failed: \(error.localizedDescription)")
        }
    }

    private func channelHeaders(_ store: RallyStore, _ candidate: PlayCandidate) -> [String: String]? {
        guard candidate.kind == .iptv else { return nil }
        if store.settings.iptvProvider == .stalker {
            let mac = store.settings.macAddress
            return ["User-Agent": "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"]
                .merging(mac.isEmpty ? [:] : ["Cookie": "mac=\(mac); stb_lang=en; timezone=GMT"]) { a, _ in a }
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

    func refreshStats() {
        if let pos = engine.position(slotId: slotId) {
            positionFraction = pos.fraction
            positionText = pos.clock
        }
        paused = !engine.isPlaying(slotId: slotId) && isPlaying
    }

    func teardown() {
        engine.release(slotId: slotId)
        isPlaying = false
        paused = false
    }
}

struct PlayerView: View {
    @EnvironmentObject var store: RallyStore
    @StateObject private var state = PlayerState()
    @State private var drawable: NSView?
    @State private var started = false
    @State private var controlsVisible = true
    @State private var pickerVisible = false
    @State private var gameViewVisible = false
    @State private var diagVisible = false
    @State private var lastMove = Date()
    @State private var mouseMonitor: Any?
    let event: SportEvent?
    let channel: IptvChannel?

    var body: some View {
        ZStack {
            VLCVideoView { view in
                drawable = view
                if !started {
                    started = true
                    Task { await state.load(event: event, channel: channel, store: store, drawable: view) }
                }
            }
            .background(Color.black)
            .onTapGesture {
                guard !pickerVisible && !gameViewVisible && !diagVisible else { return }
                controlsVisible.toggle()
                lastMove = Date()
            }
            // Top + bottom scrims (mirrors PlaybackHud gradients).
            if controlsVisible || pickerVisible || gameViewVisible || diagVisible {
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
            if gameViewVisible { gameViewPanel }
            if diagVisible { diagnosticsPanel }
            if let err = state.error, state.primary == nil, !state.isLoading {
                playbackErrorOverlay(err)
            }
        }
        .background(Color.black)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                state.refreshStats()
                if state.isPlaying && !state.paused && !pickerVisible && !gameViewVisible && !diagVisible
                    && Date().timeIntervalSince(lastMove) > 6.5 {
                    controlsVisible = false
                }
            }
        }
        .onAppear {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { ev in
                lastMove = Date()
                if state.isPlaying && !pickerVisible && !gameViewVisible && !diagVisible {
                    controlsVisible = true
                }
                return ev
            }
        }
        .onDisappear {
            if let m = mouseMonitor { NSEvent.removeMonitor(m) }
            state.teardown()
        }
    }

    // MARK: HUD top (mirrors PlaybackHud header)

    private var hudTop: some View {
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

    private var hudBottom: some View {
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
                Button(state.paused ? "▶" : "❚❚") { state.togglePause(); lastMove = Date() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RallyTheme.textPrimary)
                    .disabled(!state.isPlaying)
                    .keyboardShortcut(.space, modifiers: [])
                if event != nil {
                    playerButton("Game View", primary: true) { gameViewVisible.toggle(); lastMove = Date() }
                }
                playerButton("Sources") { pickerVisible = true; lastMove = Date() }
                playerButton("Diagnostics") { diagVisible.toggle(); lastMove = Date() }
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

    private func playerButton(_ label: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
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

    private func scoreLine(_ event: SportEvent) -> String {
        let away = event.awayTeam?.abbreviation ?? event.awayTeam?.name ?? "AWY"
        let home = event.homeTeam?.abbreviation ?? event.homeTeam?.name ?? "HME"
        if let a = event.scoreAway, let h = event.scoreHome { return "\(away) \(a)  ·  \(home) \(h)" }
        return "\(away) at \(home)"
    }

    private func specsLine(_ p: PlayCandidate) -> String {
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
                    if let d = drawable { Task { await state.retry(store: store, drawable: d) } }
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
                                if let d = drawable { Task { await state.retry(store: store, drawable: d) } }
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
            if let d = drawable {
                Task {
                    await state.switchTo(cand, store: store, drawable: d)
                    pickerVisible = false
                }
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

    // MARK: Game view (score, records, info over video edge)

    private var gameViewPanel: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("GAME VIEW").font(.system(size: 15, weight: .bold)).tracking(1.4).foregroundStyle(.white)
                    Spacer()
                    Button("Close") { gameViewVisible = false }.font(.caption)
                }
                if let event {
                    scoreBlock(event)
                    if let venue = event.venue, !venue.isEmpty {
                        Text(venue).font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    ForEach([(event.awayTeam, "AWAY"), (event.homeTeam, "HOME")], id: \.1) { team, _ in
                        if let team {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(team.name.uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                Text(team.records.compactMap { $0.summary }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                            }
                        }
                    }
                    if let p = state.primary {
                        Text(specsLine(p)).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(RallyTheme.rallyCyan)
                    }
                } else if let channel {
                    Text(channel.name).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    if let now = channel.guide?.now?.title {
                        Text("Now · \(now)").font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    if let next = channel.guide?.next?.title {
                        Text("Next · \(next)").font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(20)
            .frame(width: 360)
            .background(RallyTheme.background.opacity(0.96))
            .overlay(Rectangle().stroke(RallyTheme.glassBorder, lineWidth: 1).opacity(0.6), alignment: .leading)
        }
    }

    private func scoreBlock(_ event: SportEvent) -> some View {
        HStack(spacing: 12) {
            teamBadge(event.awayTeam?.logoUrl, event.awayTeam?.abbreviation)
            VStack {
                if event.status == .live || event.status == .halftime || event.status == .finished {
                    Text("\(event.scoreAway.map(String.init) ?? "–") – \(event.scoreHome.map(String.init) ?? "–")")
                        .font(.system(size: 26, weight: .black)).foregroundStyle(.white)
                } else {
                    Text("VS").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
                Text(event.gameStatusDetail ?? Artwork.displayLeague(event.league))
                    .font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
            }
            teamBadge(event.homeTeam?.logoUrl, event.homeTeam?.abbreviation)
        }
    }

    private func teamBadge(_ url: String?, _ abbr: String?) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 46, height: 46)
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                    Text((abbr ?? "TBD").prefix(3)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
            } else {
                Text((abbr ?? "TBD").prefix(3)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
        }
    }

    // MARK: Diagnostics (trace + specs)

    private var diagnosticsPanel: some View {
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

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        }
    }

    private func healthLabel(_ score: Int) -> String {
        if score >= 55 { return "Excellent" }
        if score >= 15 { return "Good" }
        if score >= -20 { return "Fair" }
        return "Poor"
    }
}

@MainActor
final class MultiViewState: ObservableObject {
    struct Tile: Identifiable {
        var id = UUID().uuidString
        var title: String
        var candidate: PlayCandidate
    }
    @Published var tiles: [Tile] = []
    let engine = VlcEngine()

    var canAdd: Bool { tiles.count < VlcEngine.maxTiles }

    func add(candidate: PlayCandidate) {
        guard canAdd, engine.reserve(slotId: candidate.id) else { return }
        tiles.append(Tile(title: candidate.title, candidate: candidate))
    }

    func remove(_ tile: Tile) {
        tiles.removeAll { $0.id == tile.id }
        engine.release(slotId: tile.candidate.id)
    }

    func play(tile: Tile, drawable: NSView) {
        guard let url = URL(string: tile.candidate.url) else { return }
        try? engine.play(slotId: tile.candidate.id, title: tile.title, url: url,
                         headers: tile.candidate.headers, drawable: drawable)
    }

    func teardown() {
        engine.releaseAll()
        tiles.removeAll()
    }
}

struct MultiViewView: View {
    @EnvironmentObject var store: RallyStore
    @ObservedObject var state: MultiViewState
    var body: some View {
        VStack {
            if state.tiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x2").font(.largeTitle)
                    Text("Multi-View").font(.headline)
                    Text("Open an event and add its sources as tiles (max 4).")
                        .font(.caption).foregroundStyle(RallyTheme.textTertiary)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: state.tiles.count > 1 ? 2 : 1), spacing: 8) {
                    ForEach(state.tiles) { tile in
                        VStack(spacing: 4) {
                            VLCVideoView { view in state.play(tile: tile, drawable: view) }
                                .frame(minHeight: 200)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: RallyTheme.cardCorner))
                            HStack {
                                Text(tile.title).font(.caption).lineLimit(1)
                                Spacer()
                                Button("Remove") { state.remove(tile) }
                                    .font(.caption)
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(RallyTheme.background)
        .navigationTitle("Multi-View (\(state.tiles.count)/4)")
        .onDisappear { state.teardown() }
    }
}
