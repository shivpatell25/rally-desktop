import RallyCore
import SwiftUI

/// Bundle ID: com.shiv.rally.macos
@main
struct RallyApp: App {
    @StateObject private var store = RallyStore()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.settings)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
    }
}

enum RallyTab: Int, Hashable {
    case home, leagues, search, settings
}

@MainActor
final class RallyStore: ObservableObject {
    @Published var events: [SportEvent] = []
    @Published var isLoading = false
    @Published var addonManifests: [String: StremioManifest] = [:]
    @Published var update: RallyRelease?
    @Published var channels: [IptvChannel] = []
    @Published var connectionStatus: String?
    @Published var tab: RallyTab = .home
    let settings = SettingsStore()
    private let espn = EspnClient()
    @Published var selectedEvent: SportEvent?
    @Published var selectedChannel: IptvChannel?
    @Published var showingMultiView = false
    let multiView = MultiViewState()

    var stremioClient: StremioClient { stremio }
    var stalkerClient: StalkerClient { providers().0 }
    var xtreamClient: XtreamClient { providers().1 }
    private let stremio = StremioClient()
    private let updates = UpdateChecker()
    private var stalker: StalkerClient?
    private var xtream: XtreamClient?

    private func providers() -> (StalkerClient, XtreamClient) {
        if let s = stalker, let x = xtream { return (s, x) }
        let s = StalkerClient(settings: settings)
        let x = XtreamClient(settings: settings)
        stalker = s; xtream = x
        return (s, x)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        async let board = espn.fetchAllLeagues()
        let addons = settings.stremioAddonUrls
        let manifests = await withTaskGroup(of: (String, StremioManifest?).self) { group in
            for url in addons {
                group.addTask { (url, try? await self.stremio.fetchManifest(from: url)) }
            }
            var out: [String: StremioManifest] = [:]
            for await (url, man) in group { if let man { out[url] = man } }
            return out
        }
        self.events = await board
        self.addonManifests = manifests
    }

    func refreshChannels() async {
        let (s, x) = providers()
        channels = settings.iptvProvider == .stalker ? await s.getChannels() : await x.getChannels()
    }

    func testConnection() async {
        connectionStatus = "Testing…"
        let (s, x) = providers()
        let ok = settings.iptvProvider == .stalker ? await s.authenticate(force: true) : await x.authenticate()
        connectionStatus = ok ? "Connected" : "Failed — check URL and credentials"
    }

