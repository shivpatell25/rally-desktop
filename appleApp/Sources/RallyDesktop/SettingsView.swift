import RallyCore
import SwiftUI

/// TV-glass settings: icon rail with status badges, identity header,
/// provider cards, addon cards with live metadata, descriptive toggles.
struct SettingsView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var newAddon = ""
    @State private var section = 0
    @State private var testing = false
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
    @State private var draftPass = ""
    @State private var draftAddons: [String] = []
    @State private var draftsSynced = false
    @State private var configurationError: String?
    @State private var savedNote = false

    private let sections = ["Sources", "Sports", "Teams", "Alerts", "Viewing", "Support"]
    private let icons = ["antenna.radiowaves.left.and.right", "trophy", "star", "bell", "play.tv", "info.circle"]

    var body: some View {
        HSplitView {
            List(selection: $section) {
                ForEach(sections.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        Label(sections[i], systemImage: icons[i])
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        railBadge(i)
                    }
                    .tag(i)
                }
            }
            .frame(minWidth: 210, maxWidth: 250)
            .background(RallyTheme.surfaceBase)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case 0: sourcesPanel
                    case 1: sportsPanel
                    case 2: teamsPanel
                    case 3: alertsPanel
                    case 4: viewingPanel
                    default: supportPanel
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 500)
        }
        .background { AmbientBackground() }
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private func railBadge(_ i: Int) -> some View {
        switch i {
        case 0:
            if !(store.connectionStatus ?? "").isEmpty && store.connectionStatus != "Connected" {
                Circle().fill(RallyTheme.liveRed).frame(width: 8, height: 8)
            } else if !store.channels.isEmpty {
                Text("\(store.channels.count)").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RallyTheme.rallyLime)
            }
        case 2:
            if !settings.favoriteTeamProfiles.isEmpty {
                Text("\(settings.favoriteTeamProfiles.count)").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RallyTheme.rallyCyan)
            }
        case 5:
            if store.update != nil {
                Circle().fill(RallyTheme.rallyLime).frame(width: 8, height: 8)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Panels

    private var sourcesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("SOURCES", "IPTV and addons")
            HStack(spacing: 12) {
                providerCard(title: "Stalker / Ministra", desc: "Portal + MAC", provider: .stalker)
                providerCard(title: "Xtream Codes", desc: "Server + login", provider: .xtream)
            }
            glassCard {
                if draftProvider == .stalker {
                    settingsField("Portal URL", text: $draftPortal)
                    settingsField("MAC address", text: $draftMac, mono: true)
                    settingsField("Serial (optional)", text: $draftSerial)
                    settingsField("Device ID (optional)", text: $draftDevice)
                } else {
                    settingsField("Server URL", text: $draftServer)
                    settingsField("Username", text: $draftUser)
                    HStack {
                        Text("Password").frame(width: 150, alignment: .leading)
                        SecureField("Required", text: $draftPass)
                    }
                    .font(.system(size: 14))
                }
            }
            glassCard {
                HStack(spacing: 10) {
                    tvButton("Save and Apply", primary: true) { saveDrafts() }
                    if savedNote {
                        statusPill("Saved", good: true)
                    } else if let error = configurationError {
                        Text(error).font(.system(size: 12)).foregroundStyle(RallyTheme.liveRed)
                            .lineLimit(2).frame(maxWidth: 420, alignment: .leading)
                    } else {
                        Text("Edits stay here until saved — nothing persists until validation passes.")
                            .font(.system(size: 11)).foregroundStyle(RallyTheme.textTertiary)
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
                    Text("\(store.channels.count) channels").font(.system(size: 12))
                        .foregroundStyle(RallyTheme.textSecondary)
                }
            }
            glassCard {
                Text("STREMIO ADDONS").font(.system(size: 11, weight: .bold)).tracking(1)
                    .foregroundStyle(RallyTheme.textSecondary)
                ForEach(draftAddons, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(systemName: "globe").font(.system(size: 16))
                            .foregroundStyle(RallyTheme.rallyCyan)
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.addonManifests[url]?.name ?? host(of: url))
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(versionLine(for: url))
                                .font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        if store.addonManifests[url] != nil {
                            Circle().fill(RallyTheme.rallyLime).frame(width: 8, height: 8)
                        }
                        Button("Remove") { removeAddon(url) }.font(.system(size: 12))
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
                    .font(.system(size: 11)).foregroundStyle(RallyTheme.textTertiary)
            }
        }
        .onAppear { syncDrafts() }
    }

    /// Copies saved settings into the drafts (fresh panel, or after save).
    private func syncDrafts() {
        draftProvider = settings.iptvProvider
        draftPortal = settings.portalUrl
        draftMac = settings.macAddress
        draftSerial = settings.serialNumber
        draftDevice = settings.deviceId
        draftServer = settings.xtreamServerUrl
        draftUser = settings.xtreamUsername
        draftPass = settings.xtreamPassword
        draftAddons = settings.stremioAddonUrls
        draftsSynced = true
        configurationError = nil
        savedNote = false
    }

    /// Validates, persists, invalidates the old session, and marks setup done.
    private func saveDrafts() {
        if let error = SettingsValidator.validate(provider: draftProvider, portal: draftPortal, mac: draftMac,
                                                  server: draftServer, user: draftUser, pass: draftPass,
                                                  addons: draftAddons) {
            configurationError = error
            savedNote = false
            return
        }
        settings.iptvProvider = draftProvider
        settings.portalUrl = draftPortal
        settings.macAddress = draftMac
        settings.serialNumber = draftSerial
        settings.deviceId = draftDevice
        settings.xtreamServerUrl = draftServer
        settings.xtreamUsername = draftUser
        settings.xtreamPassword = draftPass
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
            draftProvider = provider
            configurationError = nil
            savedNote = false
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(RallyTheme.rallyLime)
                    }
                }
                Text(desc).font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                if selected {
                    if provider == .stalker {
                        Text(settings.portalUrl.isEmpty ? "Not configured" : settings.portalUrl)
                            .font(.system(size: 11)).foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                    } else {
                        Text(settings.xtreamServerUrl.isEmpty ? "Not configured" : settings.xtreamServerUrl)
                            .font(.system(size: 11)).foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.white.opacity(0.1) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? RallyTheme.rallyCyan : RallyTheme.glassBorder, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func host(of url: String) -> String {
        URL(string: url)?.host ?? url
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
            glassCard {
                Text("LEAGUE ORDER").font(.system(size: 11, weight: .bold)).tracking(1)
                    .foregroundStyle(RallyTheme.textSecondary)
                Text(settings.sportsOrder.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary)
            }
        }
    }

    private var teamsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("TEAMS", "Favorite clubs")
            glassCard {
                if settings.favoriteTeamProfiles.isEmpty {
                    Text("No favorites yet. Star teams from event rows to build Up Next.")
                        .font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary)
                }
                ForEach(settings.favoriteTeamProfiles) { team in
                    HStack(spacing: 10) {
                        if let logo = team.logoUrl, let link = URL(string: logo) {
                            AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                                Text(team.abbreviation).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            }
                            .frame(width: 30, height: 30)
                        } else {
                            Text(team.abbreviation).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(team.name).font(.system(size: 14, weight: .semibold))
                            Text(team.league).font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                        }
                        Spacer()
                        Button("Remove") { _ = settings.toggleFavoriteTeam(team) }.font(.system(size: 12))
                    }
                    Divider().opacity(0.2)
                }
            }
            glassCard {
                Text("ADD TEAMS").font(.system(size: 11, weight: .bold)).tracking(1)
                    .foregroundStyle(RallyTheme.textSecondary)
                Text("Pick a league to browse its clubs. Tapping a starred team removes it.")
                    .font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
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
                        Text(team.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        let fav = FavoriteTeam(id: team.id, league: catalogLeague, name: team.name,
                                               abbreviation: team.abbreviation, logoUrl: team.logoUrl)
                        Button(settings.isFavoriteTeam(id: team.id, league: catalogLeague) ? "★" : "☆") {
                            _ = settings.toggleFavoriteTeam(fav)
                        }.font(.system(size: 16)).buttonStyle(.plain)
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
                toggleRow("Audio normalization", "Even out loud broadcasts", $settings.audioNormalizationEnabled)
                Divider().opacity(0.2)
                toggleRow("Adaptive quality", "Adjust to your connection", $settings.adaptiveQualityEnabled)
                Divider().opacity(0.2)
                toggleRow("Reduce motion", "Calm focus and transitions", $settings.reducedMotion)
                Divider().opacity(0.2)
                toggleRow("Large text", "Bigger scores and titles", $settings.largeText)
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
                        Text("Rally for macOS").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        Text("com.shiv.rally.macos").font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    if let rel = store.update {
                        tvButton("Download v\(rel.tag)", primary: true) {
                            if let url = URL(string: rel.pageUrl) { NSWorkspace.shared.open(url) }
                        }
                    } else {
                        tvButton("Check for updates") { Task { await store.checkUpdates() } }
                    }
                }
            }
            glassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Credentials on this Mac").font(.system(size: 14, weight: .semibold))
                        Text("Portal, addons, favorites and tokens").font(.system(size: 11))
                            .foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    tvButton("Clear credentials", destructive: true) { store.settings.clearCredentials() }
                }
            }
        }
    }

    // MARK: Chrome (TV glass language)

    private func panelTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .bold)).tracking(1.6).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
        }
    }

    private func glassCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(red: 23/255, green: 36/255, blue: 55/255, opacity: 0.72),
                                                Color(red: 7/255, green: 13/255, blue: 22/255, opacity: 0.56)],
                                       startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }

    private func tvButton(_ label: String, primary: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .semibold))
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
                Text(title).font(.system(size: 14))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary)
            }
        }
    }

    private func settingsField(_ label: String, text: Binding<String>, mono: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).frame(width: 150, alignment: .leading)
            TextField("Required", text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .body.monospaced() : .body)
        }
    }

    private func statusPill(_ text: String, good: Bool) -> some View {
        Text(text).font(.system(size: 11, weight: .bold))
            .foregroundStyle(good ? RallyTheme.rallyLime : RallyTheme.liveRed)
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
