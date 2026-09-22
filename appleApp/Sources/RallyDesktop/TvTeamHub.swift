import RallyCore
import SwiftUI

/// Team center. Mirrors TeamHubScreen: header (logo, MY TEAMS · LEAGUE,
/// standing summary) + Overview/Games/Roster/Injuries tabs + Remove.
/// Gated on favorites like TeamHubViewModel (NotFavorite state).
struct TvTeamHub: View {
    let team: FavoriteTeam
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var tab = 0
    @State private var standing: EspnClient.TeamStanding?
    @State private var roster: [RosterPlayer] = []
    @State private var injuries: [InjuryEntry] = []
    @State private var loading = true

    private var isFavorite: Bool {
        settings.isFavoriteTeam(id: team.id, league: team.league)
    }

    private var schedule: [SportEvent] {
        // League-scoped: bare ESPN team ids collide across leagues.
        store.events.filter {
            $0.league == team.league &&
                ($0.homeTeam?.id == team.id || $0.awayTeam?.id == team.id)
        }.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !isFavorite {
                    notFavorite
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    tabBar
                    switch tab {
                    case 0: overview
                    case 1: gamesList(schedule)
                    case 2: rosterList
                    case 3: injuryList
                    default: overview
                    }
                }
            }
            .padding(.horizontal, m.hPad).padding(.vertical, 14)
        }
        .background { AmbientBackground() }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let logo = team.logoUrl, let link = URL(string: logo) {
                AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                    Color.clear
                }
                .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("MY TEAMS · \(team.league.uppercased())")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(RallyTheme.rallyCyan)
                Text(team.name).font(.system(size: 26, weight: .black)).foregroundStyle(.white)
                if let summary = standing?.summary {
                    Text(summary).font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary)
                }
            }
            Spacer()
            if isFavorite {
                Button("Remove") { _ = settings.toggleFavoriteTeam(team) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RallyTheme.textPrimary)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .buttonStyle(.plain)
            }
        }
    }

    private var notFavorite: some View {
        VStack(spacing: 10) {
            Text("Not in your teams").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            Text("Add \(team.name) to get their schedule, roster, and injuries here.")
                .font(.callout).foregroundStyle(RallyTheme.textSecondary)
            Button("Add team") { _ = settings.toggleFavoriteTeam(team) }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 24).padding(.vertical, 10)
                .background(RallyTheme.offWhite).clipShape(RoundedRectangle(cornerRadius: 16))
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(["Overview", "Games", "Roster", "Injuries"].indices, id: \.self) { i in
                Button(["Overview", "Games", "Roster", "Injuries"][i]) { tab = i }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tab == i ? .black : RallyTheme.textPrimary)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(tab == i ? RallyTheme.offWhite : Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .buttonStyle(.plain)
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            glassSection(title: "SEASON") {
                if let summary = standing?.summary {
                    Text(summary).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                if let rank = standing?.rank, !rank.isEmpty {
                    Text("Rank \(rank)").font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary)
                }
                if standing?.summary == nil {
                    Text("Season data is unavailable.").font(.system(size: 13))
                        .foregroundStyle(RallyTheme.textSecondary)
                }
            }
            let next = schedule.first { $0.status != .finished }
            if let next {
                Text("NEXT GAME").font(.system(size: 11, weight: .bold)).tracking(1)
                    .foregroundStyle(RallyTheme.textSecondary)
                GameRow(event: next).onTapGesture { store.show(.eventDetail(next)) }
            }
            let last5 = Array(schedule.filter { $0.status == .finished }.suffix(5).reversed())
            if !last5.isEmpty {
                Text("RECENT FORM").font(.system(size: 11, weight: .bold)).tracking(1)
                    .foregroundStyle(RallyTheme.textSecondary)
                ForEach(last5) { event in
                    GameRow(event: event).onTapGesture { store.show(.eventDetail(event)) }
                }
            }
        }
    }

    private func gamesList(_ games: [SportEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if games.isEmpty {
                Text("No team games are scheduled in the current feed.")
                    .font(.callout).foregroundStyle(RallyTheme.textSecondary)
            }
            ForEach(games) { event in
                GameRow(event: event).onTapGesture { store.show(.eventDetail(event)) }
            }
        }
    }

    private var rosterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if roster.isEmpty {
                Text("Roster is unavailable for this team.")
                    .font(.callout).foregroundStyle(RallyTheme.textSecondary)
            }
            ForEach(roster) { player in
                HStack(spacing: 12) {
                    if let headshot = player.headshotUrl, let link = URL(string: headshot) {
                        AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                            Color.clear
                        }
                        .frame(width: 40, height: 40).clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text([player.position, player.jersey.map { "#\($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var injuryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if injuries.isEmpty {
                Text("No injuries reported for this team.")
                    .font(.callout).foregroundStyle(RallyTheme.textSecondary)
            }
            ForEach(injuries) { injury in
                VStack(alignment: .leading, spacing: 2) {
                    Text(injury.playerName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text([injury.position, injury.status, injury.detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func glassSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(1)
                .foregroundStyle(RallyTheme.textSecondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }

    private func load() async {
        defer { loading = false }
        guard let path = EspnClient.path(forLeague: team.league) else { return }
        async let standingFetch = store.espnClient.fetchTeamStanding(sport: path.sport, league: path.path, teamId: team.id)
        async let rosterFetch = store.espnClient.fetchRoster(sport: path.sport, league: path.path, teamId: team.id)
        async let injuryFetch = store.espnClient.fetchInjuries(sport: path.sport, league: path.path, teamId: team.id)
        standing = await standingFetch
        roster = await rosterFetch
        injuries = await injuryFetch
    }
}
