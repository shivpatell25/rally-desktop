import AppKit
import RallyCore
import SwiftUI

func tvArt(_ name: String) -> NSImage? {
    guard let url = Artwork.artURL(name) else { return nil }
    return NSImage(contentsOf: url)
}

/// Signature flare backdrop. Mirrors RallyAmbientSurface: navy base, v5 art,
/// vertical scrim so content stays legible.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            RallyTheme.deepNavy
            if let img = tvArt("rally_ambient_background") {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            }
            LinearGradient(colors: [Color.black.opacity(0.09),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.14),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.66)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}
/// Native liquid glass on macOS 26+, layered-glass fallback below.
extension View {
    @ViewBuilder
    func rallyGlass<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(RallyTheme.glassSurface).clipShape(shape)
        }
    }

    @ViewBuilder
    func bounceOnChange(_ v: Bool) -> some View {
        if #available(macOS 14, *) {
            self.symbolEffect(.bounce, value: v)
        } else {
            self
        }
    }

    /// Floating capsule bar: interactive glass, edge light, drop shadow.
    @ViewBuilder
    func rallyCapsule() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
                .overlay(Capsule().stroke(
                    LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1))
                .shadow(color: Color.black.opacity(0.4), radius: 24, y: 12)
        } else {
            self.background(RallyTheme.glassSurface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(RallyTheme.glassBorder, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.4), radius: 24, y: 12)
        }
    }
}
// MARK: - Destinations (mirrors RallyDestination)

enum TvDestination: Hashable {
    case home, live, leagues, highlights, myTeams
}
// MARK: - Top bar (mirrors RallyTopBar)

struct RallyTopBar: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @Binding var destination: TvDestination
    var onSearch: () -> Void = {}
    var onSettings: () -> Void = {}
    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let url = Artwork.artURL("rally_wordmark"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    .frame(width: 288, height: 58, alignment: .leading)
                } else {
                    Text("rally").font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundStyle(RallyTheme.rallyLime)
                }
            }
            .frame(width: 300, alignment: .leading)
            Spacer()
            HStack(spacing: 0) {
                capsuleItem(icon: "house.fill", label: "Home", dest: .home, dot: false)
                capsuleItem(icon: "dot.radiowaves.left.and.right", label: "Live", dest: .live, dot: true)
                capsuleItem(icon: "square.grid.2x2.fill", label: "Leagues", dest: .leagues, dot: false)
                capsuleItem(icon: "play.rectangle.fill", label: "Highlights", dest: .highlights, dot: false)
                capsuleItem(icon: "star.fill", label: "My Teams", dest: .myTeams, dot: false)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(width: 412)
            .rallyCapsule()
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: destination)
            Spacer()
            HStack(spacing: 12) {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(RallyTheme.textPrimary)
                        .frame(width: 52, height: 52)
                        .rallyGlass(Circle())
                }.buttonStyle(.plain)
                Button(action: onSettings) {
                    Image(systemName: "gearshape").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(RallyTheme.textPrimary)
                        .frame(width: 52, height: 52)
                        .rallyGlass(Circle())
                }.buttonStyle(.plain)
            }
            .frame(width: 300, alignment: .trailing)
        }
        .padding(.leading, m.hPad + 12)
        .padding(.trailing, m.hPad + 12)
        .padding(.top, 20)
        .frame(height: m.s(88) + 20)
    }

    @Namespace private var capsuleMotion

    private func capsuleItem(icon: String, label: String, dest: TvDestination, dot: Bool) -> some View {
        let selected = destination == dest
        return Button { destination = dest } label: {
            VStack(spacing: 4) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? RallyTheme.textPrimary : RallyTheme.textSecondary)
                        .scaleEffect(selected ? 1.12 : 1.0)
                        .bounceOnChange(selected)
                    if dot {
                        Circle().fill(RallyTheme.liveRed).frame(width: 6, height: 6)
                            .offset(x: 12, y: -9)
                    }
                }
                .frame(height: 22)
                Text(label).font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? RallyTheme.textPrimary : RallyTheme.textSecondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 76)
            .padding(.vertical, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "capsule-selection", in: capsuleMotion)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Store derivations (mirrors HomeViewModel state)

