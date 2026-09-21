import RallyCore
import SwiftUI

/// League center. Mirrors LeagueHubDashboard: eyebrow + title + counts,
/// Back/Games/Standings tabs, day pager, portrait game cards.
struct TvLeagueCenter: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    var league: String
    @EnvironmentObject var store: RallyStore
    @State private var tab = 0
    @State private var dayOffset = 0
    @State private var dayEvents: [SportEvent]?
    @State private var loadingDay = false
    @FocusState private var focus: String?

    private var leagueEvents: [SportEvent] {
        store.events.filter { $0.league == league }
    }
    private var teamCount: Int {
        Set(leagueEvents.flatMap { [$0.homeTeam?.id, $0.awayTeam?.id].compactMap { $0 } }).count
    }
    private var standings: [(team: String, record: String)] {
        var map: [String: String] = [:]
        for e in leagueEvents {
            for t in [e.homeTeam, e.awayTeam].compactMap({ $0 }) {
                if map[t.id] == nil, let rec = t.records.first?.summary {
                    map[t.id] = "\(t.name)§\(rec)"
                }
            }
        }
        return map.values.compactMap { v in
            let parts = v.split(separator: "§", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }.sorted { $0.team < $1.team }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RALLY SPORTS · LEAGUE CENTER")
                            .font(.system(size: 11, weight: .bold)).tracking(1.2)
                            .foregroundStyle(RallyTheme.rallyCyan)
                        Text(Artwork.displayLeague(league))
                            .font(.system(size: 40, weight: .black)).tracking(-0.7)
                            .foregroundStyle(.white)
                        Text("\(leagueEvents.count) games · \(teamCount) teams")
                            .font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        leagueButton("Back") { store.pendingLeague = nil }
                        leagueButton("Games", primary: tab == 0) { tab = 0 }
                        if !standings.isEmpty {
                            leagueButton("Standings", primary: tab == 1) { tab = 1 }
                        }
                    }
                }
                .padding(.horizontal, m.hPad).padding(.top, 10)
                if tab == 0 {
                    Text("GAMES").font(.system(size: 15, weight: .black)).tracking(1.6)
                        .foregroundStyle(.white).padding(.horizontal, m.hPad)
                    dayPager
                    if loadingDay {
                        ProgressView().padding(.horizontal, m.hPad)
                    } else if let day = dayEvents, !day.isEmpty {
                        portraitGrid(day)
                    } else {
                        portraitGrid(leagueEvents)
                    }
                } else {
                    Text("STANDINGS").font(.system(size: 15, weight: .black)).tracking(1.6)
                        .foregroundStyle(.white).padding(.horizontal, m.hPad)
                    standingsGrid
                }
            }
            .padding(.bottom, 18)
        }
        .background { AmbientBackground() }
        .task(id: dayOffset) { await loadDay() }
    }

    private var dayPager: some View {
        HStack(spacing: 10) {
            Button("‹") { dayOffset -= 1 }.buttonStyle(.plain)
                .font(.system(size: 20, weight: .bold)).foregroundStyle(RallyTheme.textSecondary)
            ForEach(-1...1, id: \.self) { off in
                let title = off == -1 ? "YESTERDAY" : off == 0 ? "TODAY" : "TOMORROW"
                Button(title) { dayOffset = off }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold)).tracking(0.8)
                    .foregroundStyle(dayOffset == off ? .black : RallyTheme.textSecondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(dayOffset == off ? RallyTheme.offWhite : Color.white.opacity(0.06))
                    .clipShape(Capsule())
            }
            Button("›") { dayOffset += 1 }.buttonStyle(.plain)
                .font(.system(size: 20, weight: .bold)).foregroundStyle(RallyTheme.textSecondary)
        }
        .padding(.horizontal, m.hPad)
    }

    private func loadDay() async {
        guard dayOffset != 0,
              let entry = EspnClient.leagues.first(where: { $0.league == league }) else {
            dayEvents = nil
            return
        }
        loadingDay = true
        defer { loadingDay = false }
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        dayEvents = (try? await EspnClient().fetchScoreboard(sport: entry.sport, league: entry.path,
            domainLeague: league, dates: fmt.string(from: date))) ?? []
    }

    private func portraitGrid(_ events: [SportEvent]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(events) { event in
                    TvPortraitCard(event: event, focus: $focus)
                }
            }
            .padding(.horizontal, m.hPad).padding(.vertical, 6)
        }
    }

    private var standingsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(standings, id: \.team) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text("STANDING").font(.system(size: 9, weight: .bold)).tracking(0.8)
                        .foregroundStyle(RallyTheme.textTertiary)
                    Text(row.team).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Text(row.record).font(.system(size: 12)).foregroundStyle(RallyTheme.rallyCyan)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RallyTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyTheme.glassBorder, lineWidth: 1))
            }
        }
        .padding(.horizontal, m.hPad)
    }

    private func leagueButton(_ label: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary ? RallyTheme.deepNavy : RallyTheme.offWhite)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(primary ? RallyTheme.offWhite : RallyTheme.surfaceRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(primary ? Color.white.opacity(0.72) : RallyTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Portrait game card. Mirrors AppleTvStadiumCard (240x360 proportions).
struct TvPortraitCard: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    var event: SportEvent
    var focus: FocusState<String?>.Binding
    @EnvironmentObject var store: RallyStore
    private var id: String { "portrait-\(event.id)" }
    private var isLive: Bool { event.status == .live || event.status == .halftime }
    private var isFinal: Bool { event.status == .finished }
    var body: some View {
        Button { store.show(.eventDetail(event)) } label: {
            ZStack {
                if let img = tvArt(Artwork.shelfBackdrop(event: event)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
                LinearGradient(colors: [Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.65),
                                        Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.32),
                                        Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.85),
                                        RallyTheme.deepNavy],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Text(((event.gameStatusDetail?.isEmpty == false ? event.gameStatusDetail : nil)
                        ?? Artwork.displayLeague(event.league)).uppercased())
                        .font(.system(size: 11, weight: .bold)).tracking(0.9)
                        .foregroundStyle(RallyTheme.textSecondary)
                    Spacer()
                    Spacer()
                    HStack(spacing: 0) {
                        portraitLogo(event.awayTeam?.logoUrl, event.awayTeam?.abbreviation)
                        Spacer(minLength: 8)
                        if isLive || isFinal {
                            VStack(spacing: 2) {
                                Text(event.scoreAway.map(String.init) ?? "").font(.system(size: 30, weight: .black)).foregroundStyle(.white)
                                Rectangle().fill(Color.white.opacity(0.4)).frame(width: 24, height: 1)
                                Text(event.scoreHome.map(String.init) ?? "").font(.system(size: 30, weight: .black)).foregroundStyle(.white)
                            }
                        } else {
                            Text("AT").font(.system(size: 11, weight: .bold)).tracking(1)
                                .foregroundStyle(RallyTheme.textTertiary)
                        }
                        Spacer(minLength: 8)
                        portraitLogo(event.homeTeam?.logoUrl, event.homeTeam?.abbreviation)
                    }
                    .frame(width: m.s(218))
                    Spacer()
                    Text(event.awayTeam?.name ?? "TBD").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text("at \(event.homeTeam?.name ?? "TBD")").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white).lineLimit(1)
                    if let venue = event.venue, !venue.isEmpty {
                        Text(venue).font(.system(size: 11)).foregroundStyle(RallyTheme.textTertiary)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .frame(width: m.portraitCard.width, height: m.portraitCard.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focus.wrappedValue == id ? RallyTheme.rallyCyan : RallyTheme.glassBorder,
                        lineWidth: focus.wrappedValue == id ? 2 : 1))
            .scaleEffect(focus.wrappedValue == id ? 1.025 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: focus.wrappedValue)
        }
        .buttonStyle(.plain)
        .focused(focus, equals: id)
    }

    private func portraitLogo(_ url: String?, _ abbr: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 15/255, green: 23/255, blue: 36/255, opacity: 0.65))
                .frame(width: m.s(74), height: m.s(74))
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                    Text((abbr ?? "TBD").prefix(3)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: m.s(62), height: m.s(62))
            } else {
                Text((abbr ?? "TBD").prefix(3)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
        }
    }
}

