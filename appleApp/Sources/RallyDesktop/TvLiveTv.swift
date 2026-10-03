import RallyCore
import SwiftUI

/// LIVE destination: provider channels with Now/Next EPG.
/// The menu LIVE tab means live TV, not live games.
struct TvLiveTv: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var query = ""
    @State private var category = "All Channels"
    @State private var guides: [String: ChannelGuide] = [:]
    @State private var loadingGuides = false
    @State private var inflight: Set<String> = []
    @FocusState private var focus: String?
    // EPG fan-out bound (Android Semaphore(4)): at most 4 concurrent guide
    // fetches no matter how fast the user scrolls.
    private let guideSemaphore = AsyncSemaphore(limit: 4)

    private var filtered: [IptvChannel] {
        let q = query.lowercased()
        return store.channels.filter { (category == "All Channels" || $0.category == category) && (q.isEmpty || $0.name.lowercased().contains(q) || $0.number.contains(q) || $0.category.lowercased().contains(q)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sectionSpacing) {
            HStack(alignment: .bottom, spacing: 16) {
                RallyPageHeader(
                    eyebrow: "Live TV",
                    title: "\(store.channels.count) channels",
                    subtitle: "Browse your provider lineup with current and upcoming programming."
                )
                Spacer()
                Button("Reload") { Task { await reloadChannels() } }
                    .font(RallyFont.font(size: m.bodySize, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(RallyTheme.textPrimary)
                TextField("Search channels", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: m.layout == .compact ? 220 : 280)
            }
            Picker("Category", selection: $category) {
                Text("All Channels").tag("All Channels")
                ForEach(Array(Set(store.channels.map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
            }.frame(width: 260)
            if let error = store.channelError { Text(error).font(.callout).foregroundStyle(RallyTheme.textSecondary) }
            if store.channels.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    if channelsLoading {
                        ProgressView("Loading your channels…")
                    } else if providerConfigured {
                        RallyEmptyState(
                            eyebrow: "Live TV unavailable",
                            title: "The portal did not answer.",
                            message: "Your sports schedule is safe. Try the provider connection again."
                        )
                        Button("Try Again") { Task { await reloadChannels() } }
                    } else {
                        RallyEmptyState(
                            eyebrow: "Sources",
                            title: "No channels loaded.",
                            message: "Configure a Stalker, Xtream, or M3U provider in Settings to populate Live TV."
                        )
                        Button("Open Settings") { store.show(.settings) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { channel in
                            channelRow(channel)
                                .onAppear { Task { await loadGuide(for: channel) } }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: m.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, m.hPad)
        .padding(.top, m.pageTopPadding)
        .frame(maxWidth: .infinity)
        .task {
            channelsLoading = true
            await store.ensureChannels()
            channelsLoading = false
            await loadGuides()
        }
        .onMoveCommand { _ in }
    }

    @State private var channelsLoading = false

    private var providerConfigured: Bool {
        !settings.portalUrl.isEmpty || !settings.xtreamServerUrl.isEmpty || !settings.m3uPlaylistUrl.isEmpty
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
                        Text(channel.number).font(RallyFont.font(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(channel.number).font(RallyFont.font(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(RallyFont.font(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if let guide = guides[channel.id] ?? channel.guide {
                        if let now = guide.now?.title {
                            Text("Now · \(now)").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textPrimary).lineLimit(1)
                        }
                        if let next = guide.next?.title {
                            Text("Next · \(next)").font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                        }
                    } else if loadingGuides {
                        Text("Loading guide…").font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textTertiary)
                    }
                }
                Spacer()
                Text(channel.category).font(RallyFont.font(size: 10, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(RallyTheme.textSecondary)
                Image(systemName: "play.circle.fill").font(RallyFont.font(size: 22))
                    .foregroundStyle(RallyTheme.textPrimary)
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
