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
                .frame(minWidth: 820, minHeight: 600)
                .environmentObject(store)
                .environmentObject(store.settings)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: LaunchArgs.windowSize.width, height: LaunchArgs.windowSize.height)
        .windowResizability(.contentMinSize)
        .commands { RallyCommands(store: store) }
        Settings {
            SettingsView().environmentObject(store).environmentObject(store.settings)
                .preferredColorScheme(.dark).tint(.white)
                .frame(minWidth: 760, minHeight: 580)
        }
    }
}


/// Every modal in the app flows through one slot, so detail → player →
/// multi-view transitions always surface (SwiftUI presents one sheet per level).
enum AppSheet: Identifiable {
    case eventDetail(SportEvent)
    case team(FavoriteTeam)
    case player(event: SportEvent?, channel: IptvChannel?, clip: HighlightClip? = nil, picker: Bool = false, source: PlayCandidate? = nil)
    case multiView
    case search
    case settings

    var id: String {
        switch self {
        case .eventDetail(let e): return "event-\(e.id)"
        case .team(let t): return "team-\(t.key)"
        case .player(let e, let c, let clip, _, let source):
            return "player-\(e?.id ?? c?.id ?? "none")-\(source?.id ?? clip?.id ?? "live")"
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
    @Published var channelError: String?
    @Published var scheduleEvents: [SportEvent] = []
    @Published var scheduleLoading = false
    @Published var scheduleError: String?
    @Published var highlights: [GameHighlight] = []
    @Published var highlightsLoading = false
    @Published var connectionStatus: String?
    @Published var sportsStatus = "Not refreshed"
    @Published var lastSportsRefresh: Date?
    @Published var destination: TvDestination = LaunchArgs.destination
    @Published var homeReset = 0
    let settings = SettingsStore()
    private let espn = EspnClient()
    @Published var sheet: AppSheet?
    let multiView = MultiViewState()

    init() {
        if LaunchArgs.visualFixture {
            events = VisualFixtures.events
            sportsStatus = "Visual fixture · \(events.count) events"
            lastSportsRefresh = Date(timeIntervalSince1970: 1_800_000_000)
        }
    }

    /// Single-sheet router: one presentation slot, so detail → player always surfaces.
    /// Action gate (Android TvActionGate): identical pushes within 250ms collapse,
    /// so rapid clicks can't double-push sheets or double-fire channel loads.
    private var lastSheetId: String?
    private var lastSheetAt = Date.distantPast
    func navigate(_ destination: TvDestination) {
        show(nil)
        if destination == .home { homeReset += 1 }
        self.destination = destination
    }
    func show(_ sheet: AppSheet?) {
        if let sheet {
            let now = Date()
            if sheet.id == lastSheetId, now.timeIntervalSince(lastSheetAt) < 0.25 { return }
            lastSheetId = sheet.id
            lastSheetAt = now
        }
        if case .settings = sheet { openSettings(); return }
        self.sheet = sheet
    }
    func refreshChannels() async {
        let (s, x) = providers()
        channelError = nil
        switch settings.iptvProvider {
        case .stalker: channels = await s.getChannels()
        case .xtream: channels = await x.getChannels()
        case .m3u:
            do { channels = try await M3uClient.load(source: settings.m3uPlaylistUrl, name: settings.m3uPlaylistName) }
            catch { channelError = error.localizedDescription }
        }
        if channels.isEmpty && channelError == nil { channelError = "No channels returned. Check your source in Settings." }
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
        guard settings.iptvProvider != .m3u else { return channel.guide }
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
        var seeds = Array((liveEvents + events.filter { $0.status == .finished }).prefix(10))
        if seeds.isEmpty {
            let dateFormat = DateFormatter(); dateFormat.dateFormat = "yyyyMMdd"
            for daysAgo in 1...3 {
                guard !Task.isCancelled else { return }
                let date = dateFormat.string(from: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!)
                for entry in EspnClient.leagues.filter({ ["NFL", "NBA", "MLB", "NHL"].contains($0.league) }) {
                    let recent = (try? await espn.fetchScoreboard(sport: entry.sport, league: entry.path, domainLeague: entry.league, limit: 30, dates: date)) ?? []
                    seeds += recent.filter { $0.status == .finished }.prefix(3)
                }
                if !seeds.isEmpty { break }
            }
        }
        seeds = Array(seeds.prefix(10))
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
        var seen = Set<String>()
        let fresh = pairs.sorted { $0.0.startTime > $1.0.startTime }.flatMap { e, clips in clips.map { GameHighlight(clip: $0, event: e) } }.filter { seen.insert($0.id).inserted }
        if !fresh.isEmpty { highlights = fresh }
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
        async let board = espn.fetchSportsFeed(enabled: settings.enabledLeagues)
        let addons = settings.stremioAddonUrls
        let manifests = await withTaskGroup(of: (String, StremioManifest?).self) { group in
            for url in addons {
                group.addTask { (url, try? await self.stremio.fetchManifest(from: url)) }
            }
            var out: [String: StremioManifest] = [:]
            for await (url, man) in group { if let man { out[url] = man } }
            return out
        }
        let feed = await board
        let fresh = feed.events
        if !feed.successfulLeagues.isEmpty {
            evaluateAlerts(previous: events, current: fresh)
            let refreshedLeagues = feed.successfulLeagues
            var seen = Set<String>()
            events = (fresh + events.filter { !refreshedLeagues.contains($0.league) && (settings.enabledLeagues.isEmpty || settings.enabledLeagues.contains($0.league)) }).filter { seen.insert($0.id).inserted }
            settings.savedEvents = settings.savedEvents.map { saved in events.first { $0.id == saved.id } ?? saved }
            scheduleStore.save(events)
            sportsStatus = "Live schedule · \(fresh.count) events"
        } else if events.isEmpty {
            // Offline/DNS outage: stale schedule beats an empty shelf.
            events = scheduleStore.loadAny() ?? []
            sportsStatus = events.isEmpty ? "Sports feed unavailable" : "Offline schedule · \(events.count) events"
        } else {
            sportsStatus = "Cached schedule · \(events.count) events"
        }
        lastSportsRefresh = Date()
        self.addonManifests = manifests
    }

    func refreshSchedule() async {
        guard !scheduleLoading else { return }
        scheduleLoading = true
        defer { scheduleLoading = false }
        if LaunchArgs.visualFixture { scheduleEvents = events; return }
        let fresh = await espn.fetchScheduleWindow()
        if !fresh.isEmpty { scheduleEvents = fresh; scheduleError = nil }
        else { scheduleError = "The schedule could not be refreshed. Try again." }
    }

    func refreshSavedEvents() async {
        let known = Set(events.map(\.id))
        let missing = settings.savedEvents.filter { !known.contains($0.id) }
        var fresh: [String: SportEvent] = [:]
        for offset in stride(from: 0, to: missing.count, by: 3) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: SportEvent?.self) { group in
                for event in missing[offset..<min(missing.count, offset + 3)] {
                    guard let path = EspnClient.path(forLeague: event.league) else { continue }
                    group.addTask { await self.espn.fetchSummary(sport: path.sport, league: path.path, eventId: event.id).event }
                }
                for await event in group { if let event { fresh[event.id] = event } }
            }
        }
        settings.savedEvents = settings.savedEvents.map { fresh[$0.id] ?? $0 }
    }

