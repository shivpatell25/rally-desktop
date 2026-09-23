import RallyCore
import SwiftUI

/// Bundle ID: com.shiv.rally.macos
@main
struct RallyApp: App {
    @StateObject private var store = RallyStore()

    init() {
        // Bounded artwork cache (mirrors CoilModule budgets): repeat badge
        // scrolls hit memory/disk instead of re-downloading short-TTL art.
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                    diskCapacity: 128 * 1024 * 1024)
    }
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

/// Every modal in the app flows through one slot, so detail → player →
/// multi-view transitions always surface (SwiftUI presents one sheet per level).
enum AppSheet: Identifiable {
    case eventDetail(SportEvent)
    case team(FavoriteTeam)
    case player(event: SportEvent?, channel: IptvChannel?, clip: HighlightClip? = nil, picker: Bool = false)
    case multiView
    case search
    case settings

    var id: String {
        switch self {
        case .eventDetail(let e): return "event-\(e.id)"
        case .team(let t): return "team-\(t.key)"
        case .player(let e, let c, let clip, _):
            return "player-\(e?.id ?? c?.id ?? "none")-\(clip?.id ?? "live")"
        case .multiView: return "multiview"
        case .search: return "search"
        case .settings: return "settings"
        }
    }
}
@MainActor
final class RallyStore: ObservableObject {
    @Published var events: [SportEvent] = []
    @Published var isLoading = false
    @Published var addonManifests: [String: StremioManifest] = [:]
    @Published var pendingLeague: String?
    @Published var update: RallyRelease?
    @Published var channels: [IptvChannel] = []
    @Published var highlights: [GameHighlight] = []
    @Published var highlightsLoading = false
    @Published var connectionStatus: String?
    @Published var tab: RallyTab = .home
    let settings = SettingsStore()
    private let espn = EspnClient()
    @Published var sheet: AppSheet?
    let multiView = MultiViewState()

    /// Single-sheet router: one presentation slot, so detail → player always surfaces.
    func show(_ sheet: AppSheet?) { self.sheet = sheet }
    func refreshChannels() async {
        let (s, x) = providers()
        channels = settings.iptvProvider == .stalker ? await s.getChannels() : await x.getChannels()
    }

    /// Credential change: drop the auth token and both in-memory catalogs so
    /// the next load performs a fresh handshake (Android `saveConfiguration`).
    func resetProviderSession() {
        settings.authToken = ""
        let (s, x) = providers()
        s.clearChannelCache()
        x.clearChannelCache()
        channels = []
    }
    private let stremio = StremioClient()
    private let updates = UpdateChecker()
    private var stalker: StalkerClient?
    private var xtream: XtreamClient?
    var stremioClient: StremioClient { stremio }
    var espnClient: EspnClient { espn }
    var stalkerClient: StalkerClient { providers().0 }
    var xtreamClient: XtreamClient { providers().1 }

    func ensureChannels() async {
        if channels.isEmpty { await refreshChannels() }
    }

    func guide(for channel: IptvChannel) async -> ChannelGuide? {
        let (s, x) = providers()
        return settings.iptvProvider == .stalker
            ? await s.getGuide(channelId: channel.id)
            : await x.getGuide(channelId: channel.id)
    }

    /// Aggregates ESPN highlight clips across live + finished games (cap 10
    /// summaries). Mirrors the HighlightsViewModel item flow.
    func refreshHighlights() async {
        guard !highlightsLoading else { return }
        highlightsLoading = true
        defer { highlightsLoading = false }
        let seeds = Array((liveEvents + events.filter { $0.status == .finished }).prefix(10))
        let pairs = await withTaskGroup(of: (SportEvent, [HighlightClip]).self) { group in
            for e in seeds {
                group.addTask {
                    guard let path = EspnClient.path(forLeague: e.league) else { return (e, []) }
                    let detail = await self.espn.fetchSummary(sport: path.sport, league: path.path, eventId: e.id)
                    return (e, detail.clips)
                }
            }
            var out: [(SportEvent, [HighlightClip])] = []
            for await pair in group { out.append(pair) }
            return out
        }
        highlights = pairs.flatMap { e, clips in clips.map { GameHighlight(clip: $0, event: e) } }
    }

