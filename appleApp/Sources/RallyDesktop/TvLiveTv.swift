import RallyCore
import SwiftUI

/// LIVE destination: provider channels with Now/Next EPG.
/// The menu LIVE tab means live TV, not live games.
struct TvLiveTv: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var query = ""
    @State private var guides: [String: ChannelGuide] = [:]
    @State private var loadingGuides = false
    @State private var inflight: Set<String> = []
    @FocusState private var focus: String?
    // EPG fan-out bound (Android Semaphore(4)): at most 4 concurrent guide
    // fetches no matter how fast the user scrolls.
    private let guideSemaphore = AsyncSemaphore(limit: 4)

    private var filtered: [IptvChannel] {
        guard !query.isEmpty else { return store.channels }
        let q = query.lowercased()
        return store.channels.filter { $0.name.lowercased().contains(q) || $0.number.contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVE TV").font(.system(size: 11, weight: .bold)).tracking(1.5)
                        .foregroundStyle(RallyTheme.rallyCyan)
                    Text("\(store.channels.count) channels").font(.system(size: 24, weight: .black))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button("Reload") { Task { await reloadChannels() } }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(RallyTheme.rallyCyan)
                TextField("Search channels", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .padding(.horizontal, m.hPad).padding(.top, 10)
            if store.channels.isEmpty {
                VStack(spacing: 10) {
                    if channelsLoading {
                        ProgressView("Loading your channels…")
                    } else if providerConfigured {
                        Text("Live TV is unavailable").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        Text("The schedule is safe — the portal didn't answer. Try again.")
                            .font(.callout).foregroundStyle(RallyTheme.textSecondary)
                        Button("Try Again") { Task { await reloadChannels() } }
                    } else {
                        Text("No channels loaded").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        Text("Configure the IPTV provider in Settings, then come back.")
                            .font(.callout).foregroundStyle(RallyTheme.textSecondary)
                        Button("Open Settings") { store.show(.settings) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered.prefix(120)) { channel in
                            channelRow(channel)
                                .onAppear { Task { await loadGuide(for: channel) } }
                        }
                    }
                    .padding(.horizontal, m.hPad).padding(.bottom, 20)
                }
            }
        }
        .background { AmbientBackground() }
        .task {
            await store.ensureChannels()
            await loadGuides()
        }
        .onMoveCommand { _ in }
    }

    @State private var channelsLoading = false

    private var providerConfigured: Bool {
        !settings.portalUrl.isEmpty || !settings.xtreamServerUrl.isEmpty
    }

    private func reloadChannels() async {
        guard !channelsLoading else { return }
        channelsLoading = true
        defer { channelsLoading = false }
        await store.refreshChannels()
        await loadGuides()
    }

    private func channelRow(_ channel: IptvChannel) -> some View {
        Button { store.show(.player(event: nil, channel: channel)) } label: {
            HStack(spacing: 12) {
                if let logo = channel.logoUrl, let link = URL(string: logo) {
                    AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                        Text(channel.number).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(channel.number).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let guide = guides[channel.id] ?? channel.guide {
                        if let now = guide.now?.title {
                            Text("Now · \(now)").font(.system(size: 12)).foregroundStyle(RallyTheme.rallyCyan).lineLimit(1)
                        }
                        if let next = guide.next?.title {
                            Text("Next · \(next)").font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                        }
                    } else if loadingGuides {
                        Text("Loading guide…").font(.system(size: 11)).foregroundStyle(RallyTheme.textTertiary)
                    }
                }
                Spacer()
                Text(channel.category).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(RallyTheme.textSecondary)
                Image(systemName: "play.circle.fill").font(.system(size: 22))
                    .foregroundStyle(RallyTheme.rallyCyan)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
            .rallyFocusRing(active: focus == channel.id, radius: 10)
        }
        .buttonStyle(.plain)
        .focused($focus, equals: channel.id)
    }

    private func loadGuides() async {
        // Eager kick for the first screenful only; the rest load lazily as
        // rows appear (rows past the old prefix(40) wall now get guides too).
        let targets = Array(store.channels.prefix(12))
        guard !targets.isEmpty else { return }
        loadingGuides = true
        defer { loadingGuides = false }
        await withTaskGroup(of: Void.self) { group in
            for ch in targets {
                group.addTask { await loadGuide(for: ch) }
            }
        }
    }

    /// Deduped per-row load: concurrent onAppear events for the same row
    /// collapse into one fetch instead of stampeding the portal.
    private func loadGuide(for channel: IptvChannel) async {
        if guides[channel.id] != nil || channel.guide != nil { return }
        guard !inflight.contains(channel.id) else { return }
        inflight.insert(channel.id)
        defer { inflight.remove(channel.id) }
        await guideSemaphore.wait()
        let guide = await store.guide(for: channel)
        await guideSemaphore.signal()
        if let guide { guides[channel.id] = guide }
    }
}

/// Tiny async semaphore (bounds concurrent portal calls).
private actor AsyncSemaphore {
    private var count = 0
    private let limit: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func wait() async {
        if count < limit { count += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if waiters.isEmpty { count -= 1 } else { waiters.removeFirst().resume() }
    }
}