    let alertCenter = GameAlertCenter()

    /// Diff the refresh against the last snapshot and notify for favorites
    /// (Android GameAlertManager + HomeViewModel gate).
    private func evaluateAlerts(previous: [SportEvent], current: [SportEvent]) {
        guard settings.liveGameAlertsEnabled else { return }
        let favIds = Set(settings.favoriteTeamProfiles.map(\.key))
        guard !favIds.isEmpty || !settings.savedEventIds.isEmpty else { return }
        let alerts = GameAlerts.evaluate(previous: previous, current: current,
                                         favIds: favIds,
                                         redZoneEnabled: settings.redZoneAlertsEnabled, savedEventIds: settings.savedEventIds)
        alertCenter.deliver(alerts, events: current)
    }

    func testConnection() async {
        connectionStatus = "Testing…"
        let (s, x) = providers()
        let ok: Bool
        switch settings.iptvProvider {
        case .stalker: ok = await s.authenticate(force: true)
        case .xtream: ok = await x.authenticate()
        case .m3u: await refreshChannels(); ok = !channels.isEmpty
        }
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
        case "schedule": return .schedule
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
    static var streamURL: String? {
        CommandLine.arguments.first(where: { $0.hasPrefix("--stream=") }).map { String($0.dropFirst(9)) }
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
    /// Stable local data and reduced motion for visual regression captures.
    static var visualFixture: Bool {
        CommandLine.arguments.contains("--visual-fixture")
    }
    /// Deterministic launch geometry: `--window=compact|standard|wide`.
    static var windowSize: CGSize {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--window=") }) else {
            return CGSize(width: 1440, height: 900)
        }
        switch arg.dropFirst(9) {
        case "compact": return CGSize(width: 820, height: 600)
        case "wide": return CGSize(width: 1720, height: 1000)
        default: return CGSize(width: 1440, height: 900)
        }
    }
}
struct ContentView: View {
    @EnvironmentObject var store: RallyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var slideEdge: Edge = .trailing
    @State private var prevTab = 0
    @State private var showOnboarding = false
    @State private var lastInteraction = Date()
    @State private var saverNow = Date()
    @State private var windowActive = true
    private var idleDelay: TimeInterval {
        #if DEBUG
        if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--qa-idle-seconds=") }),
           let seconds = Double(raw.split(separator: "=").last ?? ""), seconds >= 1 { return seconds }
        #endif
        return 300
    }
    private func wake() { let now = Date(); lastInteraction = now; saverNow = now }
    /// Idle screensaver (5 min, suppressed while anything is presented).
    private var saverActive: Bool {
        store.settings.scoreSaverEnabled && !showOnboarding && store.sheet == nil
            && (!windowActive || scenePhase != .active || saverNow.timeIntervalSince(lastInteraction) >= idleDelay)
    }
    private func tabIndex(_ d: TvDestination) -> Int {
        switch d { case .home: 0; case .live: 1; case .schedule: 2; case .leagues: 3; case .highlights: 5; case .myTeams: 4 }
    }
    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                AmbientBackground()
                    .allowsHitTesting(false)
                if LaunchArgs.visualFixture || CommandLine.arguments.contains(where: { $0.hasPrefix("--window=") }) {
                    VisualWindowConfigurator(size: LaunchArgs.windowSize)
                        .frame(width: 0, height: 0)
                }
                VStack(spacing: 0) {
                    if !store.hasPlayer && !store.hasMultiView { RallyNavigation(store: store) }
                    ZStack {
                        Group {
                            switch store.destination {
                            case .home: HomeView()
                            case .live: LiveView()
                            case .schedule: ScheduleView()
                            case .leagues: TvLeaguesHome()
                            case .highlights: TvHighlights()
                            case .myTeams: TvMyTeams()
                            }
                        }.opacity(store.hasEventDetail ? 0 : 1).allowsHitTesting(!store.hasEventDetail).accessibilityHidden(store.hasEventDetail || store.hasPlayer)
                        if case .eventDetail(let event) = store.sheet {
                            TvEventDetail(event: event)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .topTrailing) {
                                    Button { store.show(nil) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).font(RallyFont.font(size: 16))
                                        .foregroundStyle(RallyTheme.textSecondary).padding(.trailing, 24).padding(.top, 14)
                                        .accessibilityLabel("Close event details")
                                }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.opacity(store.hasPlayer || store.hasMultiView ? 0 : 1).accessibilityHidden(store.hasPlayer || store.hasMultiView || saverActive).allowsHitTesting(!store.hasPlayer && !store.hasMultiView && !saverActive)
                if case .multiView = store.sheet {
                    MultiViewView(state: store.multiView).environmentObject(store).environmentObject(store.settings)
                }
                if case .player(let event, let channel, let clip, let picker, let source) = store.sheet {
                    PlayerView(event: event, channel: channel, clip: clip, startWithPicker: picker, source: source)
                        .environmentObject(store).environmentObject(store.settings).id(store.sheet?.id)
                }
                // First-run gate: onboarding until setup is saved or a source exists.
                if showOnboarding {
                    OnboardingView(onContinue: {
                        showOnboarding = false
                        store.show(.settings)
                    }, onBrowse: { showOnboarding = false; store.settings.setupComplete = true })
                }
                // Idle ambient scores sit above content, below sheets/player.
                if saverActive {
                    ScoreSaverOverlay()
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .zIndex(20)
                        .onTapGesture { wake() }
                }
            }
            .environment(\.tvMetrics, TvMetrics(width: geo.size.width, height: geo.size.height, largeText: store.settings.largeText))
            .environment(\.rallyHighContrast, store.settings.highContrastFocus)
            .environment(\.rallyReduceMotion, store.settings.reducedMotion || LaunchArgs.visualFixture)
            .environment(\.dynamicTypeSize, store.settings.largeText ? .accessibility1 : .large)
        }
    }
    private var lifecycleCanvas: some View {
        canvas
        .rallyAnimation(.easeOut(duration: 0.18), value: store.destination)
        .rallyAnimation(.easeOut(duration: 0.18), value: saverActive)
        .onChange(of: scenePhase) { phase in if phase == .active { wake() } }
        .onChange(of: store.destination) { next in
            slideEdge = tabIndex(next) >= prevTab ? .trailing : .leading
            prevTab = tabIndex(next)
            lastInteraction = Date()
        }
        .onChange(of: store.sheet?.id) { _ in lastInteraction = Date() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if !LaunchArgs.visualFixture {
                    await store.refresh()
                    if store.destination == .schedule { await store.refreshSchedule() }
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                saverNow = Date()
            }
        }
        .background(RallyTheme.deepNavy)
        .tint(.white)
    }
    var body: some View {
        lifecycleCanvas
        .background {
            if #available(macOS 14, *) { SettingsBridge() }
            else { LegacySettingsBridge() }
        }
        .background {
            #if DEBUG
            RallyAuditHost(info: { "destination=\(store.destination) sheet=\(store.sheet?.id ?? "none") idle=\(saverActive) key=\(windowActive)\n" + store.multiView.auditStatus }).frame(width: 0, height: 0)
            #endif
        }
        .background { RallyWindowAppearance().frame(width: 0, height: 0) }
        .background {
            RallyWindowActivity(sleeping: saverActive, activity: wake, keyChanged: { windowActive = $0 })
                .frame(width: 0, height: 0)
        }
        .background { RallyEscapeHandler(enabled: store.sheet != nil && !store.hasPlayer) { store.show(nil) }.frame(width: 0, height: 0) }
        .navigationTitle("Rally")
        .font(RallyFont.font(size: 14))
        .onExitCommand { store.show(nil) }
        .task { await configureLaunch() }
        .onReceive(NotificationCenter.default.publisher(for: GameAlertCenter.openEventNotification), perform: openAlertEvent)
        .onOpenURL { handleURL($0) }
        .sheet(item: Binding<AppSheet?>(
            get: {
                guard let s = store.sheet else { return nil }
                if case .player = s { return nil } // fullscreen branch owns player
                if case .multiView = s { return nil }
                if case .eventDetail = s { return nil } // in-window modal owns details
                return s
            },
            set: { store.sheet = $0 }
        )) { sheet in
            Group {
                switch sheet {
                case .eventDetail:
                    EmptyView()
                case .team(let team):
                    TvTeamHub(team: team).frame(minWidth: 740, minHeight: 520)
                case .player:
                    EmptyView()
                case .multiView:
                    MultiViewView(state: store.multiView).frame(minWidth: 740, minHeight: 520)
                case .search:
                    SearchView().frame(minWidth: 700, minHeight: 500)
                case .settings:
                    SettingsView().frame(minWidth: 760, minHeight: 550)
                }
            }
            .environmentObject(store)
            .environmentObject(store.settings)
        }
    }
    private func openAlertEvent(_ note: Notification) {
        guard let id = note.object as? String, let event = store.events.first(where: { $0.id == id }) else { return }
        store.show(AppSheet.eventDetail(event))
    }
    @MainActor private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "rally" else { return }
        guard let key = url.pathComponents.first(where: { $0 != "/" }) else { return }
        if url.host?.lowercased() == "event" {
            if let event = store.events.first(where: { $0.id == key }) { store.show(.eventDetail(event)) }
        } else if url.host?.lowercased() == "team" {
            for team in store.settings.favoriteTeamProfiles where team.key == key {
                store.show(.team(team)); break
            }
        }
    }
    @MainActor private func configureLaunch() async {
            showOnboarding = !LaunchArgs.visualFixture && !LaunchArgs.skipOnboarding && store.settings.needsOnboarding
            if !LaunchArgs.visualFixture {
                store.alertCenter.requestAuthorization()
                await store.refresh()
                await store.checkUpdates()
            }
            if let league = LaunchArgs.league { store.pendingLeague = league }
            if LaunchArgs.openSettings { openSettings() }
            var launchEvent: SportEvent?
            if let id = LaunchArgs.eventId {
                launchEvent = store.events.first { $0.id == id }
                if launchEvent == nil, let league = LaunchArgs.league, let path = EspnClient.path(forLeague: league) {
                    launchEvent = await store.espnClient.fetchSummary(sport: path.sport, league: path.path, eventId: id).event
                }
                if launchEvent == nil { launchEvent = store.featuredEvent }
            }
            if let url = LaunchArgs.streamURL, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? "") {
                let selectedEvent: SportEvent? = launchEvent
                let candidate = PlayCandidate(title: "Playback Verification", url: url, kind: .stremio, exactMatch: true, rank: 0)
                store.show(.player(event: selectedEvent, channel: nil, source: candidate))
            } else if let event = launchEvent {
                store.show(.eventDetail(event))
            } else if let id = LaunchArgs.playId {
                if let e = store.events.first(where: { $0.id == id }) { store.show(.player(event: e, channel: nil)) }
                else if let e = store.featuredEvent { store.show(.player(event: e, channel: nil)) }
            }
            #if DEBUG
            if LaunchArgs.visualFixture && CommandLine.arguments.contains("--qa-multiview"), let url = LaunchArgs.streamURL {
                for index in 1...3 {
                    let separator = url.contains("?") ? "&" : "?"
                    let candidate = PlayCandidate(title: "Reference Stream \(index)", url: url + separator + "rallyQA=\(index)", kind: .stremio, exactMatch: true, rank: index)
                    store.multiView.add(candidate: candidate, event: launchEvent)
                }
                store.multiView.addStats()
                store.show(.multiView)
            }
            #endif
            if let key = LaunchArgs.teamKey,
               let team = store.settings.favoriteTeamProfiles.first(where: { $0.key == key }) {
                store.show(.team(team))
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
                Text(event.league).font(.caption.bold()).foregroundStyle(RallyTheme.textPrimary)
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
        HStack(spacing: 6) {
            if [.live, .halftime].contains(status) { Circle().fill(RallyTheme.liveRed).frame(width: 6, height: 6) }
            Text(label).font(RallyFont.font(size: 11, weight: .semibold)).fixedSize()
        }.foregroundStyle([.live, .halftime].contains(status) ? RallyTheme.liveRed : RallyTheme.textSecondary)
    }
    private var label: String {
        switch status { case .live: "LIVE"; case .halftime: "HALF"; case .finished: "FINAL"; case .notStarted: "UPCOMING"; case .delayed: "DELAYED"; case .canceled: "CANCELED" }
    }
    private var color: Color {
        switch status { case .live, .halftime: RallyTheme.liveRed; case .finished: RallyTheme.textTertiary; default: RallyTheme.textSecondary }
    }
}