    private func providers() -> (StalkerClient, XtreamClient) {
        if let s = stalker, let x = xtream { return (s, x) }
        let s = StalkerClient(settings: settings)
        let x = XtreamClient(settings: settings)
        stalker = s; xtream = x
        return (s, x)
    }

    private var refreshing = false
    private let scheduleStore = ScheduleStore()

    func refresh() async {
        // Coalesce overlapping refresh triggers (one slow portal must not
        // stack concurrent full-fan-out reloads).
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; isLoading = false }
        isLoading = true
        // Instant paint from last-known-good before the network resolves.
        if events.isEmpty, let cached = scheduleStore.loadFresh() { events = cached }
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
        let fresh = await board
        if !fresh.isEmpty {
            events = fresh
            scheduleStore.save(fresh)
        } else if events.isEmpty {
            // Offline/DNS outage: stale schedule beats an empty shelf.
            events = scheduleStore.loadAny() ?? []
        }
        self.addonManifests = manifests
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

/// An ESPN highlight clip linked to its game. Mirrors HighlightItem.
struct GameHighlight: Identifiable {
    var id: String { clip.id }
    var clip: HighlightClip
    var event: SportEvent
}

enum LaunchArgs {
    static var destination: TvDestination {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--tv=") }) else { return .home }
        switch arg.dropFirst(5) {
        case "live": return .live
        case "leagues": return .leagues
        case "highlights": return .highlights
        case "myteams": return .myTeams
        default: return .home
        }
    }
    static var league: String? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--league=") }) else { return nil }
        let l = String(arg.dropFirst(9))
        return l.isEmpty ? nil : l
    }
    static var eventId: String? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--event=") }) else { return nil }
        let id = String(arg.dropFirst(8))
        return id.isEmpty ? nil : id
    }
    static var gameMode: Bool {
        CommandLine.arguments.contains("--game")
    }
    static var openSettings: Bool {
        CommandLine.arguments.contains("--settings")
    }
    static var playId: String? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--play=") }) else { return nil }
        let id = String(arg.dropFirst(7))
        return id.isEmpty ? nil : id
    }
    /// Debug: open a team hub directly (`--team=NFL:1`), resolved from favorites.
    static var teamKey: String? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--team=") }) else { return nil }
        let key = String(arg.dropFirst(7))
        return key.isEmpty ? nil : key
    }
    /// Debug: skip the first-run gate for verification screenshots.
    static var skipOnboarding: Bool {
        CommandLine.arguments.contains("--skip-onboarding")
    }
}
struct ContentView: View {
    @EnvironmentObject var store: RallyStore
    @State private var destination: TvDestination = LaunchArgs.destination
    @State private var slideEdge: Edge = .trailing
    @State private var prevTab = 0
    @State private var showOnboarding = false
    private func tabIndex(_ d: TvDestination) -> Int {
        switch d { case .home: 0; case .live: 1; case .leagues: 2; case .highlights: 3; case .myTeams: 4 }
    }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    RallyTopBar(destination: $destination,
                                onSearch: { store.show(.search) },
                                onSettings: { store.show(.settings) })
                    Group {
                        switch destination {
                        case .home: TvHomeDashboard(destination: $destination)
                        case .live: TvLiveTv()
                        case .leagues: TvLeaguesHome()
                        case .highlights: TvHighlights()
                        case .myTeams: TvMyTeams()
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: slideEdge).combined(with: .opacity),
                        removal: .move(edge: slideEdge == .trailing ? .leading : .trailing).combined(with: .opacity)))
                }
                // Fullscreen takeover: the player covers chrome and content.
                if case .player(let event, let channel, let clip, let picker) = store.sheet {
                    PlayerView(event: event, channel: channel, clip: clip, startWithPicker: picker)
                        .environmentObject(store)
                        .environmentObject(store.settings)
                        .transition(.opacity)
                }
                // First-run gate: onboarding until setup is saved or a source exists.
                if showOnboarding {
                    OnboardingView {
                        showOnboarding = false
                        store.show(.settings)
                    }
                    .transition(.opacity)
                }
            }
            .environment(\.tvMetrics, TvMetrics(width: geo.size.width))
        }
        .animation(.smooth(duration: 0.35), value: destination)
        .onChange(of: destination) { next in
            slideEdge = tabIndex(next) >= prevTab ? .trailing : .leading
            prevTab = tabIndex(next)
        }
        .background { AmbientBackground() }
        .task {
            showOnboarding = !LaunchArgs.skipOnboarding && store.settings.needsOnboarding
            await store.refresh()
            if let league = LaunchArgs.league { store.pendingLeague = league }
            if LaunchArgs.openSettings { store.show(.settings) }
            if let id = LaunchArgs.eventId {
                if let e = store.events.first(where: { $0.id == id }) { store.show(.eventDetail(e)) }
                else if let e = store.featuredEvent { store.show(.eventDetail(e)) }
            } else if let id = LaunchArgs.playId {
                if let e = store.events.first(where: { $0.id == id }) { store.show(.player(event: e, channel: nil)) }
                else if let e = store.featuredEvent { store.show(.player(event: e, channel: nil)) }
            }
            if let key = LaunchArgs.teamKey,
               let team = store.settings.favoriteTeamProfiles.first(where: { $0.key == key }) {
                store.show(.team(team))
            }
        }
        .sheet(item: Binding<AppSheet?>(
            get: {
                guard let s = store.sheet else { return nil }
                if case .player = s { return nil } // fullscreen branch owns player
                return s
            },
            set: { store.sheet = $0 }
        )) { sheet in
            Group {
                switch sheet {
                case .eventDetail(let event):
                    TvEventDetail(event: event).frame(minWidth: 1000, minHeight: 700)
                case .team(let team):
                    TvTeamHub(team: team).frame(minWidth: 900, minHeight: 650)
                case .player:
                    EmptyView()
                case .multiView:
                    MultiViewView(state: store.multiView).frame(minWidth: 900, minHeight: 600)
                case .search:
                    SearchView().frame(minWidth: 700, minHeight: 500)
                case .settings:
                    SettingsView().frame(minWidth: 700, minHeight: 550)
                }
            }
            .environmentObject(store)
            .environmentObject(store.settings)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: RallyStore
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                ForEach(store.events.prefix(60)) { event in
                    GameCard(event: event).onTapGesture { store.show(.eventDetail(event)) }
                }
            }
            .padding(20)
        }
        .background { AmbientBackground() }
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
                            GameRow(event: event).onTapGesture { store.show(.eventDetail(event)) }
                        }
                    }
                }
            }
        }
        .background { AmbientBackground() }
    }
}

struct SearchView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var query = ""
    var body: some View {
        VStack {
            TextField("Search teams, games, channels", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top])
            List {
                if !filteredTeams.isEmpty {
                    Section("Teams") {
                        ForEach(filteredTeams) { team in
                            HStack {
                                Text(team.name)
                                Spacer()
                                Text("TEAM CENTER ›").font(.caption).foregroundStyle(RallyTheme.rallyCyan)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { store.show(.team(team)) }
                        }
                    }
                }
                ForEach(filteredEvents) { event in
                    GameRow(event: event).onTapGesture { store.show(.eventDetail(event)) }
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
                            .onTapGesture { store.show(.player(event: nil, channel: channel)) }
                        }
                    }
                }
            }
        }
        .background { AmbientBackground() }
    }
    private var filteredTeams: [FavoriteTeam] {
        guard !query.isEmpty else { return Array(settings.favoriteTeamProfiles.prefix(12)) }
        let q = query.lowercased()
        return settings.favoriteTeamProfiles.filter {
            $0.name.lowercased().contains(q) || $0.abbreviation.lowercased().contains(q)
        }
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
