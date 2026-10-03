import RallyCore
import SwiftUI

struct RallySportDirectory: View {
    let sport: String
    @EnvironmentObject var store: RallyStore
    @Environment(\.tvMetrics) private var m
    private var games: [SportEvent] {
        store.events.filter { sport == "Soccer" ? $0.sport == "soccer" : $0.league == sport }
    }
    private var channels: [IptvChannel] {
        store.channels.filter { ($0.name + " " + $0.category).localizedCaseInsensitiveContains(sport) || (sport == "UFC" && $0.name.localizedCaseInsensitiveContains("MMA")) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text(sport).font(RallyFont.display(34)); Spacer(); Button("All Leagues") { store.pendingLeague = nil }.buttonStyle(RallyActionStyle()) }
                if sport == "Soccer" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 12) {
                        ForEach(EspnClient.leagues.filter { $0.sport == "soccer" }, id: \.league) { entry in
                            RallyLeagueShortcut(league: entry.league, width: 110) { store.pendingLeague = entry.league }
                        }
                    }
                }
                if !games.isEmpty { RallyMediaRail(title: "Games", events: games) }
                if !channels.isEmpty {
                    RallySectionTitle(title: "Live TV")
                    ForEach(channels) { channel in
                        Button { store.show(.player(event: nil, channel: channel)) } label: {
                            HStack { Text(channel.name); Spacer(); Image(systemName: "play.fill") }.padding(14).rallySurface(radius: 8)
                        }.buttonStyle(.plain)
                    }
                } else if games.isEmpty {
                    RallyEmptyState(eyebrow: sport, title: "No scheduled coverage right now.", message: "Browse your live TV channels for additional coverage.")
                    Button("Browse Live TV") { store.navigate(.live) }.buttonStyle(RallyActionStyle())
                }
            }.padding(.horizontal, m.hPad).padding(.top, 22).padding(.bottom, 28)
        }.foregroundStyle(.white).task { if !LaunchArgs.visualFixture { await store.ensureChannels() } }
    }
}