enum HeroMode { case closeGame, live, startingSoon, finalRecap, upcoming, empty }

extension RallyStore {
    var liveEvents: [SportEvent] {
        events.filter { $0.status == .live || $0.status == .halftime }
    }

    var upcomingEvents: [SportEvent] {
        let cutoff = Date().addingTimeInterval(-3600)
        return events.filter { $0.status == .notStarted && $0.startTime > cutoff }
    }

    var featuredEvent: SportEvent? {
        liveEvents.first ?? upcomingEvents.first ?? events.first
    }
    var heroMode: HeroMode {
        guard let f = featuredEvent else { return .empty }
        switch f.status {
        case .live, .halftime:
            if let h = f.scoreHome, let a = f.scoreAway, abs(h - a) <= 8 { return .closeGame }
            return .live
        case .finished: return .finalRecap
        case .notStarted:
            return f.startTime < Date().addingTimeInterval(3600) ? .startingSoon : .upcoming
        default: return .upcoming
        }
    }
    var leagueShelves: [(title: String, events: [SportEvent])] {
        settings.sportsOrder.compactMap { league in
            let evs = events.filter { $0.league == league }
            return evs.isEmpty ? nil : (league, evs)
        }
    }
}

// MARK: - Dashboard (mirrors HomeContent)

struct TvHomeDashboard: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @Binding var destination: TvDestination
    @FocusState private var focus: String?
    @State private var livePage = 0
    @State private var sportPage = 0
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                TvHero(featured: store.featuredEvent, mode: store.heroMode, focus: $focus)
                liveShelf
                sportShelf
            }
            .padding(.horizontal, m.hPad)
            .padding(.top, 16).padding(.bottom, 18)
        }
        .onMoveCommand { dir in moveFocus(dir) }
    }

    private func shelfTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .bold)).tracking(2.4)
            .foregroundStyle(RallyTheme.textPrimary)
            .padding(.top, 6)
    }

    private var liveItems: [SportEvent] { Array((store.liveEvents + store.upcomingEvents).prefix(15)) }

    private var liveShelf: some View {
        PagedShelf(title: store.liveEvents.isEmpty ? "UPCOMING" : "LIVE / UPCOMING",
                   items: liveItems, pageSize: 4, aspect: 300.0 / 170.0,
                   idFor: { "live-\($0.id)" }, focus: $focus, page: $livePage) { event, size, focus in
            TvLiveCard(event: event, focus: focus, size: size)
        }
    }

    private var sportShelf: some View {
        PagedShelf(title: "BY SPORT", items: store.leagueShelves, pageSize: 5, aspect: 200.0 / 150.0,
                   idFor: { "sport-\($0.title)" }, focus: $focus, page: $sportPage) { shelf, size, focus in
            TvSportCard(title: shelf.title, events: shelf.events, focus: focus, size: size) {
                store.pendingLeague = shelf.title
                destination = .leagues
            }
        }
    }

    private func liveVisibleIds() -> [String] {
        Array((store.liveEvents + store.upcomingEvents).prefix(15))
            .dropFirst(livePage * 4).prefix(4).map { "live-\($0.id)" }
    }

    private func sportVisibleIds() -> [String] {
        Array(store.leagueShelves.dropFirst(sportPage * 5).prefix(5)).map { "sport-\($0.title)" }
    }

    /// Vertical walk only; PagedShelf owns left/right inside its row.
    /// Hero row keeps left/right between its two buttons.
    private func moveFocus(_ dir: MoveCommandDirection) {
        var rows: [[String]] = []
        rows.append(["hero-watch", "hero-details"])
        rows.append(liveVisibleIds())
        rows.append(sportVisibleIds())
        let flat = rows.enumerated().flatMap { r, ids in ids.map { (r, $0) } }
        guard let cur = focus, let pos = flat.firstIndex(where: { $0.1 == cur }) else {
            focus = rows.first?.first
            return
        }
        let (r, _) = flat[pos]
        let col = rows[r].firstIndex(of: cur) ?? 0
        switch dir {
        case .left where r == 0: focus = rows[r][max(0, col - 1)]
        case .right where r == 0: focus = rows[r][min(rows[r].count - 1, col + 1)]
        case .up: focus = r > 0 ? rows[r - 1][min(col, rows[r - 1].count - 1)] : rows[r][col]
        case .down: focus = r < rows.count - 1 ? rows[r + 1][min(col, rows[r + 1].count - 1)] : rows[r][col]
        default: break
        }
    }
}

