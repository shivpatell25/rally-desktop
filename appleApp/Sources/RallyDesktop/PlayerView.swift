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
    let event: SportEvent?
    let channel: IptvChannel?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VLCVideoView { view in
                    drawable = view
                    if !started {
                        started = true
                        Task { await state.load(event: event, channel: channel, store: store, drawable: view) }
                    }
                }
                .frame(minWidth: 480, minHeight: 270)
                .background(Color.black)
                HStack(spacing: 10) {
                    if state.isLoading { ProgressView().scaleEffect(0.7) }
                    Button(state.paused ? "▶" : "❚❚") { state.togglePause() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(RallyTheme.textPrimary)
                        .disabled(!state.isPlaying)
                        .keyboardShortcut(.space, modifiers: [])
                    if let err = state.error {
                        Text(err).font(.caption).foregroundStyle(RallyTheme.liveRed).lineLimit(1)
                        Button("Retry") {
                            if let d = drawable { Task { await state.retry(store: store, drawable: d) } }
                        }
                    } else if let p = state.primary {
                        Text(p.title).font(.caption).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                        Spacer()
                        Text(state.positionText).font(.caption.monospacedDigit())
                            .foregroundStyle(RallyTheme.textSecondary)
                        Text(p.kind == .stremio ? "Stremio" : "IPTV").font(.caption2.bold())
                            .foregroundStyle(RallyTheme.rallyCyan)
                    }
                    Spacer()
                    Button(state.showDiagnostics ? "Hide stats" : "Stats") {
                        state.showDiagnostics.toggle()
                    }
                    .font(.caption)
                }
                .padding(8)
                if state.showDiagnostics {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.trace.suffix(6), id: \.self) { line in
                            Text(line).font(.caption2.monospaced())
                                .foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                        }
                    }
                    .padding([.horizontal, .bottom], 8)
                }
            }
            .frame(minWidth: 500)
            VStack(alignment: .leading) {
                Text("Sources (\(state.candidates.count))").font(.headline).padding([.top, .horizontal])
                if state.isLoading && state.candidates.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView("Finding sources…")
                        ForEach(state.trace.suffix(3), id: \.self) { line in
                            Text(line).font(.caption2).foregroundStyle(RallyTheme.textTertiary)
                        }
                    }
                    .padding()
                } else if !state.isLoading && state.candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.error ?? "No playable sources found")
                            .font(.callout).foregroundStyle(RallyTheme.liveRed)
                        Text("Check addon URLs and the IPTV provider in Settings, then retry.")
                            .font(.caption).foregroundStyle(RallyTheme.textSecondary)
                        HStack {
                            Button("Retry") {
                                if let d = drawable { Task { await state.retry(store: store, drawable: d) } }
                            }
                            Button("Open Settings") { store.show(.settings) }
                        }
                    }
                    .padding()
                } else {
                    List(state.candidates) { cand in
                        Button {
                            if let d = drawable { Task { await state.switchTo(cand, store: store, drawable: d) } }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(cand.title).font(.callout).lineLimit(2)
                                    if let addon = cand.addonName {
                                        Text(addon).font(.caption).foregroundStyle(RallyTheme.textTertiary)
                                    }
                                    if let note = state.candidateNote[cand.id] {
                                        Text(note).font(.caption2).foregroundStyle(RallyTheme.textSecondary)
                                    }
                                }
                                if cand.exactMatch {
                                    Text("MATCH").font(.caption2.bold()).foregroundStyle(RallyTheme.rallyLime)
                                }
                                Button("+ Tile") { store.multiView.add(candidate: cand) }
                                    .font(.caption)
                                    .disabled(!store.multiView.canAdd)
                                if cand.id == state.primary?.id {
                                    Image(systemName: "play.fill").foregroundStyle(RallyTheme.rallyCyan)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: 240, maxWidth: 340)
        }
        .background(RallyTheme.background)
        .navigationTitle(event?.name ?? channel?.name ?? "Player")
        .toolbar {
            Button("Multi-View (\(store.multiView.tiles.count))") {
                store.show(.multiView)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                state.refreshStats()
            }
        }
        .onDisappear { state.teardown() }
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
