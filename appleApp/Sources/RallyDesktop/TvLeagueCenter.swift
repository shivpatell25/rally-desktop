import RallyCore
import SwiftUI

/// League center. Mirrors LeagueHubDashboard: eyebrow + title + counts,
/// Back/Games/Standings tabs, day pager, compact matchup rows.
struct TvLeagueCenter: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    var league: String
    @EnvironmentObject var store: RallyStore
    @State private var tab = 0
    @State private var dayOffset = 0
    @State private var dayEvents: [SportEvent]?
    @State private var dayError: String?
    @State private var loadingDay = false
    @State private var standings: [StandingEntry] = []
    @State private var teams: [Team] = []
    @State private var loadingTeams = true
    @State private var redZone: IptvChannel?
    @FocusState private var focus: String?

    private var leagueEvents: [SportEvent] {
        store.events.filter { $0.league == league }
    }
    private var teamCount: Int {
        standings.isEmpty
            ? Set(leagueEvents.flatMap { [$0.homeTeam?.id, $0.awayTeam?.id].compactMap { $0 } }).count
            : standings.count
    }
    private var postseasonGames: [SportEvent] {
        LeagueHub.postseasonEvents(from: leagueEvents)
    }
    private var playoffSeeds: [StandingEntry] {
        LeagueHub.playoffPicture(standings: standings, league: league)
    }
    private var showPlayoffs: Bool { !postseasonGames.isEmpty || !playoffSeeds.isEmpty }

    /// League-matching provider channels for the CHANNELS strip.
    private var leagueChannels: [IptvChannel] {
        let q = league.lowercased()
        return store.channels.filter {
            $0.name.lowercased().contains(q) || $0.category.lowercased().contains(q)
        }.prefix(8).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RALLY SPORTS · LEAGUE CENTER")
                            .font(RallyFont.font(size: m.eyebrowSize, weight: .bold)).tracking(1.2)
                            .foregroundStyle(RallyTheme.textPrimary)
                        Text(Artwork.displayLeague(league))
                            .font(RallyFont.font(size: m.pageTitleSize + 8, weight: .black)).tracking(-0.7)
                            .foregroundStyle(.white)
                        Text("\(leagueEvents.count) games · \(teamCount) teams")
                            .font(RallyFont.font(size: m.bodySize)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 10) {
                            leagueButton("Back") { store.pendingLeague = nil }
                            leagueButton("Games", primary: tab == 0) { tab = 0 }
                            if !standings.isEmpty {
                                leagueButton("Standings", primary: tab == 1) { tab = 1 }
                            }
                            if showPlayoffs {
                                leagueButton("Playoffs", primary: tab == 2) { tab = 2 }
                            }
                            leagueButton("Teams", primary: tab == 3) { tab = 3 }
                        }
                        if league.lowercased() == "nfl", let rz = redZone {
                            leagueButton("● RedZone", primary: true) {
                                store.show(.player(event: nil, channel: rz))
                            }
                        }
                    }
                }
                .padding(.horizontal, m.hPad).padding(.top, m.pageTopPadding)
                if tab == 0 {
                    Text("GAMES").font(RallyFont.font(size: m.sectionTitleSize, weight: .black)).tracking(1.6)
                        .foregroundStyle(.white).padding(.horizontal, m.hPad)
                    dayPager
                    if loadingDay {
                        ProgressView().padding(.horizontal, m.hPad)
                    } else if let error = dayError {
                        Text(error).font(.callout).foregroundStyle(RallyTheme.liveRed)
                            .padding(.horizontal, m.hPad)
                    } else if let day = dayEvents {
                        if day.isEmpty {
                            Text("No games are listed for this date.")
                                .font(.callout).foregroundStyle(RallyTheme.textSecondary)
                                .padding(.horizontal, m.hPad)
                        } else {
                            matchupRows(day)
                        }
                    } else {
                        matchupRows(leagueEvents)
                    }
                    if !leagueChannels.isEmpty {
                        Text("CHANNELS").font(RallyFont.font(size: m.sectionTitleSize, weight: .black)).tracking(1.6)
                            .foregroundStyle(.white).padding(.horizontal, m.hPad).padding(.top, 6)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(leagueChannels) { channel in
                                    Button { store.show(.player(event: nil, channel: channel)) } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(channel.name).font(RallyFont.font(size: 13, weight: .semibold))
                                                .foregroundStyle(.white).lineLimit(1)
                                            if let now = channel.guide?.now?.title {
                                                Text(now).font(RallyFont.font(size: 11))
                                                    .foregroundStyle(RallyTheme.textPrimary).lineLimit(1)
                                            } else {
                                                Text(channel.category).font(RallyFont.font(size: 11))
                                                    .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                                            }
                                        }
                                        .padding(12)
                                        .frame(width: 220, alignment: .leading)
                                        .background(Color.white.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyTheme.glassBorder, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, m.hPad)
                        }
                    }
                } else if tab == 1 {
                    Text("STANDINGS").font(RallyFont.font(size: m.sectionTitleSize, weight: .black)).tracking(1.6)
                        .foregroundStyle(.white).padding(.horizontal, m.hPad)
                    standingsRows
                } else if tab == 3 {
                    teamDirectory
                } else {
                    Text("PLAYOFFS").font(RallyFont.font(size: m.sectionTitleSize, weight: .black)).tracking(1.6)
                        .foregroundStyle(.white).padding(.horizontal, m.hPad)
                    if !postseasonGames.isEmpty {
                        matchupRows(postseasonGames)
                    } else {
                        playoffRows
                    }
                }
            }
            .frame(maxWidth: m.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 28)
        }
        .task { await loadHub() }
        .task(id: dayOffset) { await loadDay() }
    }

    private var dayPager: some View {
        HStack(spacing: 10) {
            Button("‹") { dayOffset -= 1 }.buttonStyle(.plain)
                .font(RallyFont.font(size: 20, weight: .bold)).foregroundStyle(RallyTheme.textSecondary)
            ForEach(-1...1, id: \.self) { off in
                let title = off == -1 ? "YESTERDAY" : off == 0 ? "TODAY" : "TOMORROW"
                Button(title) { dayOffset = off }.buttonStyle(.plain)
                    .font(RallyFont.font(size: 12, weight: .bold)).tracking(0.8)
                    .foregroundStyle(dayOffset == off ? .black : RallyTheme.textSecondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(dayOffset == off ? RallyTheme.offWhite : Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button("›") { dayOffset += 1 }.buttonStyle(.plain)
                .font(RallyFont.font(size: 20, weight: .bold)).foregroundStyle(RallyTheme.textSecondary)
            if dayOffset != 0 {
                Button("Today") { dayOffset = 0 }.buttonStyle(.plain)
                    .font(RallyFont.font(size: 12, weight: .bold)).foregroundStyle(RallyTheme.textPrimary)
            }
            if abs(dayOffset) > 1 {
                Text(dayLabel).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary)
            }
        }
        .padding(.horizontal, m.hPad)
    }

    private var dayLabel: String {
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d"
        return fmt.string(from: date).uppercased()
    }
    private func loadHub() async {
        guard let entry = EspnClient.leagues.first(where: { $0.league == league }) else { loadingTeams = false; return }
        async let catalog = store.espnClient.fetchTeams(sport: entry.sport, league: entry.path)
        async let table = store.espnClient.fetchStandings(sport: entry.sport, league: entry.path)
        await store.ensureChannels()
        let official = await table
        // Off-season the endpoint publishes no table (link only) — fall back
        // to in-feed records so the tab survives instead of vanishing.
        standings = official.isEmpty ? inFeedStandings() : official
        teams = await catalog
        loadingTeams = false
        redZone = LeagueHub.redZoneChannel(in: store.channels)
    }

    private func inFeedStandings() -> [StandingEntry] {
        var map: [String: StandingEntry] = [:]
        for e in leagueEvents {
            for t in [e.homeTeam, e.awayTeam].compactMap({ $0 }) {
                if map[t.id] == nil, let rec = t.records.first?.summary {
                    map[t.id] = StandingEntry(teamId: t.id, name: t.name, abbreviation: t.abbreviation,
                                             logoUrl: t.logoUrl, summary: rec)
                }
            }
        }
        return map.values.sorted { $0.name < $1.name }
    }

    private func loadDay() async {
        let requestedOffset = dayOffset
        dayError = nil
        guard let entry = EspnClient.leagues.first(where: { $0.league == league }) else { dayEvents = []; return }
        if LaunchArgs.visualFixture {
            let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
            dayEvents = leagueEvents.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) }
            return
        }
        loadingDay = true
        defer { if dayOffset == requestedOffset && !Task.isCancelled { loadingDay = false } }
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = Calendar.current.timeZone
        do {
            let events = try await store.espnClient.fetchScoreboard(sport: entry.sport, league: entry.path,
                domainLeague: league, dates: fmt.string(from: date))
            guard !Task.isCancelled, dayOffset == requestedOffset else { return }
            dayEvents = events.filter { Calendar.current.isDate($0.startTime, inSameDayAs: date) }
        } catch {
            guard !Task.isCancelled, dayOffset == requestedOffset else { return }
            // No silent wrong-day fallback: say so and keep Today visible.
            dayEvents = nil
            dayError = "Couldn't load that date. Check your connection and try again."
        }
    }

    private func matchupRows(_ events: [SportEvent]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(events.sorted { $0.startTime < $1.startTime }) { event in
                RallyEventRow(event: event)
            }
        }.padding(.horizontal, m.hPad)
    }

    private var teamDirectory: some View {
        VStack(alignment: .leading, spacing: 16) {
            RallySectionTitle(title: "Teams")
            if loadingTeams { ProgressView("Loading teams…") }
            else if teams.isEmpty {
                RallyEmptyState(eyebrow: league, title: "Teams unavailable", message: "The league has not published its team directory. Try again to reconnect.")
                Button("Try Again") { loadingTeams = true; Task { await loadHub() } }.buttonStyle(RallyActionStyle())
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    ForEach(teams) { team in
                        Button {
                            store.show(.team(FavoriteTeam(id: team.id, league: league, name: team.name, abbreviation: team.abbreviation, logoUrl: team.logoUrl)))
                        } label: {
                            VStack(spacing: 14) {
                                RallyTeamLogo(team: team, size: 64)
                                Text(team.name).font(RallyFont.font(size: 14, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
                            }.frame(maxWidth: .infinity).frame(height: 150)
                                .background(RallyTheme.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help("Open " + team.name)
                    }
                }
            }
        }.padding(.horizontal, m.hPad)
    }

    private var standingsRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(standings) { row in standingRow(row) }
        }.padding(.horizontal, m.hPad)
    }

    private var playoffRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(playoffSeeds.enumerated()), id: \.element.id) { index, row in
                standingRow(row, seed: index + 1)
            }
        }.padding(.horizontal, m.hPad)
    }

    private func standingRow(_ row: StandingEntry, seed: Int? = nil) -> some View {
        Button {
            store.show(.team(FavoriteTeam(id: row.teamId, league: league, name: row.name,
                                         abbreviation: row.abbreviation, logoUrl: row.logoUrl)))
        } label: {
            HStack(spacing: 14) {
                if let seed {
                    Text("\(seed)").font(RallyFont.font(size: 13, weight: .semibold))
                        .foregroundStyle(RallyTheme.textSecondary).frame(width: 24)
                }
                RallyTeamLogo(team: Team(id: row.teamId, name: row.name,
                                        abbreviation: row.abbreviation, logoUrl: row.logoUrl), size: 32)
                Text(row.name).font(RallyFont.font(size: 16, weight: .semibold))
                    .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
                Text(row.recordLine).font(RallyFont.font(size: 14))
                    .foregroundStyle(RallyTheme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(RallyTheme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 16).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
        }.buttonStyle(.plain).help("Open " + row.name)
    }

    private func leagueButton(_ label: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(RallyFont.font(size: 14, weight: .semibold))
                .foregroundStyle(primary ? RallyTheme.deepNavy : RallyTheme.offWhite)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(primary ? RallyTheme.offWhite : RallyTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? Color.white.opacity(0.72) : RallyTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Responsive league directory. Cards flow into additional rows instead of
/// overflowing the native window.
struct TvLeaguesHome: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @FocusState private var focus: String?

    private var columnCount: Int {
        switch m.layout {
        case .compact: 3
        case .standard: 5
        case .wide: 5
        }
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 180), spacing: m.cardSpacing), count: columnCount)
    }
    private var cardSize: CGSize {
        let width = (m.contentWidth - m.cardSpacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        return CGSize(width: width, height: width * 0.66)
    }

    var body: some View {
        if let pending = store.pendingLeague {
            if ["Soccer", "Tennis", "UFC"].contains(pending) { RallySportDirectory(sport: pending) }
            else { TvLeagueCenter(league: pending) }
        } else {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: m.sectionSpacing) {
                        RallyPageHeader(
                            eyebrow: "Leagues",
                            title: "Leagues",
                            subtitle: "Open a league for games, standings, channels, and postseason coverage."
                        )
                        .id("leagues-top")
                        LazyVGrid(columns: columns, alignment: .leading, spacing: m.cardSpacing) {
                            ForEach(store.leagueShelves, id: \.title) { shelf in
                                TvDirectoryCard(title: shelf.title, events: shelf.events,
                                                focus: $focus, size: cardSize) {
                                    store.pendingLeague = shelf.title
                                }
                            }
                        }
                    }
                    .frame(maxWidth: m.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, m.hPad)
                    .padding(.top, m.pageTopPadding)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    guard LaunchArgs.visualFixture else { return }
                    DispatchQueue.main.async {
                        reader.scrollTo("leagues-top", anchor: .top)
                    }
                }
            }
        }
    }
}

struct TvDirectoryCard: View {
    var title: String
    var events: [SportEvent]
    var focus: FocusState<String?>.Binding
    var size: CGSize
    @Environment(\.tvMetrics) private var m: TvMetrics
    @State private var hovered = false
    var onSelect: () -> Void = {}
    private var id: String { "dir-\(title)" }
    private var hasLive: Bool { events.contains { $0.status == .live || $0.status == .halftime } }
    private var active: Bool { focus.wrappedValue == id || hovered }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 20) {
                RallyLeagueMark(league: title, size: 66)
                Text(Artwork.displayLeague(title)).font(RallyFont.font(size: 20, weight: .medium)).lineLimit(1)
                if hasLive { Text("● LIVE").font(RallyFont.font(size: 10, weight: .semibold)).foregroundStyle(RallyTheme.liveRed) }
            }
            .frame(width: size.width, height: max(185, size.height))
            .foregroundStyle(.white).background(RallyTheme.surfaceBase.opacity(active ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Color.white.opacity(0.5) : .clear, lineWidth: 0.7))
            .offset(y: hovered ? -2 : 0)
        }
        .buttonStyle(.plain)
        .focused(focus, equals: id)
        .onHover { hovered = $0 }
    }
}