// MARK: - Hero (mirrors HomeDashboardHero)

struct TvHero: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    var featured: SportEvent?
    var mode: HeroMode
    var focus: FocusState<String?>.Binding
    @EnvironmentObject var store: RallyStore
    var body: some View {
        ZStack(alignment: .leading) {
            if let img = tvArt(Artwork.heroBackdrop(event: featured)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RallyTheme.surfaceRaised
            }
            // Horizontal scrim (mirrors hero horizontalGradient) + bottom scrim.
            LinearGradient(colors: [Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.91),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.72),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.22),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.03)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .clear,
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.09),
                                    Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.56)],
                           startPoint: .top, endPoint: .bottom)
            if let event = featured {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            heroPill
                            Text(((event.gameStatusDetail?.isEmpty == false ? event.gameStatusDetail : nil)
                                ?? Artwork.displayLeague(event.league)).uppercased())
                                .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                                .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                        }
                        HStack(spacing: 0) {
                            heroTeam(name: event.awayTeam?.name, abbr: event.awayTeam?.abbreviation, logo: event.awayTeam?.logoUrl)
                                .frame(maxWidth: .infinity)
                            VStack(spacing: 2) {
                                Text(scoreText(event)).font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(subText(event)).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                            }
                            .frame(width: m.s(150))
                            heroTeam(name: event.homeTeam?.name, abbr: event.homeTeam?.abbreviation, logo: event.homeTeam?.logoUrl)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: m.s(620))
                        Text([event.venue, event.gameStatusDetail].compactMap { $0?.isEmpty == false ? $0 : nil }
                            .joined(separator: "  ·  ").isEmpty
                            ? Artwork.displayLeague(event.league)
                            : [event.venue, event.gameStatusDetail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "  ·  "))
                            .font(.system(size: 10, weight: .medium)).tracking(0.3)
                            .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                        HStack(spacing: 12) {
                            tvButton(primaryText, primary: true, id: "hero-watch", focus: focus) {
                                store.show(.eventDetail(event))
                            }
                            tvButton("Details", id: "hero-details", focus: focus) {
                                store.show(.eventDetail(event))
                            }
                        }
                    }
                    .padding(.leading, m.s(40)).padding(.vertical, m.s(22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 300)
                }
            }
            if let mark = tvArt("rally_mark_ui") {
                Image(nsImage: mark).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: m.s(30), height: m.s(30))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(22)
            }
        }
        .frame(height: m.heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }

    private var heroPill: some View {
        Group {
            switch mode {
            case .closeGame: livePill("CLOSE GAME")
            case .live: livePill(featured?.gameStatusDetail)
            case .startingSoon: metaPill("STARTING SOON")
            case .finalRecap: metaPill("FINAL RECAP")
            case .upcoming: metaPill("FEATURED")
            case .empty: EmptyView()
            }
        }
    }

    private func livePill(_ detail: String?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(.white).frame(width: 6, height: 6)
            Text(detail?.isEmpty == false ? "LIVE · \(detail!)" : "LIVE")
                .font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RallyTheme.liveRed).clipShape(Capsule())
    }

    private func metaPill(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(1)
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.24)).clipShape(Capsule())
    }

    private func scoreText(_ event: SportEvent) -> String {
        switch event.status {
        case .live, .halftime, .finished:
            return "\(event.scoreAway.map(String.init) ?? "–")  –  \(event.scoreHome.map(String.init) ?? "–")"
        default: return "VS"
        }
    }

    private func subText(_ event: SportEvent) -> String {
        switch event.status {
        case .live, .halftime: return event.gameStatusDetail ?? ""
        case .finished: return "FINAL"
        default:
            return "\(event.startTime.formatted(.dateTime.month(.abbreviated).day())) · \(event.startTime.formatted(.dateTime.hour().minute()))"
        }
    }

    private var primaryText: String {
        guard let event = featured else { return "Browse Live TV" }
        switch event.status {
        case .live, .halftime: return "Watch live"
        case .finished: return "Game center"
        default: return "Game center"
        }
    }

    private func heroTeam(name: String?, abbr: String?, logo: String?) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 15/255, green: 23/255, blue: 36/255, opacity: 0.65))
                    .frame(width: 76, height: 76)
                if let logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                        Text(abbr ?? "TBD").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 62, height: 62)
                } else {
                    Text(abbr ?? "TBD").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
            }
            Text(name ?? "TBD").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RallyTheme.textPrimary).lineLimit(1)
        }
    }

    private func tvButton(_ label: String, primary: Bool = false, id: String, focus: FocusState<String?>.Binding, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary ? Color.black : RallyTheme.textPrimary)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(primary ? RallyTheme.offWhite : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(focus.wrappedValue == id ? RallyTheme.rallyCyan : (primary ? Color.clear : RallyTheme.glassBorder),
                            lineWidth: focus.wrappedValue == id ? 2 : 1))
                .scaleEffect(focus.wrappedValue == id ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .focused(focus, equals: id)
    }
}

