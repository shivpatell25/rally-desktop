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
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class RallyStore: ObservableObject {
    @Published var events: [SportEvent] = []
    @Published var isLoading = false
    @Published var addonManifest: StremioManifest?
    @Published var update: RallyRelease?
    @AppStorage("addonUrl") var addonUrl = "https://sports.highfly.to/manifest.json"

    private let espn = EspnClient()
    private let stremio = StremioClient()
    private let updates = UpdateChecker()

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        async let board = espn.fetchAllLeagues()
        async let manifest: StremioManifest? = { try? await stremio.fetchManifest(from: addonUrl) }()
        let (events, man) = await (board, manifest)
        self.events = events
        self.addonManifest = man
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
            List {
                Section("Browse") {
                    Label("Home", systemImage: "house").tag(0)
                    Label("Leagues", systemImage: "trophy").tag(1)
                    Label("Search", systemImage: "magnifyingglass").tag(2)
                    Label("Settings", systemImage: "gear").tag(3)
                }
                if let man = store.addonManifest {
                    Section("Addon") {
                        Text(man.name ?? "Stremio").font(.headline)
                        Text("v\(man.version ?? "?")").font(.caption).foregroundStyle(RallyTheme.textTertiary)
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
            HomeView()
        }
        .background(RallyTheme.background)
        .task { await store.refresh(); await store.checkUpdates() }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: RallyStore
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                ForEach(store.events.prefix(60)) { event in
                    GameCard(event: event)
                }
            }
            .padding(20)
        }
        .background(RallyTheme.background)
        .overlay { if store.isLoading && store.events.isEmpty { ProgressView("Loading games…") } }
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