    func checkUpdates() async {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        self.update = await updates.check(currentVersion: current)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: RallyStore
    var body: some View {
        NavigationSplitView {
            List(selection: $store.tab) {
                Section("Browse") {
                    Label("Home", systemImage: "house").tag(RallyTab.home)
                    Label("Leagues", systemImage: "trophy").tag(RallyTab.leagues)
                    Label("Search", systemImage: "magnifyingglass").tag(RallyTab.search)
                    Label("Settings", systemImage: "gear").tag(RallyTab.settings)
                }
                if !store.addonManifests.isEmpty {
                    Section("Addons") {
                        ForEach(store.addonManifests.sorted(by: { $0.key < $1.key }), id: \.key) { _, man in
                            VStack(alignment: .leading) {
                                Text(man.name ?? "Stremio").font(.headline)
                                Text("v\(man.version ?? "?")").font(.caption).foregroundStyle(RallyTheme.textTertiary)
                            }
                        }
                    }
                }
                if let rel = store.update {
                    Section("Update") {
                        Text("v\(rel.tag) available").foregroundStyle(RallyTheme.rallyLime)
                    }
                }
            }
            .navigationTitle("Rally")
        } detail: {
            switch store.tab {
            case .home: HomeView()
            case .leagues: LeaguesView()
            case .search: SearchView()
            case .settings: SettingsView()
            }
        }
        .background(RallyTheme.background)
        .task { await store.refresh(); await store.checkUpdates() }
        .sheet(item: $store.selectedEvent) { event in
            PlayerView(event: event, channel: nil)
                .environmentObject(store)
                .environmentObject(store.settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .sheet(item: $store.selectedChannel) { channel in
            PlayerView(event: nil, channel: channel)
                .environmentObject(store)
                .environmentObject(store.settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .sheet(isPresented: $store.showingMultiView) {
            MultiViewView(state: store.multiView)
                .environmentObject(store)
                .environmentObject(store.settings)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: RallyStore
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                ForEach(store.events.prefix(60)) { event in
                    GameCard(event: event).onTapGesture { store.selectedEvent = event }
                }
            }
            .padding(20)
        }
        .background(RallyTheme.background)
        .overlay { if store.isLoading && store.events.isEmpty { ProgressView("Loading games…") } }
    }
}

struct LeaguesView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        List {
            ForEach(settings.sportsOrder, id: \.self) { league in
                let games = store.events.filter { $0.league == league }
                if !games.isEmpty {
                    Section("\(league) (\(games.count))") {
                        ForEach(games.prefix(30)) { event in
                            GameRow(event: event).onTapGesture { store.selectedEvent = event }
                        }
                    }
                }
            }
        }
        .background(RallyTheme.background)
    }
}

struct SearchView: View {
    @EnvironmentObject var store: RallyStore
    @State private var query = ""
    var body: some View {
        VStack {
            TextField("Search teams, games, channels", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top])
            List {
                ForEach(filteredEvents) { event in
                    GameRow(event: event).onTapGesture { store.selectedEvent = event }
                }
                if !query.isEmpty {
                    Section("Channels") {
                        ForEach(filteredChannels) { channel in
                            HStack {
                                Text(channel.name)
                                Spacer()
                                if let now = channel.guide?.now?.title {
                                    Text(now).font(.caption).foregroundStyle(RallyTheme.textTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { store.selectedChannel = channel }
                        }
                    }
                }
            }
        }
        .background(RallyTheme.background)
    }
    private var filteredEvents: [SportEvent] {
        guard !query.isEmpty else { return Array(store.events.prefix(20)) }
        let q = query.lowercased()
        return store.events.filter {
            $0.name.lowercased().contains(q)
            || ($0.homeTeam?.name.lowercased().contains(q) == true)
            || ($0.awayTeam?.name.lowercased().contains(q) == true)
        }
    }
    private var filteredChannels: [IptvChannel] {
        let q = query.lowercased()
        return store.channels.filter { $0.name.lowercased().contains(q) }.prefix(30).map { $0 }
    }
}

struct GameRow: View {
    let event: SportEvent
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(event.name).font(.headline).foregroundStyle(RallyTheme.textPrimary)
                Text("\(event.league) · \(event.startTime.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(RallyTheme.textTertiary)
            }
            Spacer()
            StatusBadge(status: event.status)
        }
    }
}

struct GameCard: View {
    let event: SportEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.league).font(.caption.bold()).foregroundStyle(RallyTheme.rallyCyan)
                Spacer()
                StatusBadge(status: event.status)
            }
            Text(event.name).font(.headline).foregroundStyle(RallyTheme.textPrimary).lineLimit(2)
            if let home = event.homeTeam, let away = event.awayTeam {
                HStack {
                    Text("\(away.abbreviation) \(event.scoreAway.map(String.init) ?? "")")
                    Text("@")
                    Text("\(home.abbreviation) \(event.scoreHome.map(String.init) ?? "")")
                }
                .font(.title3.bold()).foregroundStyle(RallyTheme.textPrimary)
            }
            Text(event.startTime.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(RallyTheme.textTertiary)
        }
        .padding(14)
        .background(RallyTheme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: RallyTheme.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: RallyTheme.cardCorner).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }
}

struct StatusBadge: View {
    let status: EventStatus
    var body: some View {
        Text(label).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color).clipShape(Capsule()).foregroundStyle(.black)
    }
    private var label: String {
        switch status { case .live: "LIVE"; case .halftime: "HALF"; case .finished: "FINAL"; case .notStarted: "UPCOMING"; case .delayed: "DELAYED"; case .canceled: "CANCELED" }
    }
    private var color: Color {
        switch status { case .live, .halftime: RallyTheme.liveRed; case .finished: RallyTheme.textTertiary; default: RallyTheme.rallyLime }
    }
}