// MARK: - Live shelf card (mirrors HomeCompactLiveCard)

struct TvLiveCard: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    var event: SportEvent
    var focus: FocusState<String?>.Binding
    var size: CGSize?
    @EnvironmentObject var store: RallyStore
    private var id: String { "live-\(event.id)" }
    private var isLive: Bool { event.status == .live || event.status == .halftime }
    var body: some View {
        Button { store.show(.eventDetail(event)) } label: {
            ZStack {
                if let img = tvArt(Artwork.shelfBackdrop(event: event)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
                LinearGradient(colors: [Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.15),
                                        Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.47),
                                        Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.91)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    HStack {
                        Text(isLive ? "● LIVE" : "UPCOMING  ·  \(event.startTime.formatted(.dateTime.hour().minute()))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isLive ? RallyTheme.liveRed : RallyTheme.offWhite)
                        Spacer()
                        Text(isLive ? (event.gameStatusDetail?.uppercased() ?? "") : event.startTime.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                            .font(.system(size: 9, weight: .bold)).tracking(0.6)
                            .foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 0) {
                        teamLogo(event.awayTeam?.logoUrl, event.awayTeam?.abbreviation)
                        Spacer()
                        if isLive {
                            HStack(spacing: 8) {
                                Text(event.scoreAway.map(String.init) ?? "–").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                                Text("–").font(.system(size: 17)).foregroundStyle(RallyTheme.textTertiary)
                                Text(event.scoreHome.map(String.init) ?? "–").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                            }
                        } else {
                            Text("VS").font(.system(size: 13, weight: .bold)).tracking(1).foregroundStyle(.white)
                        }
                        Spacer()
                        teamLogo(event.homeTeam?.logoUrl, event.homeTeam?.abbreviation)
                    }
                    Spacer()
                    Text("\(event.awayTeam?.abbreviation ?? Artwork.displayLeague(event.league))   ·   \(event.homeTeam?.abbreviation ?? "")".trimmingCharacters(in: .whitespaces).uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(RallyTheme.offWhite.opacity(0.82)).lineLimit(1)
                }
                .padding(.horizontal, 15).padding(.vertical, 11)
            }
            .frame(width: (size ?? m.liveCard).width, height: (size ?? m.liveCard).height)
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

    private func teamLogo(_ url: String?, _ abbr: String?) -> some View {
        ZStack {
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                    Text((abbr ?? "TBD").prefix(3)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: m.s(44), height: m.s(44))
            } else {
                Text((abbr ?? "TBD").prefix(3)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .frame(width: m.s(44), height: m.s(44))
            }
        }
    }
}

// MARK: - Sport card (mirrors HomeCompactSportCard)

struct TvSportCard: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    var title: String
    var events: [SportEvent]
    var focus: FocusState<String?>.Binding
    var size: CGSize?
    @EnvironmentObject var store: RallyStore
    var onSelect: () -> Void = {}
    private var id: String { "sport-\(title)" }
    private var liveCount: Int { events.count { $0.status == .live || $0.status == .halftime } }
    var body: some View {
        Button(action: onSelect) {
            ZStack {
                if let img = tvArt(Artwork.leagueBackdrop(league: title)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
                LinearGradient(colors: [Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.15),
                                        Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.43),
                                        Color(red: 5/255, green: 8/255, blue: 15/255, opacity: 0.9)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    if liveCount > 0 {
                        Text("●  \(liveCount) LIVE").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(RallyTheme.liveRed)
                            .frame(width: 120, alignment: .leading)
                    } else {
                        Spacer().frame(height: 10)
                    }
                    if let mark = Artwork.leagueMark(league: title), let img = tvArt(mark) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: m.s(72), height: m.s(56))
                    } else {
                        Text(Artwork.leagueShortMark(league: title))
                            .font(.system(size: 22, weight: .bold)).tracking(1)
                            .foregroundStyle(RallyTheme.offWhite)
                            .frame(height: m.s(56))
                    }
                    Spacer()
                    Text(Artwork.displayLeague(title).uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.white).lineLimit(1)
                }
                .padding(12)
            }
            .frame(width: (size ?? m.sportCard).width, height: (size ?? m.sportCard).height)
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
}

// MARK: - LIVE destination

struct TvLiveRow: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @FocusState private var focus: String?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(store.liveEvents) { event in
                    TvLiveCard(event: event, focus: $focus)
                }
            }
            .padding(.horizontal, m.hPad).padding(.vertical, 14)
        }
        .background { AmbientBackground() }
        .overlay { if store.liveEvents.isEmpty { Text("No games in progress").foregroundStyle(RallyTheme.textSecondary) } }
    }
}

