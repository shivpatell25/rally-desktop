import AppKit
import RallyCore
import SwiftUI
import UniformTypeIdentifiers

struct PersonalizationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
/// TV-glass settings: icon rail with status badges, identity header,
/// provider cards, addon cards with live metadata, descriptive toggles.
struct SettingsView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var newAddon = ""
    @State private var section = 0
    @State private var testing = false
    @State private var exportingBackup = false
    @State private var importingBackup = false
    @State private var backupMessage: String?
    @State private var catalogLeague = "NFL"
    @State private var catalogTeams: [Team] = []
    @State private var catalogFilter = ""
    @State private var catalogLoading = false
    // Sources drafts: nothing persists until Save validates (Android saveConfiguration).
    @State private var draftProvider: IptvProvider = .stalker
    @State private var draftPortal = ""
    @State private var draftMac = ""
    @State private var draftSerial = ""
    @State private var draftDevice = ""
    @State private var draftServer = ""
    @State private var draftUser = ""
    @State private var draftPlaylist = ""
    @State private var draftPlaylistName = ""
    @State private var draftPass = ""
    @State private var draftAddons: [String] = []
    @State private var draftsSynced = false
    @State private var configurationError: String?
    @State private var savedNote = false

    private let sections = ["Sources", "Addons", "Sports", "My Rally", "Alerts", "Viewing", "Support"]
    private let icons = ["antenna.radiowaves.left.and.right", "trophy", "star", "bell", "play.tv", "info.circle"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 20) {
                if let logo = tvArt("rally_wordmark") { Image(nsImage: logo).resizable().scaledToFit().frame(width: 112, height: 38) }
                Text("Settings").font(RallyFont.display(28))
                Spacer()
            }
            RallyTabs(items: sections.enumerated().map { ($0.element, $0.offset) }, selection: $section)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case 0: sourcesPanel
                    case 1: addonsPanel
                    case 2: sportsPanel
                    case 3: teamsPanel
                    case 4: alertsPanel
                    case 5: viewingPanel
                    default: supportPanel
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
            }
        }
        .padding(30).frame(minWidth: 740, minHeight: 540)
        .background { AmbientBackground() }.foregroundStyle(RallyTheme.textPrimary)
        .font(RallyFont.font(size: 14)).navigationTitle("Settings")
    }

    @ViewBuilder
    private func railBadge(_ i: Int) -> some View {
        switch i {
        case 0:
            if !(store.connectionStatus ?? "").isEmpty && store.connectionStatus != "Connected" {
                Circle().fill(RallyTheme.liveRed).frame(width: 8, height: 8)
            } else if !store.channels.isEmpty {
                Text("\(store.channels.count)").font(RallyFont.font(size: 11, weight: .bold))
                    .foregroundStyle(RallyTheme.textPrimary)
            }
        case 2:
            if !settings.favoriteTeamProfiles.isEmpty {
                Text("\(settings.favoriteTeamProfiles.count)").font(RallyFont.font(size: 11, weight: .bold))
                    .foregroundStyle(RallyTheme.textPrimary)
            }
        case 5:
            if store.update != nil {
                Circle().fill(RallyTheme.textPrimary).frame(width: 8, height: 8)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Panels

    private var sourcesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("SOURCES", "IPTV providers")
            if let message = settings.credentialError { Text(message).font(.callout).foregroundStyle(RallyTheme.liveRed) }
            HStack(spacing: 12) {
                providerCard(title: "Stalker / Ministra", desc: "Portal + MAC", provider: .stalker)
                providerCard(title: "Xtream Codes", desc: "Server + login", provider: .xtream)
                providerCard(title: "M3U Playlist", desc: "URL or file", provider: .m3u)
            }
            glassCard {
                if draftProvider == .stalker {
                    settingsField("Portal URL", text: $draftPortal)
                    settingsField("MAC address", text: $draftMac, mono: true)
                    settingsField("Serial (optional)", text: $draftSerial)
                    settingsField("Device ID (optional)", text: $draftDevice)
                } else if draftProvider == .m3u {
                    settingsField("Playlist URL", text: $draftPlaylist)
                    settingsField("Playlist name", text: $draftPlaylistName)
                    Button("Choose playlist file…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { draftPlaylist = url.absoluteString }
                    }
                } else {
                    settingsField("Server URL", text: $draftServer)
                    settingsField("Username", text: $draftUser)
                    HStack {
                        Text("Password").frame(width: 150, alignment: .leading)
                        SecureField("Required", text: $draftPass)
                    }
                    .font(RallyFont.font(size: 14))
                }
            }
            glassCard {
                HStack(spacing: 10) {
                    tvButton("Save and Apply", primary: true) { saveDrafts() }
                    if savedNote {
                        statusPill("Saved", good: true)
                    } else if let error = configurationError {
                        Text(error).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.liveRed)
                            .lineLimit(2).frame(maxWidth: 420, alignment: .leading)
                    } else {
                        Text("Edits stay here until saved — nothing persists until validation passes.")
                            .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textTertiary)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                }
            }
            glassCard {
                HStack(spacing: 10) {
                    tvButton("Test connection", primary: true) {
                        testing = true
                        Task {
                            await store.testConnection()
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if testing { ProgressView().scaleEffect(0.7) }
                    tvButton("Load channels") { Task { await store.refreshChannels() } }
                    if let status = store.connectionStatus {
                        statusPill(status, good: status == "Connected")
                    }
                    Spacer()
                    Text("\(store.channels.count) channels").font(RallyFont.font(size: 12))
                        .foregroundStyle(RallyTheme.textSecondary)
                }
            }

        }
        .onAppear { if !draftsSynced { syncDrafts() } }
    }

    private var addonsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            panelTitle("ADDONS", "Installed stream sources")
            glassCard {
                Text("STREMIO ADDONS").font(RallyFont.font(size: 11, weight: .bold)).tracking(1)
                    .foregroundStyle(RallyTheme.textSecondary)
                ForEach(draftAddons, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(systemName: "globe").font(RallyFont.font(size: 16))
                            .foregroundStyle(RallyTheme.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.addonManifests[url]?.name ?? host(of: url))
                                .font(RallyFont.font(size: 13, weight: .semibold)).lineLimit(1)
                            Text(versionLine(for: url))
                                .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        if store.addonManifests[url] != nil {
                            Circle().fill(RallyTheme.textPrimary).frame(width: 8, height: 8)
                        }
                        Button("Remove") { removeAddon(url) }.font(RallyFont.font(size: 12))
                    }
                    Divider().opacity(0.2)
                }
                HStack {
                    TextField("Add addon manifest URL", text: $newAddon)
                        .textFieldStyle(.roundedBorder)
                    tvButton("Add") {
                        let clean = newAddon.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty, UrlNormalizer.normalizeAddon(clean) != nil,
                           !draftAddons.contains(clean) {
                            draftAddons.append(clean)
                            newAddon = ""
                            configurationError = nil
                            savedNote = false
                        }
                    }
                }
                Text("HTTP portals work for legacy providers but can be intercepted — prefer HTTPS.")
                    .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textTertiary)
            }
            tvButton("Save and Apply", primary: true) { saveDrafts() }
            if let error = configurationError { Text(error).foregroundStyle(RallyTheme.liveRed) }
            if savedNote { Text("Saved").foregroundStyle(RallyTheme.textPrimary) }
        }.onAppear { if !draftsSynced { syncDrafts() } }
    }

    /// Copies saved settings into the drafts (fresh panel, or after save).
    private func syncDrafts() {
        draftPlaylist = settings.m3uPlaylistUrl
        draftPlaylistName = settings.m3uPlaylistName
        draftProvider = settings.iptvProvider
        draftPortal = settings.portalUrl
        draftMac = settings.macAddress
        draftSerial = settings.serialNumber
        draftDevice = settings.deviceId
        draftServer = settings.xtreamServerUrl
        draftUser = settings.xtreamUsername
        draftPass = settings.iptvProvider == .xtream ? settings.xtreamPassword : ""
        draftAddons = settings.stremioAddonUrls
        draftsSynced = true
        configurationError = nil
        savedNote = false
    }

    /// Validates, persists, invalidates the old session, and marks setup done.
    private func saveDrafts() {
        if let error = SettingsValidator.validate(provider: draftProvider, portal: draftPortal, mac: draftMac,
                                                  server: draftServer, user: draftUser, pass: draftPass,
                                                  addons: draftAddons, playlist: draftPlaylist) {
            configurationError = error
            savedNote = false
            return
        }
        settings.m3uPlaylistUrl = draftPlaylist
        settings.m3uPlaylistName = draftPlaylistName
        settings.iptvProvider = draftProvider
        settings.portalUrl = draftPortal
        settings.macAddress = draftMac
        settings.serialNumber = draftSerial
        settings.deviceId = draftDevice
        settings.xtreamServerUrl = draftServer
        settings.xtreamUsername = draftUser
        if draftProvider == .xtream {
            settings.xtreamPassword = draftPass
            if let error = settings.credentialError { configurationError = error; savedNote = false; return }
        }
        settings.stremioAddonUrls = draftAddons
        store.resetProviderSession()
        settings.setupComplete = true
        configurationError = nil
        savedNote = true
        Task { await store.refresh() }
    }

    private func providerCard(title: String, desc: String, provider: IptvProvider) -> some View {
        let selected = draftProvider == provider
        return Button {
            if provider == .xtream && draftPass.isEmpty { draftPass = settings.xtreamPassword }
            draftProvider = provider
            configurationError = nil
            savedNote = false
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(RallyFont.font(size: 14, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(RallyTheme.textPrimary)
                    }
                }
                Text(desc).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                if selected {
                    if provider == .stalker {
                        Text(settings.portalUrl.isEmpty ? "Not configured" : settings.portalUrl)
                            .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                    } else if provider == .m3u {
                        Text(settings.m3uPlaylistUrl.isEmpty ? "Not configured" : (settings.m3uPlaylistName.isEmpty ? "Configured playlist" : settings.m3uPlaylistName))
                            .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                    } else {
                        Text(settings.xtreamServerUrl.isEmpty ? "Not configured" : settings.xtreamServerUrl)
                            .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.white.opacity(0.1) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.white.opacity(0.55) : RallyTheme.glassBorder, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    private func host(of url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    private func versionLine(for url: String) -> String {
        if let man = store.addonManifests[url] {
            return "v\(man.version ?? "?") · \(man.catalogs?.count ?? 0) catalogs"
        }
        return url
    }

    private var sportsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("SPORTS", "Leagues and order")
            if settings.enabledLeagues.isEmpty {
                Text("All leagues enabled").font(RallyFont.font(size: 12))
                    .foregroundStyle(RallyTheme.textSecondary)
            }
            glassCard {
                ForEach(Array(settings.sportsOrder.enumerated()), id: \.element) { index, league in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(league).font(RallyFont.font(size: 14, weight: .semibold))
                            Text(settings.favoriteSports.contains(league) ? "Favorite · \(settings.isLeagueEnabled(league) ? "Shown" : "Hidden")"
                                : (settings.isLeagueEnabled(league) ? "Shown" : "Hidden"))
                                .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                        }
                        Spacer()
                        Button(settings.favoriteSports.contains(league) ? "★" : "☆") {
                            settings.toggleFavoriteSport(league)
                        }.font(RallyFont.font(size: 15)).buttonStyle(.plain)
                        Toggle("", isOn: Binding(
                            get: { settings.isLeagueEnabled(league) },
                            set: { _ in settings.toggleLeague(league) }
                        )).labelsHidden().scaleEffect(0.85)
                        Button("↑") { settings.moveSportUp(league) }
                            .disabled(index == 0).font(RallyFont.font(size: 13)).buttonStyle(.plain)
                            .foregroundStyle(index == 0 ? RallyTheme.textTertiary : RallyTheme.textPrimary)
                        Button("↓") { settings.moveSportDown(league) }
                            .disabled(index == settings.sportsOrder.count - 1)
                            .font(RallyFont.font(size: 13)).buttonStyle(.plain)
                            .foregroundStyle(index == settings.sportsOrder.count - 1 ? RallyTheme.textTertiary : RallyTheme.textPrimary)
                    }
                    Divider().opacity(0.2)
                }
            }
        }
    }

    private var teamsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("TEAMS", "Favorite clubs")
            glassCard {
                if settings.favoriteTeamProfiles.isEmpty {
                    Text("No favorites yet. Star teams from event rows to build Up Next.")
                        .font(RallyFont.font(size: 13)).foregroundStyle(RallyTheme.textSecondary)
                }
                ForEach(settings.favoriteTeamProfiles) { team in
                    HStack(spacing: 10) {
                        if let logo = team.logoUrl, let link = URL(string: logo) {
                            AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                                Text(team.abbreviation).font(RallyFont.font(size: 10, weight: .bold)).foregroundStyle(.white)
                            }
                            .frame(width: 30, height: 30)
                        } else {
                            Text(team.abbreviation).font(RallyFont.font(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(team.name).font(RallyFont.font(size: 14, weight: .semibold))
                            Text(team.league).font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                        }
                        Spacer()
                        Button("Remove") { _ = settings.toggleFavoriteTeam(team) }.font(RallyFont.font(size: 12))
                    }
                    Divider().opacity(0.2)
                }
            }
            glassCard {
                Text("ADD TEAMS").font(RallyFont.font(size: 11, weight: .bold)).tracking(1)
                    .foregroundStyle(RallyTheme.textSecondary)
                Text("Pick a league to browse its clubs. Tapping a starred team removes it.")
                    .font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                Picker("League", selection: $catalogLeague) {
                    ForEach(EspnClient.leagues.map(\.league), id: \.self) { league in
                        Text(league).tag(league)
                    }
                }
                .frame(maxWidth: 260)
                .task(id: catalogLeague) { await loadCatalog() }
                TextField("Filter teams", text: $catalogFilter)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                if catalogLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(filteredCatalog) { team in
                    HStack(spacing: 10) {
                        if let logo = team.logoUrl, let link = URL(string: logo) {
                            AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                                Color.clear
                            }
                            .frame(width: 30, height: 30)
                        }
                        Text(team.name).font(RallyFont.font(size: 14, weight: .semibold))
                        Spacer()
                        let fav = FavoriteTeam(id: team.id, league: catalogLeague, name: team.name,
                                               abbreviation: team.abbreviation, logoUrl: team.logoUrl)
                        Button(settings.isFavoriteTeam(id: team.id, league: catalogLeague) ? "★" : "☆") {
                            _ = settings.toggleFavoriteTeam(fav)
                        }.font(RallyFont.font(size: 16)).buttonStyle(.plain)
                    }
                    Divider().opacity(0.2)
                }
            }
        }
        .task { await loadCatalog() }
    }

    private var filteredCatalog: [Team] {
        guard !catalogFilter.isEmpty else { return catalogTeams }
        let q = catalogFilter.lowercased()
        return catalogTeams.filter { $0.name.lowercased().contains(q) || $0.abbreviation.lowercased().contains(q) }
    }

    private func loadCatalog() async {
        guard let path = EspnClient.path(forLeague: catalogLeague) else { catalogTeams = []; return }
        catalogLoading = true
        defer { catalogLoading = false }
        catalogTeams = await store.espnClient.fetchTeams(sport: path.sport, league: path.path)
    }
    private var alertsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("ALERTS", "Live notifications")
            glassCard {
                toggleRow("Live game alerts", "Kickoff, scores and finals", $settings.liveGameAlertsEnabled)
                Divider().opacity(0.2)
                toggleRow("NFL RedZone alerts", "Every touchdown channel", $settings.redZoneAlertsEnabled)
            }
        }
    }

    private var viewingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("VIEWING", "Playback and access")
            glassCard {
                toggleRow("Low latency mode", "Closer to the live edge", $settings.lowLatencyMode)
                Divider().opacity(0.2)
                toggleRow("Audio normalization", "Even out loud compatibility broadcasts", $settings.audioNormalizationEnabled)
                Divider().opacity(0.2)
                toggleRow("Adaptive quality", "Adjust to your connection", $settings.adaptiveQualityEnabled)
                Divider().opacity(0.2)
                toggleRow("Reduce motion", "Calm focus and transitions", $settings.reducedMotion)
                Divider().opacity(0.2)
                toggleRow("Large text", "Bigger scores and titles", $settings.largeText)
                Divider().opacity(0.2)
                toggleRow("High-contrast focus", "Brighter, thicker selection rings", $settings.highContrastFocus)
                Divider().opacity(0.2)
                toggleRow("Spoken score summaries", "Announce live scores on Home", $settings.spokenScoreSummaries)
                Divider().opacity(0.2)
                toggleRow("Score saver", "Ambient scores after 5 idle minutes", $settings.scoreSaverEnabled)
            }
        }
    }

    private var supportPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("SUPPORT", "About and diagnostics")
            glassCard {
                HStack(spacing: 12) {
                    if let mark = tvArt("rally_mark_ui") {
                        Image(nsImage: mark).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rally for macOS").font(RallyFont.font(size: 15, weight: .bold)).foregroundStyle(.white)
                        Text("com.shiv.rally.macos").font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    if store.checkingUpdates {
                        ProgressView().scaleEffect(0.7)
                        Text("Checking…").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                    } else if let rel = store.update {
                        VStack(alignment: .trailing, spacing: 2) {
                            tvButton("Download v\(rel.tag)", primary: true) {
                                if let url = URL(string: rel.assetUrl) { NSWorkspace.shared.open(url) }
                            }
                            Text(formatBytes(rel.assetSize)).font(RallyFont.font(size: 10))
                                .foregroundStyle(RallyTheme.textTertiary)
                        }
                        if !rel.notes.isEmpty {
                            Text(String(rel.notes.prefix(180))).font(RallyFont.font(size: 11))
                                .foregroundStyle(RallyTheme.textSecondary).lineLimit(3)
                                .frame(maxWidth: 300, alignment: .trailing)
                        }
                    } else if let error = store.updateError {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(error).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.liveRed)
                                .frame(maxWidth: 300, alignment: .trailing)
                            tvButton("Retry") { Task { await store.checkUpdates(force: true) } }
                        }
                    } else {
                        if store.updateChecked {
                            Text("You're up to date").font(RallyFont.font(size: 12))
                                .foregroundStyle(RallyTheme.textSecondary)
                        }
                        tvButton("Check for updates") { Task { await store.checkUpdates(force: true) } }
                    }
                }
            }
            glassCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic updates").font(RallyFont.font(size: 14, weight: .semibold))
                        Text("Sparkle feed — installs staged releases in-app")
                            .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    tvButton("Check now", primary: true) { store.sparkle.checkForUpdates() }
                        .disabled(!store.sparkle.canCheckForUpdates)
                }
            }
            glassCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sports data").font(RallyFont.font(size: 14, weight: .semibold))
                        Text(store.sportsStatus)
                            .font(RallyFont.font(size: 12))
                            .foregroundStyle(store.sportsStatus.contains("unavailable")
                                ? RallyTheme.liveRed : RallyTheme.textSecondary)
                        if let refreshed = store.lastSportsRefresh {
                            Text("Last checked \(refreshed.formatted(.relative(presentation: .named)))")
                                .font(RallyFont.font(size: 11))
                                .foregroundStyle(RallyTheme.textTertiary)
                        }
                    }
                    Spacer()
                    if store.isLoading { ProgressView().scaleEffect(0.7) }
                    tvButton("Refresh now") { Task { await store.refresh() } }
                        .disabled(store.isLoading)
                }
            }
            glassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Credentials on this Mac").font(RallyFont.font(size: 14, weight: .semibold))
                        Text("Portal, server, MAC, and tokens — favorites and prefs survive")
                            .font(RallyFont.font(size: 11))
                            .foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    tvButton("Clear credentials", destructive: true) { store.settings.clearCredentials() }
                }
            }
            glassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PERSONALIZATION").font(RallyFont.font(size: 11, weight: .bold)).tracking(1)
                        .foregroundStyle(RallyTheme.textSecondary)
                    Text("Leagues, favorites, alerts, playback, and access — never credentials or addons.")
                        .font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                    HStack(spacing: 10) {
                        tvButton("Export…") { exportingBackup = true }
                        tvButton("Import…") { importingBackup = true }
                        tvButton("Copy support report") { copySupportReport() }
                    }
                    if let backupMessage {
                        Text(backupMessage).font(RallyFont.font(size: 12))
                            .foregroundStyle(RallyTheme.textSecondary)
                    }
                }
            }
        }
        .fileExporter(isPresented: $exportingBackup, document: backupDocument(), contentType: .json,
                      defaultFilename: "rally-personalization.json") { result in
            backupMessage = (try? result.get()) != nil ? "Exported." : "Export cancelled."
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else { backupMessage = "Couldn't read that file."; return }
                defer { url.stopAccessingSecurityScopedResource() }
                backupMessage = store.settings.importPersonalization(try Data(contentsOf: url))
                    ? "Imported — your leagues, teams, and prefs are restored."
                    : "That file isn't Rally personalization."
            } catch {
                backupMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func backupDocument() -> PersonalizationDocument {
        PersonalizationDocument(data: store.settings.exportPersonalization() ?? Data())
    }

    /// Scrubbed report: versions and counts only, never URLs, tokens, or MACs.
    private func copySupportReport() {
        let s = store.settings
        let lines = [
            "Rally for macOS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")",
            "Provider: \(s.iptvProvider) configured=\(!s.portalUrl.isEmpty || !s.xtreamServerUrl.isEmpty)",
            "Events: \(store.events.count) · Channels: \(store.channels.count) · Addons: \(s.stremioAddonUrls.count)",
            "Sports: \(store.sportsStatus) lastRefresh=\(store.lastSportsRefresh?.ISO8601Format() ?? "never")",
            "Leagues: \(s.sportsOrder.joined(separator: ","))",
            "Favorites: \(s.favoriteTeamProfiles.count) teams",
            "Alerts: live=\(s.liveGameAlertsEnabled) redzone=\(s.redZoneAlertsEnabled)",
            "Viewing: latency=\(s.lowLatencyMode) norm=\(s.audioNormalizationEnabled) adaptive=\(s.adaptiveQualityEnabled)",
            "Access: motion=\(s.reducedMotion) large=\(s.largeText) contrast=\(s.highContrastFocus) spoken=\(s.spokenScoreSummaries)",
            "Update: \(store.update?.tag ?? "up-to-date")\(store.updateError.map { " error=\($0)" } ?? "")",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        backupMessage = "Support report copied — paste it anywhere."
    }

    // MARK: Chrome (TV glass language)

    private func panelTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(RallyFont.font(size: 15, weight: .bold)).tracking(1.6).foregroundStyle(.white)
            Text(subtitle).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary)
        }
    }

    private func glassCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tvButton(_ label: String, primary: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(RallyFont.font(size: 14, weight: .semibold))
                .foregroundStyle(destructive ? RallyTheme.liveRed : primary ? Color.black : RallyTheme.textPrimary)
                .padding(.horizontal, 20).padding(.vertical, 9)
                .background(destructive ? Color.white.opacity(0.06) : primary ? RallyTheme.offWhite : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(RallyFont.font(size: 14))
                Text(subtitle).font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
            }
        }
    }

    private func settingsField(_ label: String, text: Binding<String>, mono: Bool = false) -> some View {
        HStack {
            Text(label).font(RallyFont.font(size: 14)).frame(width: 150, alignment: .leading)
            TextField(label.contains("optional") ? "Optional" : "Required", text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .body.monospaced() : .body)
        }
    }

    private func statusPill(_ text: String, good: Bool) -> some View {
        Text(text).font(RallyFont.font(size: 11, weight: .bold))
            .foregroundStyle(good ? RallyTheme.textPrimary : RallyTheme.liveRed)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
    }

    private func removeAddon(_ url: String) {
        draftAddons.removeAll { $0 == url }
        configurationError = nil
        savedNote = false
    }
}
