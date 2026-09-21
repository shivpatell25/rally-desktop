import RallyCore
import SwiftUI

/// TV-glass settings: section rail + panel content, same six sections as
/// Android SettingsScreen, TV typography and button treatments.
struct SettingsView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var newAddon = ""
    @State private var section = 0

    private let sections = ["Sources", "Sports", "Teams", "Alerts", "Viewing", "Support"]
    private let icons = ["antenna.radiowaves.left.and.right", "trophy", "star", "bell", "play.tv", "info.circle"]

    var body: some View {
        HSplitView {
            List(selection: $section) {
                ForEach(sections.indices, id: \.self) { i in
                    Label(sections[i], systemImage: icons[i]).tag(i)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(minWidth: 190, maxWidth: 230)
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
            .frame(minWidth: 480)
        }
        .background { AmbientBackground() }
        .navigationTitle("Settings")
    }

    // MARK: Panels

    private var sourcesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("SOURCES", "IPTV and addons")
            glassCard {
                Picker("Provider", selection: $settings.iptvProvider) {
                    Text("Stalker / Ministra").tag(IptvProvider.stalker)
                    Text("Xtream Codes").tag(IptvProvider.xtream)
                }
                .pickerStyle(.segmented)
                if settings.iptvProvider == .stalker {
                    settingsField("Portal URL", text: $settings.portalUrl)
                    settingsField("MAC address", text: macBinding(), mono: true)
                    settingsField("Serial (optional)", text: $settings.serialNumber)
                    settingsField("Device ID (optional)", text: $settings.deviceId)
                } else {
                    settingsField("Server URL", text: $settings.xtreamServerUrl)
                    settingsField("Username", text: $settings.xtreamUsername)
                    HStack {
                        Text("Password").frame(width: 150, alignment: .leading)
                        SecureField("Required", text: passwordBinding())
                    }
                    .font(.system(size: 14))
                }
            }
            glassCard {
                HStack(spacing: 10) {
                    tvButton("Test connection", primary: true) { Task { await store.testConnection() } }
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
                ForEach(settings.stremioAddonUrls, id: \.self) { url in
                    HStack {
                        Text(url).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { removeAddon(url) }.font(.system(size: 12))
                    }
                    Divider().opacity(0.2)
                }
                HStack {
                    TextField("Add addon manifest URL", text: $newAddon)
                        .textFieldStyle(.roundedBorder)
                    tvButton("Add") {
                        let clean = newAddon.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty {
                            settings.stremioAddonUrls.append(clean)
                            newAddon = ""
                            Task { await store.refresh() }
                        }
                    }
                }
                Text("HTTP portals work for legacy providers but can be intercepted — prefer HTTPS.")
                    .font(.system(size: 11)).foregroundStyle(RallyTheme.textTertiary)
            }
        }
    }

    private var sportsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("SPORTS", "Leagues and order")
            glassCard {
                Text("League order").font(.system(size: 14, weight: .semibold))
                Text(settings.sportsOrder.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary)
                Toggle("Setup complete", isOn: $settings.setupComplete)
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
                    HStack {
                        Text("\(team.name) (\(team.abbreviation))").font(.system(size: 14))
                        Spacer()
                        Text(team.league).font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                        Button("Remove") { _ = settings.toggleFavoriteTeam(team) }.font(.system(size: 12))
                    }
                    Divider().opacity(0.2)
                }
            }
        }
    }

    private var alertsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("ALERTS", "Live notifications")
            glassCard {
                Toggle("Live game alerts", isOn: $settings.liveGameAlertsEnabled)
                Divider().opacity(0.2)
                Toggle("NFL RedZone alerts", isOn: $settings.redZoneAlertsEnabled)
            }
        }
    }

    private var viewingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("VIEWING", "Playback and access")
            glassCard {
                Toggle("Low latency mode", isOn: $settings.lowLatencyMode)
                Divider().opacity(0.2)
                Toggle("Audio normalization", isOn: $settings.audioNormalizationEnabled)
                Divider().opacity(0.2)
                Toggle("Adaptive quality", isOn: $settings.adaptiveQualityEnabled)
                Divider().opacity(0.2)
                Toggle("Reduce motion", isOn: $settings.reducedMotion)
                Divider().opacity(0.2)
                Toggle("Large text", isOn: $settings.largeText)
            }
        }
    }

    private var supportPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("SUPPORT", "About and diagnostics")
            glassCard {
                Text("Rally for macOS · bundle com.shiv.rally.macos")
                    .font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary)
                if let rel = store.update {
                    tvButton("Download v\(rel.tag)", primary: true) {
                        if let url = URL(string: rel.pageUrl) { NSWorkspace.shared.open(url) }
                    }
                } else {
                    tvButton("Check for updates") { Task { await store.checkUpdates() } }
                }
            }
            glassCard {
                tvButton("Clear credentials", destructive: true) { store.settings.clearCredentials() }
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

    private func macBinding() -> Binding<String> {
        Binding(get: { settings.macAddress }, set: { settings.macAddress = $0 })
    }
    private func passwordBinding() -> Binding<String> {
        Binding(get: { settings.xtreamPassword }, set: { settings.xtreamPassword = $0 })
    }
    private func removeAddon(_ url: String) {
        settings.stremioAddonUrls.removeAll { $0 == url }
        Task { await store.refresh() }
    }
}
