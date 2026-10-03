import RallyCore
import SwiftUI

struct LiveView: View {
    @EnvironmentObject var store: RallyStore
    @Environment(\.tvMetrics) private var m
    @State private var mode = 0
    @State private var league = "All Sports"
    private var filtered: [SportEvent] { store.liveEvents.filter { league == "All Sports" || $0.league == league } }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                RallyTabs(items: [("Live Games", 0), ("Live TV", 1)], selection: $mode).frame(width: 250)
                Spacer()
                if mode == 0 {
                    Menu {
                        Button("All Sports") { league = "All Sports" }
                        ForEach(Array(Set(store.liveEvents.map(\.league))).sorted(), id: \.self) { name in Button(name) { league = name } }
                    } label: { Label(league, systemImage: "line.3.horizontal.decrease") }
                        .menuStyle(.borderlessButton).fixedSize().buttonStyle(RallyActionStyle()).foregroundStyle(.white)
                }
            }.padding(.horizontal, m.hPad)
            if mode == 1 { TvLiveTv() }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: m.sectionSpacing) {
                        RallySectionTitle(title: "Live Now", actionTitle: "Refresh") { Task { await store.refresh() } }
                        if store.isLoading && store.events.isEmpty { ProgressView("Loading live games…") }
                        else if filtered.isEmpty {
                            RallyEmptyState(eyebrow: "Live", title: "No games live right now.", message: "Check the next starts or browse your TV channels.")
                            HStack(spacing: 12) {
                                if !store.liveEvents.isEmpty { Button("Clear Filter") { league = "All Sports" }.buttonStyle(RallyActionStyle()) }
                                Button("Full Schedule") { store.destination = .schedule }.buttonStyle(RallyActionStyle(primary: true))
                                Button("Browse Live TV") { mode = 1 }.buttonStyle(RallyActionStyle())
                            }
                        } else {
                            RallyMediaRail(title: "On Air", events: filtered)
                            ForEach(Array(Set(filtered.map(\.league))).sorted(), id: \.self) { name in
                                RallyMediaRail(title: Artwork.displayLeague(name), events: filtered.filter { $0.league == name })
                            }
                        }
                        if !store.upcomingEvents.isEmpty { RallyMediaRail(title: "Next Up", events: Array(store.upcomingEvents.prefix(12))) { store.destination = .schedule } }
                    }.padding(.horizontal, m.hPad).padding(.bottom, 36)
                }
            }
        }.padding(.top, 16)
    }
}
