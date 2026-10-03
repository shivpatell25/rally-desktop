import RallyCore
import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var indexedQuery = ""
    @State private var streams: [StremioStreamOption] = []
    @State private var searching = false
    private var events: [SportEvent] {
        var seen = Set<String>()
        return (store.events + store.scheduleEvents).filter {
            seen.insert($0.id).inserted && !indexedQuery.isEmpty && [$0.name, $0.league, $0.sport, $0.homeTeam?.name ?? "", $0.awayTeam?.name ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(indexedQuery) })
        }.prefix(20).map { $0 }
    }
    private var teams: [FavoriteTeam] {
        settings.favoriteTeamProfiles.filter { !indexedQuery.isEmpty && [$0.name, $0.abbreviation, $0.league].contains(where: { $0.localizedCaseInsensitiveContains(indexedQuery) }) }
    }
    private var leagues: [String] {
        EspnClient.leagues.map(\.league).filter { !indexedQuery.isEmpty && ($0.localizedCaseInsensitiveContains(indexedQuery) || Artwork.displayLeague($0).localizedCaseInsensitiveContains(indexedQuery)) }
    }
    private var channels: [IptvChannel] {
        store.channels.filter { !indexedQuery.isEmpty && [$0.name, $0.number, $0.category, $0.guide?.now?.title ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(indexedQuery) }) }.prefix(24).map { $0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(RallyTheme.textPrimary)
                TextField("Search games, teams, leagues, channels", text: $query).textFieldStyle(.plain).font(RallyFont.font(size: 20)).focused($focused)
                if searching { ProgressView().controlSize(.small) }
                Button { store.show(nil) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close Search (Escape)")
            }.padding(18).background(RallyTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            if indexedQuery.isEmpty {
                RallyEmptyState(eyebrow: "Search Rally", title: "Find your next game.", message: "Search the sports schedule, your teams, live channels, and installed addons.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !events.isEmpty { RallySectionTitle(title: "Games"); ForEach(events) { RallyEventRow(event: $0) } }
                        if !teams.isEmpty {
                            RallySectionTitle(title: "My Teams")
                            ForEach(teams) { team in
                                Button { store.show(.team(team)) } label: {
                                    HStack(spacing: 14) {
                                        RallyTeamLogo(team: Team(id: team.id, name: team.name, abbreviation: team.abbreviation, logoUrl: team.logoUrl))
                                        Text(team.name); Spacer(); Text(team.league).foregroundStyle(RallyTheme.textSecondary); Image(systemName: "chevron.right")
                                    }.padding(.vertical, 12)
                                }.buttonStyle(.plain)
                            }
                        }
                        if !leagues.isEmpty {
                            RallySectionTitle(title: "Leagues")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(leagues, id: \.self) { league in
                                        RallyLeagueShortcut(league: league) { settings.recordViewedLeague(league); store.pendingLeague = league; store.destination = .leagues; store.show(nil) }
                                    }
                                }
                            }
                        }
                        if !channels.isEmpty {
                            RallySectionTitle(title: "Channels")
                            ForEach(channels) { channel in
                                Button { store.show(.player(event: nil, channel: channel)) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(channel.name).font(RallyFont.font(size: 14, weight: .semibold))
                                            Text(channel.guide?.now?.title ?? channel.category).font(.caption).foregroundStyle(RallyTheme.textSecondary)
                                        }; Spacer(); Image(systemName: "play.circle")
                                    }.rallySurface(padding: 12)
                                }.buttonStyle(.plain)
                            }
                        }
                        if !streams.isEmpty {
                            RallySectionTitle(title: "Addon Streams")
                            ForEach(streams, id: \.streamUrl) { stream in
                                Button {
                                    if !stream.isDirectPlayable, let url = URL(string: stream.streamUrl) { NSWorkspace.shared.open(url); return }
                                    let candidate = PlayCandidate(title: stream.title, url: stream.streamUrl, headers: stream.headers, kind: .stremio, exactMatch: false, rank: 0, addonName: stream.addonName)
                                    store.show(.player(event: nil, channel: nil, source: candidate))
                                } label: {
                                    HStack { VStack(alignment: .leading, spacing: 4) {
                                        Text(stream.title).lineLimit(2)
                                        Text(stream.addonName ?? "Addon").font(.caption).foregroundStyle(RallyTheme.textSecondary)
                                    }; Spacer(); Image(systemName: stream.isDirectPlayable ? "play.circle" : "arrow.up.right.square") }.rallySurface(padding: 12)
                                }.buttonStyle(.plain).help(stream.isDirectPlayable ? "Play this source" : "Open this source in your browser")
                            }
                        }
                        if !searching && events.isEmpty && teams.isEmpty && leagues.isEmpty && channels.isEmpty && streams.isEmpty {
                            RallyEmptyState(eyebrow: "Search", title: "No results found.", message: "Try a team, league, channel, or shorter game title.")
                        }
                    }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(RallyTheme.deepNavy)
            .onAppear { focused = true }
            .task { await store.ensureChannels() }
            .task(id: query) {
                let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                indexedQuery = requested; streams = []
                guard requested.count >= 3 else { searching = false; return }
                searching = true
                let results = await store.stremioClient.searchStreams(query: requested, addons: settings.stremioAddonUrls)
                guard !Task.isCancelled && query.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
                streams = results; searching = false
                for channel in channels.prefix(8) {
                    if let guide = await store.guide(for: channel), let index = store.channels.firstIndex(where: { $0.id == channel.id }) {
                        store.channels[index].guide = guide
                    }
                }
            }
            .background { RallyEscapeHandler { store.show(nil) }.frame(width: 0, height: 0) }
            .onExitCommand { store.show(nil) }
    }
}
