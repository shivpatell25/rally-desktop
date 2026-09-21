import RallyCore
import SwiftUI

/// LIVE destination: provider channels with Now/Next EPG.
/// The menu LIVE tab means live TV, not live games.
struct TvLiveTv: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @State private var query = ""
    @State private var guides: [String: ChannelGuide] = [:]
    @State private var loadingGuides = false
    @FocusState private var focus: String?

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
                TextField("Search channels", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .padding(.horizontal, m.hPad).padding(.top, 10)
            if store.channels.isEmpty {
                VStack(spacing: 10) {
                    Text("No channels loaded").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    Text("Configure the IPTV provider in Settings, then come back.")
                        .font(.callout).foregroundStyle(RallyTheme.textSecondary)
                    Button("Open Settings") { store.show(.settings) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered.prefix(120)) { channel in
                            channelRow(channel)
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
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                focus == channel.id ? RallyTheme.rallyCyan : RallyTheme.glassBorder,
                lineWidth: focus == channel.id ? 2 : 1))
        }
        .buttonStyle(.plain)
        .focused($focus, equals: channel.id)
    }

    private func loadGuides() async {
        let targets = Array(store.channels.prefix(40))
        guard !targets.isEmpty else { return }
        loadingGuides = true
        defer { loadingGuides = false }
        await withTaskGroup(of: (String, ChannelGuide?).self) { group in
            for ch in targets {
                group.addTask { (ch.id, await store.guide(for: ch)) }
            }
            for await (id, guide) in group {
                if let guide { guides[id] = guide }
            }
        }
    }
}