/// Leagues directory. Mirrors LeaguesScreen: header plus five-at-a-time
/// directory cards routing into the league center.
struct TvLeaguesHome: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @FocusState private var focus: String?
    @State private var page = 0
    var body: some View {
        if let pending = store.pendingLeague {
            TvLeagueCenter(league: pending)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LEAGUES").font(.system(size: 11, weight: .bold)).tracking(1.5)
                        .foregroundStyle(RallyTheme.rallyCyan)
                    Text("Every sport. One starting point.").font(.system(size: 27, weight: .black)).tracking(-0.6)
                        .foregroundStyle(.white)
                    Text("Five leagues at a time. Open one for games, standings, and channels.").font(.system(size: 11))
                        .foregroundStyle(RallyTheme.textSecondary)
                }
                .padding(.horizontal, m.hPad).padding(.top, 12)
                .frame(height: 74, alignment: .topLeading)
                PagedShelf(title: nil as String?, items: store.leagueShelves, pageSize: 5, aspect: 1.0,
                           idFor: { $0.title }, focus: $focus, page: $page) { shelf, size, focus in
                    TvDirectoryCard(title: shelf.title, events: shelf.events, focus: focus, size: size) {
                        store.pendingLeague = shelf.title
                    }
                }
                .padding(.horizontal, m.hPad)
                Spacer(minLength: 0)
            }
            .background { AmbientBackground() }
        }
    }
}

