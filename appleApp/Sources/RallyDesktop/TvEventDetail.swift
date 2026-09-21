import RallyCore
import SwiftUI

/// Event detail. Mirrors EventDetailsView: compact hero + three glass panels.
struct TvEventDetail: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    var event: SportEvent
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var teamStats: [TeamStatComparison] = []
    @State private var leaders: [PlayerLeader] = []
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                detailHero
                HStack(spacing: 12) {
                    matchupPanel
                    outlookPanel
                    infoPanel
                }
            }
            .padding(.horizontal, m.hPad).padding(.vertical, 12)
        }
        .background { AmbientBackground() }
        .task { await loadDetail() }
    }

    private func loadDetail() async {
        guard let path = EspnClient.path(forLeague: event.league) else { return }
        let detail = await store.espnClient.fetchSummary(
            sport: path.sport, league: path.path, eventId: event.id,
            awayAbbr: event.awayTeam?.abbreviation, homeAbbr: event.homeTeam?.abbreviation)
        teamStats = detail.teamStats
        leaders = detail.leaders
    }

    private var isLive: Bool { event.status == .live || event.status == .halftime }
    private var isFinal: Bool { event.status == .finished }

    private var detailHero: some View {
        ZStack(alignment: .leading) {
            if let img = tvArt(Artwork.heroBackdrop(event: event)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RallyTheme.surfaceRaised
            }
            LinearGradient(colors: [Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.91),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.72),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.22),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.03)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .clear,
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.09),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.56)],
                           startPoint: .top, endPoint: .bottom)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(isLive ? "LIVE" : isFinal ? "FINAL" : "UPCOMING")
                            .font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(isLive ? RallyTheme.liveRed : Color.white.opacity(0.19))
                            .clipShape(Capsule())
                        Text(Artwork.displayLeague(event.league).uppercased())
                            .font(.system(size: 12, weight: .semibold)).tracking(1.2)
                            .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: 0) {
                        teamHero(event.awayTeam).frame(maxWidth: .infinity)
                        VStack(spacing: 2) {
                            Text(isLive || isFinal
                                ? "\(event.scoreAway.map(String.init) ?? "–")  –  \(event.scoreHome.map(String.init) ?? "–")" : "VS")
                                .font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                            Text(isLive ? (event.gameStatusDetail ?? "") : isFinal ? "FINAL"
                                : event.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()).uppercased())
                                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                            if let ctx = event.gameStatusDetail, isLive == false, isFinal == false {
                                Text(ctx.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                                    .foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                            }
                        }
                        .frame(width: m.s(170))
                        teamHero(event.homeTeam).frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: m.s(640))
                    Text([event.venue, event.gameStatusDetail].compactMap { $0?.isEmpty == false ? $0 : nil }
                        .joined(separator: "  ·  "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    HStack(spacing: 10) {
                        Button { store.show(.player(event: event, channel: nil)) } label: {
                            Text(isLive ? "Watch live" : "Watch").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.black).padding(.horizontal, 24).padding(.vertical, 10)
                                .background(RallyTheme.offWhite).clipShape(RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                        Button { store.show(.player(event: event, channel: nil, picker: true)) } label: {
                            Text("Pick source").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(RallyTheme.textPrimary).padding(.horizontal, 24).padding(.vertical, 10)
                                .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(RallyTheme.glassBorder, lineWidth: 1))
                        }.buttonStyle(.plain)
                        if let home = event.homeTeam {
                            let team = FavoriteTeam(id: home.id, league: event.league, name: home.name,
                                abbreviation: home.abbreviation, logoUrl: home.logoUrl)
                            Button { _ = settings.toggleFavoriteTeam(team) } label: {
                                Text(settings.isFavoriteTeam(id: home.id, league: event.league) ? "Saved" : "Save")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(RallyTheme.textPrimary).padding(.horizontal, 24).padding(.vertical, 10)
                                    .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(RallyTheme.glassBorder, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, m.s(36)).padding(.vertical, m.s(18))
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: m.s(280))
            }
            if let mark = tvArt("rally_mark_ui") {
                Image(nsImage: mark).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: m.s(30), height: m.s(30))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(m.s(22))
            }
        }
        .frame(height: m.detailHeroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }

    private func teamHero(_ team: Team?) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 15/255, green: 23/255, blue: 36/255, opacity: 0.65))
                    .frame(width: m.s(92), height: m.s(92))
                if let logo = team?.logoUrl, let url = URL(string: logo) {
                    AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                        Text(team?.abbreviation ?? "TBD").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: m.s(76), height: m.s(76))
                } else {
                    Text(team?.abbreviation ?? "TBD").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                }
            }
            Text(team?.name ?? "TBD").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RallyTheme.textPrimary).lineLimit(1)
        }
    }

    // MARK: Panels (mirror EventStatsPanel / EventLeadersPanel / EventAnalyticsPanel chrome)

    private var matchupPanel: some View {
        panel(title: isLive ? "LIVE STATS" : event.status == .notStarted ? "MATCHUP PREVIEW" : "MATCHUP STATS", trailing: nil) {
            matchupRow(away: event.awayTeam, home: event.homeTeam, label: "TEAMS")
            matchupRowText(away: recordSummary(event.awayTeam), home: recordSummary(event.homeTeam), label: "RECORD")
            ForEach(teamStats.prefix(4), id: \.label) { stat in
                matchupRowText(away: stat.awayValue, home: stat.homeValue, label: stat.label.uppercased())
            }
            matchupRowText(away: event.scoreAway.map(String.init), home: event.scoreHome.map(String.init), label: "SCORE")
        }
    }

    private var outlookPanel: some View {
        panel(title: "TEAM OUTLOOK", trailing: nil) {
            outlookColumn(team: event.awayTeam)
            Divider().opacity(0.3)
            outlookColumn(team: event.homeTeam)
        }
    }

    private var infoPanel: some View {
        panel(title: event.status == .notStarted ? "GAME INFORMATION" : "ANALYTICS", trailing: nil) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metricTile("STATUS", statusText)
                metricTile("LEAGUE", Artwork.displayLeague(event.league).uppercased())
                metricTile("VENUE", (event.venue ?? "TBD").uppercased())
                metricTile("DATE", event.startTime.formatted(.dateTime.month(.abbreviated).day()).uppercased())
            }
        }
    }

    private func panel<Content: View>(title: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.system(size: 15, weight: .bold)).tracking(1.4).foregroundStyle(.white)
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 9, weight: .bold)).tracking(0.8)
                        .foregroundStyle(RallyTheme.rallyCyan)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: m.panelMinHeight, alignment: .topLeading)
        .background(LinearGradient(colors: [Color(red: 23/255, green: 36/255, blue: 55/255, opacity: 0.72),
                                            Color(red: 14/255, green: 25/255, blue: 39/255, opacity: 0.64),
                                            Color(red: 7/255, green: 13/255, blue: 22/255, opacity: 0.56)],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }

    private func matchupRow(away: Team?, home: Team?, label: String) -> some View {
        HStack {
            Text(away?.abbreviation ?? "AWY").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 90, alignment: .leading).lineLimit(1)
            Text(label).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(RallyTheme.textSecondary).frame(maxWidth: .infinity).lineLimit(1)
            Text(home?.abbreviation ?? "HME").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 90, alignment: .trailing).lineLimit(1)
        }
        .frame(height: 30)
    }

    private func matchupRowText(away: String?, home: String?, label: String) -> some View {
        HStack {
            Text(away ?? "–").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 90, alignment: .leading).lineLimit(1)
            Text(label).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(RallyTheme.textSecondary).frame(maxWidth: .infinity).lineLimit(1)
            Text(home ?? "–").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 90, alignment: .trailing).lineLimit(1)
        }
        .frame(height: 30)
    }

    private func teamLeaders(_ team: Team?) -> [PlayerLeader] {
        guard let team else { return [] }
        return leaders.filter {
            $0.teamAbbr?.caseInsensitiveCompare(team.abbreviation) == .orderedSame
        }.prefix(2).map { $0 }
    }

    private func outlookColumn(team: Team?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(team?.name.uppercased() ?? "TBD").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            Text(recordSummary(team) ?? "No record available")
                .font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricTile(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(RallyTheme.textTertiary)
            Text(value).font(.system(size: 12, weight: .bold)).foregroundStyle(.white).lineLimit(2)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(red: 23/255, green: 36/255, blue: 55/255, opacity: 0.32))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 90/255, green: 120/255, blue: 148/255, opacity: 0.16), lineWidth: 1))
    }

    private func recordSummary(_ team: Team?) -> String? {
        guard let team, !team.records.isEmpty else { return nil }
        return team.records.compactMap { $0.summary }.joined(separator: " · ")
    }

    private var statusText: String {
        switch event.status {
        case .live: "LIVE"; case .halftime: "HALFTIME"; case .finished: "FINAL"
        case .notStarted: "UPCOMING"; case .delayed: "DELAYED"; case .canceled: "CANCELED"
        }
    }
}
