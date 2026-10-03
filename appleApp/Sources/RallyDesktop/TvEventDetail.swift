import RallyCore
import SwiftUI

/// Rally event composition: cinematic hero, underline tabs and three context panels.
struct TvEventDetail: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    var event: SportEvent
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var selectedTab = "Overview"
    @State private var plays: [GamePlay] = []
    @State private var sources: [PlayCandidate] = []
    @State private var webSources: [StremioStreamOption] = []
    @State private var sourcesLoading = false
    @State private var detailLoading = true
    @State private var detailError: String?
    @State private var injuries: [(team: String, entries: [InjuryEntry])] = []
    @State private var teamStats: [TeamStatComparison] = []
    @State private var leaders: [PlayerLeader] = []
    @State private var playerTables: [PlayerStatTable] = []
    @State private var clips: [HighlightClip] = []
    @State private var homeWinPct: Double?
    @State private var awayWinPct: Double?
    @State private var venueName: String?
    @State private var venueLocation: String?
    @State private var venueImageUrl: String?
    @State private var weatherSummary: String?
    @State private var articleHeadline: String?
    @State private var articleSummary: String?
    @State private var liveEvent: SportEvent?
    /// Live override: polling refreshes scores without reopening the page.
    private var ev: SportEvent { liveEvent ?? event }
    private enum DetailLayout {
        case wide
        case medium
        case compact

        init(width: CGFloat) {
            if width >= 1040 { self = .wide }
            else if width >= 800 { self = .medium }
            else { self = .compact }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = DetailLayout(width: proxy.size.width)
            ZStack {
                ScrollView {
                    VStack(spacing: 10) {
                        RallyHero(event: ev, detailed: true, venueImageURL: venueImageUrl)
                        RallyTabs(items: ["Overview", "Stats", "Players", "Plays", "Sources", "Highlights"].map { ($0, $0) }, selection: $selectedTab)
                            .padding(.bottom, 10)
                        if detailLoading { ProgressView("Loading game details…") }
                        if let detailError {
                            HStack { Text(detailError); Button("Try Again") { Task { await loadDetail() } } }.font(.callout)
                        }
                        switch selectedTab {
                        case "Stats":
                            matchupPanel
                            if !leaders.isEmpty { leadersPanel }
                            if !playerTables.isEmpty { playerStatsPanel }
                            if teamStats.isEmpty && leaders.isEmpty && playerTables.isEmpty { unavailable("Statistics") }
                        case "Players":
                            if !playerTables.isEmpty { playerStatsPanel }
                            else { unavailable("Players") }
                        case "Plays":
                            if plays.isEmpty { unavailable("Play-by-play") }
                            else { RallyPlaysPanel(plays: plays) }
                        case "Sources": sourcesPanel
                        case "Highlights": if clips.isEmpty { unavailable("Highlights") } else { clipsPanel }
                        default:
                            detailPanels(layout)
                        }

                    }
                    .padding(.horizontal, m.hPad)
                    .padding(.vertical, 12)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .environment(\.tvMetrics, TvMetrics(width: proxy.size.width, height: proxy.size.height, largeText: settings.largeText))
        }
        .task {
            guard !LaunchArgs.visualFixture else { detailLoading = false; return }
            await loadDetail()
            await pollLive()
        }
    }

    private func loadDetail() async {
        detailLoading = true
        defer { detailLoading = false }
        guard let path = EspnClient.path(forLeague: ev.league) else { return }
        let detail = await store.espnClient.fetchSummary(
            sport: path.sport, league: path.path, eventId: ev.id,
            awayAbbr: ev.awayTeam?.abbreviation, homeAbbr: ev.homeTeam?.abbreviation)
        detailError = detail.isAvailable ? nil : "Game details could not be loaded."
        if let current = detail.event { liveEvent = current }
        plays = detail.plays
        teamStats = detail.teamStats
        leaders = detail.leaders
        playerTables = detail.playerTables
        clips = detail.clips
        homeWinPct = detail.homeWinPct
        awayWinPct = detail.awayWinPct
        venueName = detail.venueName
        venueLocation = detail.venueLocation
        venueImageUrl = detail.venueImageUrl
        weatherSummary = detail.weatherSummary
        articleHeadline = detail.headline
        articleSummary = detail.summary
    }
    /// plus the score line every 30s while the game is live.
    private func pollLive() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, isLive else { continue }
            await loadDetail()
            if let path = EspnClient.path(forLeague: ev.league),
               let fresh = try? await store.espnClient.fetchScoreboard(sport: path.sport, league: path.path,
                   domainLeague: ev.league),
               let updated = fresh.first(where: { $0.id == ev.id }) {
                liveEvent = updated
            }
        }
    }

    private var leadersPanel: some View {
        panel(title: "TOP PERFORMERS", trailing: nil) {
            ForEach([ev.awayTeam, ev.homeTeam].compactMap { $0 }, id: \.id) { team in
                let rows = teamLeaders(team)
                if !rows.isEmpty {
                    Text(team.abbreviation).font(RallyFont.font(size: 10, weight: .bold)).tracking(0.8)
                        .foregroundStyle(RallyTheme.textSecondary)
                    ForEach(rows, id: \.playerShortName) { leader in
                        HStack(spacing: 8) {
                            if let image = leader.headshotUrl ?? leader.teamLogoUrl, let link = URL(string: image) {
                                AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                                    Circle().fill(Color.white.opacity(0.08))
                                }
                                .frame(width: 34, height: 34).clipShape(Circle())
                            } else {
                                Circle().fill(Color.white.opacity(0.08)).frame(width: 34, height: 34)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(leader.playerShortName).font(RallyFont.font(size: 13, weight: .semibold)).foregroundStyle(.white)
                                Text(leader.statDisplay).font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textPrimary)
                            }
                            Spacer()
                            Text(leader.category).font(RallyFont.font(size: 10)).foregroundStyle(RallyTheme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private var featuredPlayerTables: [PlayerStatTable] {
        var seen = Set<String>()
        return playerTables.filter {
            !$0.rows.isEmpty && seen.insert($0.teamId ?? $0.teamAbbreviation).inserted
        }
    }

    private var playerStatsPanel: some View {
        RallyPlayersPanel(tables: playerTables).padding(16).rallySurface(radius: 8)
    }

    private var oldPlayerStatsPanel: some View {
        panel(title: "PLAYER STAT LINES", trailing: nil) {
            ForEach(Array(playerTables.enumerated()), id: \.offset) { entry in
                let table = entry.element
                let columns = rallyPreferredStatIndices(table.labels)
                HStack(spacing: 8) {
                    remoteLogo(table.teamLogoUrl, fallback: table.teamAbbreviation, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(table.teamName).font(RallyFont.font(size: 12, weight: .bold)).foregroundStyle(.white)
                        Text(rallyStatLabel(table.category ?? "Statistics").uppercased())
                            .font(RallyFont.font(size: 9, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(RallyTheme.textTertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(columns, id: \.self) { index in
                        Text(table.labels[index]).frame(width: 48, alignment: .trailing)
                    }
                }
                .font(RallyFont.font(size: 9, weight: .bold)).foregroundStyle(RallyTheme.textTertiary)
                ForEach(table.rows, id: \.displayName) { row in
                    HStack(spacing: 7) {
                        remoteLogo(row.headshotUrl, fallback: row.jersey ?? "", size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.shortName ?? row.displayName).lineLimit(1)
                            if let position = row.position {
                                Text(position).font(RallyFont.font(size: 9)).foregroundStyle(RallyTheme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(columns, id: \.self) { index in
                            Text(row.stats.indices.contains(index) ? row.stats[index] : "–")
                                .font(RallyFont.font(size: 11, weight: .semibold)).monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    .font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textPrimary)
                }
                Divider().opacity(0.2)
            }
        }
    }

    private var clipsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            RallySectionTitle(title: "Highlights")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(clips) { clip in
                        RallyClipCard(clip: clip, width: m.mediaWidth) {
                            if clip.streamUrl != nil { store.show(.player(event: ev, channel: nil, clip: clip)) }
                            else if let value = clip.webUrl, let url = URL(string: value) { NSWorkspace.shared.open(url) }
                        }.disabled(clip.streamUrl == nil && clip.webUrl == nil)
                    }
                }.padding(.vertical, 3)
            }
        }
    }

    private func unavailable(_ feature: String) -> some View {
        RallyEmptyState(eyebrow: feature, title: "No \(feature.lowercased()) published yet.", message: "Available coverage appears here as the league publishes it.")
    }
    private var sourcesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sourcesLoading { ProgressView("Finding broadcasts…") }
            else if sources.isEmpty && webSources.isEmpty { unavailable("Sources") }
            ForEach(sources) { source in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.title).font(.headline)
                        Text(source.kind == .iptv ? "IPTV · \(source.channel?.category ?? "Broadcast")" : (source.addonName ?? "Addon"))
                            .font(.caption).foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    Button("Watch") { store.show(.player(event: ev, channel: nil, source: source)) }
                }.rallySurface(padding: 14)
            }
            ForEach(webSources, id: \.streamUrl) { source in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(source.title).font(.headline); Text("Browser coverage · " + (source.addonName ?? "Addon")).font(.caption).foregroundStyle(RallyTheme.textSecondary) }
                    Spacer()
                    Button("Open Website") { if let url = URL(string: source.streamUrl) { NSWorkspace.shared.open(url) } }
                }.rallySurface(padding: 14)
            }
            Button("Refresh Sources") { Task { await loadSources() } }
        }.task { if sources.isEmpty { await loadSources() } }
    }
    private func loadSources() async {
        guard !sourcesLoading else { return }
        sourcesLoading = true
        defer { sourcesLoading = false }
        await store.ensureChannels()
        let event = ev
        let options = await withTaskGroup(of: [StremioStreamOption].self) { group in
            for base in settings.stremioAddonUrls { group.addTask { await store.stremioClient.findStreams(for: event, addonBase: base) } }
            var result: [StremioStreamOption] = []
            for await part in group { result += part }
            return result
        }
        webSources = options.filter { !$0.isDirectPlayable }
        sources = StreamResolver.candidates(event: ev, channels: store.channels, stremioOptions: options)
    }
    private func loadAvailability() async {
        guard let path = EspnClient.path(forLeague: ev.league) else { return }
        for team in [ev.awayTeam, ev.homeTeam].compactMap({ $0 }) {
            let rows = await store.espnClient.fetchInjuries(sport: path.sport, league: path.path, teamId: team.id)
            injuries.append((team.name, rows))
        }
    }
    private var overviewLeaders: [PlayerLeader] {
        let teams = [ev.awayTeam?.abbreviation, ev.homeTeam?.abbreviation].compactMap { $0 }
        let paired = teams.flatMap { abbreviation in leaders.filter { $0.teamAbbr == abbreviation }.prefix(3) }
        return paired.isEmpty ? Array(leaders.prefix(6)) : paired
    }
    private var formStats: [TeamStatComparison] {
        let preferred = ["Total Yards", "Passing", "Rushing", "1st Downs", "3rd down efficiency", "Possession"].compactMap { label in teamStats.first { $0.label == label } }
        return Array((preferred.isEmpty ? teamStats : preferred).prefix(3))
    }
    private var overviewPlayersPanel: some View {
        panel(title: "Player Stats", trailing: nil) {
            if leaders.isEmpty { Text("Player stats appear as coverage is published.").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary) }
            ForEach(Array(overviewLeaders.enumerated()), id: \.offset) { _, leader in
                HStack(spacing: 8) {
                    remoteLogo(leader.headshotUrl, fallback: leader.position ?? "", size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leader.playerShortName).font(RallyFont.font(size: 12, weight: .medium)).lineLimit(1)
                        Text([leader.teamAbbr, leader.category].compactMap { $0 }.joined(separator: " · ")).font(RallyFont.font(size: 10)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    Text(leader.statDisplay).font(RallyFont.font(size: 11, weight: .semibold)).lineLimit(2)
                }
            }
            Button("All Players") { selectedTab = "Players" }.buttonStyle(.plain).font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
        }
    }
    private var availabilityPanel: some View {
        panel(title: "Injuries / Availability", trailing: nil) {
            if injuries.allSatisfy({ $0.entries.isEmpty }) {
                Text("No availability report published.").font(.callout).foregroundStyle(RallyTheme.textSecondary)
            }
            ForEach(injuries.indices, id: \.self) { index in
                let group = injuries[index]
                if !group.entries.isEmpty {
                    Text(group.team).font(.subheadline.bold())
                    ForEach(group.entries, id: \.playerName) { row in
                        HStack { Text(row.playerName); Spacer(); Text(row.status ?? "Status unavailable").foregroundStyle(RallyTheme.textPrimary) }.font(.callout)
                    }
                }
            }
        }
    }

    private var isLive: Bool { ev.status == .live || ev.status == .halftime }
    private var isFinal: Bool { ev.status == .finished }

    @ViewBuilder
    private func detailPanels(_ layout: DetailLayout) -> some View {
        if layout == .wide {
            HStack(alignment: .top, spacing: 14) {
                infoPanel.frame(maxWidth: .infinity)
                outlookPanel.frame(maxWidth: .infinity)
                overviewPlayersPanel.frame(maxWidth: .infinity)
            }
        } else if layout == .medium {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) { infoPanel; outlookPanel }
                overviewPlayersPanel
            }
        } else {
            VStack(spacing: 14) { infoPanel; outlookPanel; overviewPlayersPanel }
        }
    }
    private var relatedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            RallySectionTitle(title: "More from this game", action: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach([("Full Stats", "Stats", "chart.bar", "Team and player breakdowns"), ("Play-by-Play", "Plays", "list.bullet", "Every play, in real time"), ("Highlights", "Highlights", "play.fill", "Key moments and recap")], id: \.0) { title, tab, icon, subtitle in
                        Button { selectedTab = tab } label: {
                            HStack(spacing: 14) {
                                if let image = tvArt(Artwork.shelfBackdrop(event: ev)) { Image(nsImage: image).resizable().scaledToFill().frame(width: 100, height: 72).clipped() }
                                Image(systemName: icon).font(RallyFont.font(size: 20)).frame(width: 34)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(title).font(RallyFont.font(size: 14, weight: .semibold))
                                    Text(subtitle).font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(RallyTheme.textSecondary)
                            }.foregroundStyle(.white).frame(width: max(300, min(410, m.contentWidth / 3 - 12)))
                                .rallySurface(radius: 8).clipped()
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(.top, 12)
    }

    private func detailHero(compact: Bool) -> some View {
        ZStack(alignment: .leading) {
            heroBackdrop
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
                        StatusBadge(status: ev.status)
                        Text(Artwork.displayLeague(ev.league).uppercased())
                            .font(RallyFont.font(size: 12, weight: .semibold)).tracking(1.2)
                            .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: 0) {
                        teamHero(ev.awayTeam).frame(maxWidth: .infinity)
                        VStack(spacing: 2) {
                            Text(isLive || isFinal
                                ? "\(ev.scoreAway.map(String.init) ?? "–")  –  \(ev.scoreHome.map(String.init) ?? "–")" : "VS")
                                .font(RallyFont.font(size: 34, weight: .bold)).foregroundStyle(.white)
                            Text(isLive ? (ev.gameStatusDetail ?? "") : isFinal ? "FINAL"
                                : ev.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()).uppercased())
                                .font(RallyFont.font(size: 10, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                            if let ctx = ev.gameStatusDetail, isLive == false, isFinal == false {
                                Text(ctx.uppercased()).font(RallyFont.font(size: 10, weight: .semibold)).tracking(0.8)
                                    .foregroundStyle(RallyTheme.textTertiary).lineLimit(1)
                            }
                        }
                        .frame(width: compact ? m.s(130) : m.s(170))
                        teamHero(ev.homeTeam).frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: compact ? .infinity : m.s(640))
                    Text(heroMetadata)
                        .font(RallyFont.font(size: 10, weight: .medium))
                        .foregroundStyle(RallyTheme.textSecondary)
                        .lineLimit(2)
                    heroActions
                }
                .padding(.leading, m.s(36))
                .padding(.trailing, compact ? m.s(36) : 0)
                .padding(.vertical, m.s(18))
                .frame(maxWidth: compact ? .infinity : m.s(760), alignment: .leading)
                if !compact {
                    Spacer(minLength: m.s(120))
                }
            }
            if let mark = tvArt("rally_mark_ui") {
                Image(nsImage: mark).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: m.s(30), height: m.s(30))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(m.s(22))
            }
        }
        .frame(height: compact ? max(260, m.detailHeroHeight) : m.detailHeroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var heroBackdrop: some View {
        if let venueImageUrl, let url = URL(string: venueImageUrl) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else if let img = tvArt(Artwork.heroBackdrop(event: ev)) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    RallyTheme.surfaceRaised
                }
            }
        } else if let img = tvArt(Artwork.heroBackdrop(event: ev)) {
            Image(nsImage: img).resizable().scaledToFill()
        } else {
            RallyTheme.surfaceRaised
        }
    }

    private var heroMetadata: String {
        let venue = venueName ?? ev.venue
        let values = [venue, venueLocation, ev.broadcasts.first]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return values.isEmpty ? Artwork.displayLeague(ev.league) : values.joined(separator: "  ·  ")
    }

    private var heroActions: some View {
        HStack(spacing: 10) {
            Button(isLive ? "Watch Live" : "Watch") { store.show(.player(event: ev, channel: nil)) }
                .buttonStyle(RallyActionStyle(primary: true))
            Button { settings.toggleSavedEvent(ev) } label: {
                Label(settings.savedEventIds.contains(ev.id) ? "In Watchlist" : "Watchlist", systemImage: settings.savedEventIds.contains(ev.id) ? "bookmark.fill" : "plus")
            }.buttonStyle(RallyActionStyle())
            Button("Pick Source") { store.show(.player(event: ev, channel: nil, picker: true)) }.buttonStyle(RallyActionStyle())
            Menu {
                ForEach([ev.awayTeam, ev.homeTeam].compactMap { $0 }, id: \.id) { side in
                    let team = FavoriteTeam(id: side.id, league: ev.league, name: side.name, abbreviation: side.abbreviation, logoUrl: side.logoUrl)
                    Button((settings.isFavoriteTeam(id: side.id, league: ev.league) ? "Unfollow " : "Follow ") + side.name) { _ = settings.toggleFavoriteTeam(team) }
                }
            } label: { Label("Teams", systemImage: "star") }.menuStyle(.borderlessButton).fixedSize().font(RallyFont.font(size: 12))
        }
    }

    private func teamHero(_ team: Team?) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 15/255, green: 23/255, blue: 36/255, opacity: 0.65))
                    .frame(width: m.s(92), height: m.s(92))
                if let logo = team?.logoUrl, let url = URL(string: logo) {
                    AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                        Text(team?.abbreviation ?? "TBD").font(RallyFont.font(size: 16, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: m.s(76), height: m.s(76))
                } else {
                    Text(team?.abbreviation ?? "TBD").font(RallyFont.font(size: 16, weight: .bold)).foregroundStyle(.white)
                }
            }
            Text(team?.name ?? "TBD").font(RallyFont.font(size: 14, weight: .semibold))
                .foregroundStyle(RallyTheme.textPrimary).lineLimit(1)
        }
    }

    // MARK: Panels (mirror EventStatsPanel / EventLeadersPanel / EventAnalyticsPanel chrome)

    private var matchupPanel: some View {
        panel(title: isLive ? "LIVE STATS" : ev.status == .notStarted ? "MATCHUP PREVIEW" : "MATCHUP STATS", trailing: nil) {
            matchupRow(away: ev.awayTeam, home: ev.homeTeam, label: "TEAMS")
            matchupRowText(away: recordSummary(ev.awayTeam), home: recordSummary(ev.homeTeam), label: "RECORD")
            ForEach(teamStats.prefix(5), id: \.label) { stat in
                matchupRowText(away: stat.awayValue, home: stat.homeValue,
                               label: rallyStatLabel(stat.label).uppercased())
            }
            matchupRowText(away: ev.scoreAway.map(String.init), home: ev.scoreHome.map(String.init), label: "SCORE")
        }
    }

    private var outlookPanel: some View {
        panel(title: "Team Form", trailing: nil) {
            HStack {
                VStack(spacing: 8) {
                    RallyTeamLogo(team: ev.awayTeam, size: 60)
                    Text(rallyTeamName(ev.awayTeam, league: ev.league)).font(RallyFont.font(size: 16, weight: .semibold)).lineLimit(1)
                    Text(recordSummary(ev.awayTeam) ?? "—").foregroundStyle(RallyTheme.textSecondary)
                }
                Spacer()
                Text("VS").foregroundStyle(RallyTheme.textSecondary)
                Spacer()
                VStack(spacing: 8) {
                    RallyTeamLogo(team: ev.homeTeam, size: 60)
                    Text(rallyTeamName(ev.homeTeam, league: ev.league)).font(RallyFont.font(size: 16, weight: .semibold)).lineLimit(1)
                    Text(recordSummary(ev.homeTeam) ?? "—").foregroundStyle(RallyTheme.textSecondary)
                }
            }.padding(.vertical, 8)
            ForEach(formStats, id: \.label) { stat in
                Divider().overlay(RallyTheme.glassBorder)
                HStack { Text(stat.awayValue).bold(); Spacer(); Text(rallyStatLabel(stat.label)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1); Spacer(); Text(stat.homeValue).bold() }.font(RallyFont.font(size: 13))
            }
            if teamStats.isEmpty { Text("Team statistics appear as coverage is published.").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary) }
            if let home = homeWinPct, let away = awayWinPct { Text("WIN PROBABILITY").font(RallyFont.font(size: 9, weight: .semibold)).tracking(1); winProbability(home: home, away: away) }
        }
    }

    private var infoPanel: some View {
        panel(title: "Game Info", trailing: nil) {
            Label(venueName ?? ev.venue ?? "Venue not published", systemImage: "sportscourt").font(RallyFont.font(size: 15, weight: .medium))
            if let venueLocation { Text(venueLocation).foregroundStyle(RallyTheme.textSecondary).padding(.leading, 26) }
            Label(ev.broadcasts.first ?? "Broadcast not published", systemImage: "tv")
            Label(ev.startTime.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            Label("\(rallyTeamName(ev.awayTeam, league: ev.league)) \(recordSummary(ev.awayTeam) ?? "—")  |  \(rallyTeamName(ev.homeTeam, league: ev.league)) \(recordSummary(ev.homeTeam) ?? "—")", systemImage: "person.2")
            if let weatherSummary { Label(weatherSummary, systemImage: "cloud.sun") }
        }.font(RallyFont.font(size: 14))
    }

    private func panel<Content: View>(title: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title.capitalized).font(RallyFont.font(size: 18, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if let trailing {
                    Text(trailing).font(RallyFont.font(size: 9, weight: .bold)).tracking(0.8)
                        .foregroundStyle(RallyTheme.textPrimary)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(RallyTheme.surfaceBase.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RallyTheme.glassBorder, lineWidth: 0.6))
    }

    private func matchupRow(away: Team?, home: Team?, label: String) -> some View {
        HStack {
            HStack(spacing: 7) {
                remoteLogo(away?.logoUrl, fallback: away?.abbreviation ?? "AWY", size: 28)
                Text(away?.abbreviation ?? "AWY")
            }
            .font(RallyFont.font(size: 12, weight: .bold)).foregroundStyle(.white)
            .frame(width: 90, alignment: .leading).lineLimit(1)
            Text(label).font(RallyFont.font(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(RallyTheme.textSecondary).frame(maxWidth: .infinity).lineLimit(1)
            HStack(spacing: 7) {
                Text(home?.abbreviation ?? "HME")
                remoteLogo(home?.logoUrl, fallback: home?.abbreviation ?? "HME", size: 28)
            }
            .font(RallyFont.font(size: 12, weight: .bold)).foregroundStyle(.white)
            .frame(width: 90, alignment: .trailing).lineLimit(1)
        }
        .frame(height: 34)
    }

    private func matchupRowText(away: String?, home: String?, label: String) -> some View {
        HStack {
            Text(away ?? "–").font(RallyFont.font(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 90, alignment: .leading).lineLimit(1)
            Text(label).font(RallyFont.font(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(RallyTheme.textSecondary).frame(maxWidth: .infinity).lineLimit(1)
            Text(home ?? "–").font(RallyFont.font(size: 12, weight: .bold)).foregroundStyle(.white)
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
        HStack(alignment: .top, spacing: 10) {
            remoteLogo(team?.logoUrl, fallback: team?.abbreviation ?? "TBD", size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(team?.name.uppercased() ?? "TBD").font(RallyFont.font(size: 12, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text(recordSummary(team) ?? "No record available")
                    .font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(2)
                if let team {
                    let fav = FavoriteTeam(id: team.id, league: ev.league, name: team.name,
                                           abbreviation: team.abbreviation, logoUrl: team.logoUrl)
                    Button("TEAM CENTER ›") { store.show(.team(fav)) }
                        .font(RallyFont.font(size: 10, weight: .bold)).foregroundStyle(RallyTheme.textPrimary)
                        .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricTile(_ label: String, _ value: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(RallyFont.font(size: 13, weight: .semibold)).foregroundStyle(RallyTheme.textPrimary)
            Text(label).font(RallyFont.font(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(RallyTheme.textTertiary)
            Text(value).font(RallyFont.font(size: 12, weight: .bold)).foregroundStyle(.white).lineLimit(2)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(red: 23/255, green: 36/255, blue: 55/255, opacity: 0.32))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 90/255, green: 120/255, blue: 148/255, opacity: 0.16), lineWidth: 1))
    }

    private func winProbability(home: Double, away: Double) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text("\(ev.awayTeam?.abbreviation ?? "AWY") \(Int(away.rounded()))%")
                Spacer()
                Text("\(Int(home.rounded()))% \(ev.homeTeam?.abbreviation ?? "HME")")
            }
            .font(RallyFont.font(size: 10, weight: .bold)).foregroundStyle(.white)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle().fill(RallyTheme.rallyCyan)
                        .frame(width: geometry.size.width * CGFloat(away / max(1, away + home)))
                    Rectangle().fill(Color.white.opacity(0.24))
                }
            }
            .frame(height: 7).clipShape(Capsule())
        }
        .padding(.top, 5)
    }

    @ViewBuilder
    private func remoteLogo(_ urlString: String?, fallback: String, size: CGFloat) -> some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                Circle().fill(Color.white.opacity(0.08))
            }
            .frame(width: size, height: size).clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                Text(fallback).font(RallyFont.font(size: max(8, size * 0.25), weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }

    private func recordSummary(_ team: Team?) -> String? {
        team?.primaryRecordSummary
    }

    private var statusText: String {
        switch ev.status {
        case .live: "LIVE"; case .halftime: "HALFTIME"; case .finished: "FINAL"
        case .notStarted: "UPCOMING"; case .delayed: "DELAYED"; case .canceled: "CANCELED"
        }
    }
}