struct TvDirectoryCard: View {
    var title: String
    var events: [SportEvent]
    var focus: FocusState<String?>.Binding
    var size: CGSize?
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    var onSelect: () -> Void = {}
    private var id: String { "dir-\(title)" }
    private var hasLive: Bool { events.contains { $0.status == .live || $0.status == .halftime } }
    var body: some View {
        Button(action: onSelect) {
            ZStack {
                if let img = tvArt(Artwork.leagueBackdrop(league: title)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
                LinearGradient(colors: [Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.18),
                                        Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.9)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    HStack {
                        Text("LEAGUE CENTER").font(.system(size: 9, weight: .bold)).tracking(0.8)
                            .foregroundStyle(RallyTheme.textSecondary)
                        Spacer()
                        if hasLive {
                            Text("● LIVE").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(RallyTheme.liveRed)
                        }
                    }
                    Spacer()
                    if let mark = Artwork.leagueMark(league: title), let img = tvArt(mark) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 92, height: 72)
                    } else {
                        Text(Artwork.leagueShortMark(league: title))
                            .font(.system(size: 28, weight: .black)).tracking(1)
                            .foregroundStyle(RallyTheme.offWhite)
                            .frame(height: 72)
                    }
                    Spacer()
                    Text(Artwork.displayLeague(title).uppercased())
                        .font(.system(size: 14, weight: .black)).tracking(0.5)
                        .foregroundStyle(.white).lineLimit(1)
                    Text(events.isEmpty ? "OPEN LEAGUE CENTER" : "\(events.count) GAMES")
                        .font(.system(size: 9, weight: .bold)).tracking(0.7)
                        .foregroundStyle(focus.wrappedValue == id ? RallyTheme.rallyCyan : RallyTheme.textSecondary)
                }
                .padding(15)
            }
            .frame(width: (size ?? CGSize(width: 220, height: 220)).width,
                   height: (size ?? CGSize(width: 220, height: 220)).height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focus.wrappedValue == id ? RallyTheme.rallyCyan : Color(red: 56/255, green: 120/255, blue: 148/255, opacity: 0.22),
                        lineWidth: focus.wrappedValue == id ? 2 : 1))
            .scaleEffect(focus.wrappedValue == id ? 1.025 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: focus.wrappedValue)
        }
        .buttonStyle(.plain)
        .focused(focus, equals: id)
    }
}
