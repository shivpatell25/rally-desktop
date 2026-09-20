import RallyCore
import SwiftUI

/// Mirrors Android `SettingsScreen` sections: Sources, Sports, Teams, Alerts, Viewing, Support.
struct SettingsView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var newAddon = ""
    var body: some View {
        Form {
            Section("Sources — IPTV and addons") {
                Picker("Provider", selection: $settings.iptvProvider) {
                    Text("Stalker / Ministra").tag(IptvProvider.stalker)
                    Text("Xtream Codes").tag(IptvProvider.xtream)
                }
                if settings.iptvProvider == .stalker {
                    TextField("Portal URL", text: $settings.portalUrl)
                    TextField("MAC address", text: macBinding())
                        .font(.body.monospaced())
                    TextField("Serial (optional)", text: $settings.serialNumber)
                    TextField("Device ID (optional)", text: $settings.deviceId)
                } else {
                    TextField("Server URL", text: $settings.xtreamServerUrl)
                    TextField("Username", text: $settings.xtreamUsername)
                    SecureField("Password", text: passwordBinding())
                }
                HStack {
                    Button("Test connection") { Task { await store.testConnection() } }
                    if let status = store.connectionStatus {
                        Text(status).font(.caption).foregroundStyle(RallyTheme.textSecondary)
                    }
                }
                Button("Load channels") { Task { await store.refreshChannels() } }
                Text("\(store.channels.count) channels loaded").font(.caption).foregroundStyle(RallyTheme.textTertiary)

                ForEach(settings.stremioAddonUrls, id: \.self) { url in
                    HStack {
                        Text(url).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { removeAddon(url) }
                    }
                }
                HStack {
                    TextField("Add addon manifest URL", text: $newAddon)
                    Button("Add") {
                        let clean = newAddon.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty {
                            settings.stremioAddonUrls.append(clean)
                            newAddon = ""
                            Task { await store.refresh() }
                        }
                    }
                }
                Text("HTTP portals are supported for legacy providers but can be intercepted — prefer HTTPS.")
                    .font(.caption).foregroundStyle(RallyTheme.textTertiary)
            }

            Section("Sports — leagues") {
                Text("League order: \(settings.sportsOrder.prefix(6).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(RallyTheme.textSecondary)
                Toggle("Setup complete", isOn: $settings.setupComplete)
            }

            Section("Teams — favorite clubs") {
                if settings.favoriteTeamProfiles.isEmpty {
                    Text("No favorites yet. Star teams from event rows to build Up Next.")
                        .font(.caption).foregroundStyle(RallyTheme.textTertiary)
                }
                ForEach(settings.favoriteTeamProfiles) { team in
                    HStack {
                        Text("\(team.name) (\(team.abbreviation))")
                        Spacer()
                        Text(team.league).font(.caption).foregroundStyle(RallyTheme.textTertiary)
                        Button("Remove") { _ = settings.toggleFavoriteTeam(team) }
                    }
                }
            }

            Section("Alerts — live notifications") {
                Toggle("Live game alerts", isOn: $settings.liveGameAlertsEnabled)
                Toggle("NFL RedZone alerts", isOn: $settings.redZoneAlertsEnabled)
            }

            Section("Viewing — playback and access") {
                Toggle("Low latency mode", isOn: $settings.lowLatencyMode)
                Toggle("Audio normalization", isOn: $settings.audioNormalizationEnabled)
                Toggle("Adaptive quality", isOn: $settings.adaptiveQualityEnabled)
                Toggle("Reduce motion", isOn: $settings.reducedMotion)
                Toggle("Large text", isOn: $settings.largeText)
            }

            Section("Support — about and diagnostics") {
                Text("Rally for macOS · bundle com.shiv.rally.macos").font(.caption)
                if let rel = store.update {
                    Button("Download v\(rel.tag)") {
                        if let url = URL(string: rel.pageUrl) { NSWorkspace.shared.open(url) }
                    }
                } else {
                    Button("Check for updates") { Task { await store.checkUpdates() } }
                }
                Button("Clear credentials", role: .destructive) {
                    settings.clearCredentials()
                }
            }
        }
        .formStyle(.grouped)
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