// MARK: - HIGHLIGHTS destination (finished games = recaps)

struct TvHighlights: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @FocusState private var focus: String?
    private var recaps: [SportEvent] {
        store.events.filter { $0.status == .finished }.prefix(30).map { $0 }
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(recaps) { event in
                    TvLiveCard(event: event, focus: $focus)
                }
            }
            .padding(.horizontal, m.hPad).padding(.vertical, 14)
        }
        .background { AmbientBackground() }
        .overlay { if recaps.isEmpty { Text("No recaps yet").foregroundStyle(RallyTheme.textSecondary) } }
    }
}

// MARK: - MY TEAMS destination

struct TvMyTeams: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        List {
            ForEach(settings.favoriteTeamProfiles) { team in
                Section(team.name) {
                    let next = store.events.filter {
                        $0.homeTeam?.id == team.id || $0.awayTeam?.id == team.id
                    }.prefix(5)
                    if next.isEmpty {
                        Text("No upcoming games").font(.caption).foregroundStyle(RallyTheme.textTertiary)
                    }
                    ForEach(Array(next)) { event in
                        GameRow(event: event).onTapGesture { store.show(.eventDetail(event)) }
                    }
                }
            }
        }
        .background { AmbientBackground() }
        .overlay {
            if settings.favoriteTeamProfiles.isEmpty {
                Text("Star teams to build your Up Next").foregroundStyle(RallyTheme.textSecondary)
            }
        }
    }
}
