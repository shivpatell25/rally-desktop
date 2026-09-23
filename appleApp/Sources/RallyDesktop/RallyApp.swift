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
    /// Action gate (Android TvActionGate): identical pushes within 250ms collapse,
    /// so rapid clicks can't double-push sheets or double-fire channel loads.
    private var lastSheetId: String?
    private var lastSheetAt = Date.distantPast
    func show(_ sheet: AppSheet?) {
        if let sheet {
            let now = Date()
            if sheet.id == lastSheetId, now.timeIntervalSince(lastSheetAt) < 0.25 { return }
            lastSheetId = sheet.id
            lastSheetAt = now
        }
        self.sheet = sheet
    }
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
            evaluateAlerts(previous: events, current: fresh)
            events = fresh
            scheduleStore.save(fresh)
        } else if events.isEmpty {
            // Offline/DNS outage: stale schedule beats an empty shelf.
            events = scheduleStore.loadAny() ?? []
        }
        self.addonManifests = manifests
    }

    let alertCenter = GameAlertCenter()

    /// Diff the refresh against the last snapshot and notify for favorites
    /// (Android GameAlertManager + HomeViewModel gate).
    private func evaluateAlerts(previous: [SportEvent], current: [SportEvent]) {
        guard settings.liveGameAlertsEnabled else { return }
        let favIds = Set(settings.favoriteTeamProfiles.flatMap { [$0.id, $0.key] })
        guard !favIds.isEmpty else { return }
        let alerts = GameAlerts.evaluate(previous: previous, current: current,
                                         favIds: favIds,
                                         redZoneEnabled: settings.redZoneAlertsEnabled)
        alertCenter.deliver(alerts, events: current)
    }

    func testConnection() async {
        connectionStatus = "Testing…"
        let (s, x) = providers()
        let ok = settings.iptvProvider == .stalker ? await s.authenticate(force: true) : await x.authenticate()
        connectionStatus = ok ? "Connected" : "Failed — check URL and credentials"
    }

    @Published var checkingUpdates = false
    @Published var updateError: String?
    @Published var updateChecked = false
    /// In-app updater (Sparkle feed). Instantiated once; the GitHub poll below
    /// stays as the fallback that deep-links when nothing is staged.
    let sparkle = SparkleUpdater()

    func checkUpdates(force: Bool = false) async {
        let now = Date().timeIntervalSince1970
        if !force, now - settings.lastUpdateCheckMs / 1000 < 7 * 24 * 3600, updateChecked { return }
        guard !checkingUpdates else { return }
        checkingUpdates = true
        defer { checkingUpdates = false }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        switch await updates.poll(currentVersion: current) {
        case .available(let rel):
            update = rel
            updateError = nil
        case .upToDate:
            update = nil
            updateError = nil
        case .failed(let message):
            updateError = message
        }
        settings.lastUpdateCheckMs = now * 1000
        updateChecked = true
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
    @State private var lastInteraction = Date()
    @State private var saverNow = Date()
    /// Idle screensaver (5 min, suppressed while anything is presented).
    private var saverActive: Bool {
        store.settings.scoreSaverEnabled && !showOnboarding && store.sheet == nil
            && saverNow.timeIntervalSince(lastInteraction) > 5 * 60
    }
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
                }
                // Idle ambient scores sit above content, below sheets/player.
                if saverActive {
                    ScoreSaverOverlay()
                        .transition(.opacity)
                        .onTapGesture { lastInteraction = Date() }
                }
            }
            .environment(\.tvMetrics, TvMetrics(width: geo.size.width))
            .environment(\.rallyHighContrast, store.settings.highContrastFocus)
            .environment(\.rallyReduceMotion, store.settings.reducedMotion)
            .environment(\.dynamicTypeSize, store.settings.largeText ? .accessibility1 : .large)
        }
        .rallyAnimation(.smooth(duration: 0.35), value: destination)
        .onChange(of: destination) { next in
            slideEdge = tabIndex(next) >= prevTab ? .trailing : .leading
            prevTab = tabIndex(next)
            lastInteraction = Date()
        }
        .onChange(of: store.sheet?.id) { _ in lastInteraction = Date() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                saverNow = Date()
            }
        }
        .background { AmbientBackground() }
        .task {
            showOnboarding = !LaunchArgs.skipOnboarding && store.settings.needsOnboarding
            store.alertCenter.requestAuthorization()
            await store.refresh()
            await store.checkUpdates()
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
        .onReceive(NotificationCenter.default.publisher(for: GameAlertCenter.openEventNotification)) { note in
            guard let id = note.object as? String,
                  let e = store.events.first(where: { $0.id == id }) else { return }
            store.show(.eventDetail(e))
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "rally" else { return }
            let parts = url.pathComponents.filter { $0 != "/" }
            switch (url.host?.lowercased(), parts.first) {
            case ("event", let id?):
                if let e = store.events.first(where: { $0.id == id }) { store.show(.eventDetail(e)) }
            case ("team", let key?):
                if let team = store.settings.favoriteTeamProfiles.first(where: { $0.key == key }) {
                    store.show(.team(team))
                }
            default:
                break
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
        .overlay { if store.isLoading && store.events.isEmpty { ProgressView("Loading games…") } }
    }
}

struct LeaguesView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        List {
            ForEach(settings.sportsOrder.filter { settings.isLeagueEnabled($0) }, id: \.self) { league in
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
    @State private var debouncedQuery = ""
    @State private var generation = 0
    @State private var addonStreams: [(event: SportEvent, option: StremioStreamOption)] = []
    @State private var streamsLoading = false
    @State private var indexReady = false
    var body: some View {
        VStack {
            TextField("Search teams, games, leagues, channels", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top])
                .onChange(of: query) { _ in
                    generation += 1
                    let current = generation
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if current == generation { debouncedQuery = query }
                    }
                }
            if debouncedQuery.isEmpty && !store.events.isEmpty { indexReadyNote }
            List {
                if !filteredLeagues.isEmpty {
                    Section("Leagues") {
                        ForEach(filteredLeagues, id: \.self) { league in
                            HStack {
                                Text(league)
                                Spacer()
                                Text("\(store.events.filter { $0.league == league }.count) games")
                                    .font(.caption).foregroundStyle(RallyTheme.textTertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.pendingLeague = league
                                store.show(nil)
                            }
                        }
                    }
                }
                if !filteredTeams.isEmpty {
                    Section("My Teams") {
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
                if !filteredEvents.isEmpty {
                    Section("Games") {
                        ForEach(filteredEvents) { event in
                            GameRow(event: event).onTapGesture { store.show(.eventDetail(event)) }
                        }
                    }
                }
                if !filteredChannels.isEmpty {
                    Section("Live TV") {
                        ForEach(filteredChannels) { channel in
                            HStack {
                                Text(channel.name)
                                Spacer()
                                if let now = channel.guide?.now?.title {
                                    Text(now).font(.caption).foregroundStyle(RallyTheme.textTertiary)
                                } else if let next = channel.guide?.next?.title {
                                    Text("Next · \(next)").font(.caption).foregroundStyle(RallyTheme.textTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { store.show(.player(event: nil, channel: channel)) }
                        }
                    }
                }
                if streamsLoading {
                    Section("Addon Streams") {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } else if !addonStreams.isEmpty {
                    Section("Addon Streams") {
                        ForEach(addonStreams, id: \.option.streamUrl) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.option.title).lineLimit(1)
                                    Text(item.event.name).font(.caption).foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                                }
                                Spacer()
                                if let addon = item.option.addonName {
                                    Text(addon).font(.caption).foregroundStyle(RallyTheme.textTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { store.show(.player(event: item.event, channel: nil)) }
                        }
                    }
                }
                if !debouncedQuery.isEmpty && filteredLeagues.isEmpty && filteredTeams.isEmpty
                    && filteredEvents.isEmpty && filteredChannels.isEmpty && addonStreams.isEmpty && !streamsLoading {
                    Text("No results found.").foregroundStyle(RallyTheme.textSecondary)
                }
            }
        }
        .background { AmbientBackground() }
        .task(id: debouncedQuery) { await runSearch() }
        .task { indexReady = !store.events.isEmpty }
    }
    private var indexReadyNote: some View {
        Text(indexReady ? "Index ready · \(store.events.count) games · \(store.channels.count) channels"
                        : "Building index…")
            .font(.caption).foregroundStyle(RallyTheme.textTertiary)
    }
    private var filteredTeams: [FavoriteTeam] {
        guard !debouncedQuery.isEmpty else { return Array(settings.favoriteTeamProfiles.prefix(12)) }
        let q = debouncedQuery.lowercased()
        return settings.favoriteTeamProfiles.filter {
            $0.name.lowercased().contains(q) || $0.abbreviation.lowercased().contains(q)
        }
    }
    private var filteredEvents: [SportEvent] {
        guard !debouncedQuery.isEmpty else { return Array(store.events.prefix(20)) }
        let q = debouncedQuery.lowercased()
        return store.events.filter {
            $0.name.lowercased().contains(q)
            || ($0.homeTeam?.name.lowercased().contains(q) == true)
            || ($0.awayTeam?.name.lowercased().contains(q) == true)
        }.prefix(20).map { $0 }
    }
    private var filteredLeagues: [String] {
        guard !debouncedQuery.isEmpty else { return [] }
        let q = debouncedQuery.lowercased()
        return EspnClient.leagues.map(\.league).filter { $0.lowercased().contains(q) }.prefix(8).map { $0 }
    }
    private var filteredChannels: [IptvChannel] {
        let q = debouncedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        return store.channels.filter {
            $0.name.lowercased().contains(q) || $0.number.contains(q)
                || ($0.guide?.now?.title.lowercased().contains(q) == true)
                || ($0.guide?.next?.title.lowercased().contains(q) == true)
        }.prefix(24).map { $0 }
    }
    /// Addon-stream lookup only for queries of 3+ chars (Android SearchViewModel).
    private func runSearch() async {
        addonStreams = []
        guard debouncedQuery.count >= 3 else { streamsLoading = false; return }
        streamsLoading = true
        defer { streamsLoading = false }
        let q = debouncedQuery.lowercased()
        let targets = filteredEvents.prefix(5)
        var out: [(event: SportEvent, option: StremioStreamOption)] = []
        for event in targets {
            for base in settings.stremioAddonUrls {
                let opts = await store.stremioClient.findStreams(for: event, addonBase: base)
                for opt in opts where opt.isDirectPlayable
                    && (opt.title.lowercased().contains(q) || (opt.description?.lowercased().contains(q) == true)) {
                    out.append((event, opt))
                    if out.count >= 20 { break }
                }
                if out.count >= 20 { break }
            }
            if out.count >= 20 { break }
        }
        addonStreams = out
        // Enrich the visible channel rows with guides (first 8, guarded).
        for channel in filteredChannels.prefix(8) where channel.guide == nil {
            _ = await store.guide(for: channel)
        }
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
