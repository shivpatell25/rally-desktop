import RallyCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.tvMetrics) private var m
    @State private var progress: CGFloat = 0
    @State private var guideRequested = false
    @State private var livePage = 0
    @State private var venueImageURL: String?
    @FocusState private var focus: String?
    private var upcoming: [SportEvent] { Array(store.upcomingEvents.sorted { $0.startTime < $1.startTime }.prefix(4)) }
    private let sports = ["NFL", "NBA", "MLB", "NHL", "NCAAF", "NCAAB", "MLS", "UFC", "Soccer", "Tennis"]
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Group {
                        if let featured = store.featuredEvent { RallyHero(event: featured, venueImageURL: venueImageURL) }
                        else if store.isLoading { ProgressView("Loading Rally…").frame(maxWidth: .infinity).frame(height: m.heroHeight) }
                        else { RallyEmptyState(eyebrow: "Home", title: "The sports feed is unavailable.", message: "Your saved teams and sources are safe. Try refreshing."); Button("Try Again") { Task { await store.refresh() } }.buttonStyle(RallyActionStyle()) }
                    }.id("home-top")
                    liveShelf.id("home-live")
                    if !upcoming.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            RallySectionTitle(title: progress < 0.5 ? "Starting Soon" : (upcoming.allSatisfy { Calendar.current.isDateInToday($0.startTime) } ? "Tonight’s Schedule" : "Upcoming Schedule"), actionTitle: "See Full Schedule") { store.navigate(.schedule) }
                            RallyUpcomingMorph(events: upcoming, progress: progress, focus: $focus)
                        }.onMoveCommand { direction in
                            if direction == .down, focus?.hasPrefix("soon-") == true, !guideRequested {
                                guideRequested = true
                                withAnimation(.easeInOut(duration: 0.3)) { progress = 1; reader.scrollTo("home-live", anchor: .top) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        RallySectionTitle(title: "Browse by Sport")
                        let columns = m.contentWidth >= 1050 ? 10 : 5
                        let width = (m.contentWidth - CGFloat(columns - 1) * 10) / CGFloat(columns)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 10), count: columns), spacing: 10) {
                            ForEach(sports, id: \.self) { league in
                                RallyLeagueShortcut(league: league, width: width) { store.pendingLeague = league; store.navigate(.leagues) }
                            }
                        }
                    }.padding(.top, 2).opacity(Double(progress)).disabled(progress < 0.7).accessibilityHidden(progress < 0.7)
                    if store.sportsStatus.contains("Cached") || store.sportsStatus.contains("Offline") { Label(store.sportsStatus, systemImage: "wifi.slash").font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary) }
                }.background(RallyScrollObserver { offset in
                    let next = min(1, max(0, offset / max(1, m.heroHeight + 22)))
                    if !guideRequested { progress = next }
                    if offset <= 2 { guideRequested = false; progress = 0 }
                }.frame(width: 0, height: 0))
                    .padding(.horizontal, m.hPad).padding(.bottom, 28)
                    .frame(minHeight: m.height - (m.width < 1050 ? 76 : 90) + m.heroHeight + 22, alignment: .top)
                    .frame(maxWidth: m.contentMaxWidth + m.hPad * 2).frame(maxWidth: .infinity)
            }.coordinateSpace(name: "home-scroll")
                .onChange(of: store.homeReset) { _ in
                    guideRequested = false
                    withAnimation(.easeInOut(duration: 0.28)) { progress = 0; reader.scrollTo("home-top", anchor: .top) }
                }
                .task(id: store.featuredEvent?.id) {
                    venueImageURL = store.featuredEvent?.venueImageUrl
                    guard !LaunchArgs.visualFixture, let event = store.featuredEvent, let path = EspnClient.path(forLeague: event.league) else { return }
                    let detail = await store.espnClient.fetchSummary(sport: path.sport, league: path.path, eventId: event.id)
                    guard !Task.isCancelled else { return }
                    venueImageURL = detail.venueImageUrl
                }
                .task(id: store.liveEvents.isEmpty) { if !LaunchArgs.visualFixture && store.liveEvents.isEmpty { await store.refreshHighlights() } }
        }
    }
    private var liveShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            RallySectionTitle(title: store.liveEvents.isEmpty ? "Recent Highlights" : "Live Now") { store.navigate(store.liveEvents.isEmpty ? .highlights : .live) }
            if !store.liveEvents.isEmpty {
                PagedShelf(title: nil, items: store.liveEvents, pageSize: 3, aspect: 2.65, idFor: { "live-\($0.id)" }, focus: $focus, page: $livePage) { event, size, focus in
                    TvLiveCard(event: event, focus: focus, size: size)
                }
            } else if !store.highlights.isEmpty {
                PagedShelf(title: nil, items: store.highlights, pageSize: 3, aspect: 2.65, idFor: { $0.id }, focus: $focus, page: $livePage) { item, size, focus in
                    TvHighlightCard(item: item, focus: focus, size: size)
                }
            } else {
                HStack(spacing: m.cardSpacing) {
                    ForEach(0..<3) { _ in
                        Button { store.navigate(.highlights) } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                ZStack { RoundedRectangle(cornerRadius: 8).fill(RallyTheme.surfaceBase.opacity(0.55)); Label(store.highlightsLoading ? "Loading highlights…" : "Browse Highlights", systemImage: "play.fill").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary) }.frame(height: m.mediaWidth / 2.65)
                                Text("Recent coverage").font(RallyFont.font(size: 14)).foregroundStyle(RallyTheme.textSecondary)
                            }.frame(width: m.mediaWidth)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Each event is rendered once. Its time, marks, matchup and reminder move from
/// the four-column preview into four full-width rows as the same page scrolls.
struct RallyUpcomingMorph: View {
    let events: [SportEvent]
    var progress: CGFloat
    var focus: FocusState<String?>.Binding
    @EnvironmentObject private var store: RallyStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.tvMetrics) private var m
    private let compactHeight: CGFloat = 80
    private let rowHeight: CGFloat = 54
    var body: some View {
        GeometryReader { geo in
            let columns: CGFloat = 4
            let slot = geo.size.width / columns
            let p = min(1, max(0, progress))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).stroke(RallyTheme.glassBorder.opacity(Double(p)), lineWidth: 0.7)
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    let compactX = CGFloat(index) * slot
                    let rowWidth = slot + (geo.size.width - slot) * p
                    HStack(spacing: 0) {
                        Button { store.show(.eventDetail(event)) } label: {
                            ZStack(alignment: .topLeading) {
                                Text(event.startTime.formatted(.dateTime.hour().minute())).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                                    .offset(x: 10 + 6 * p, y: 2 + 15 * p)
                                HStack(spacing: 8) { RallyTeamLogo(team: event.awayTeam, size: 30); RallyTeamLogo(team: event.homeTeam, size: 30) }
                                    .offset(x: 10 + (geo.size.width * 0.14 - 10) * p, y: 27 - 17 * p)
                                Text(event.rallyMatchup).font(RallyFont.font(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                                    .frame(width: max(80, (slot - 106) + (geo.size.width * 0.45 - slot + 106) * p), alignment: .leading)
                                    .offset(x: 88 + (geo.size.width * 0.3 - 88) * p, y: 28 - 11 * p)
                                Text(event.league).font(RallyFont.font(size: 10)).foregroundStyle(RallyTheme.textSecondary)
                                    .offset(x: 88 + (geo.size.width * 0.78 - 88) * p, y: 58 - 39 * p)
                            }.frame(width: rowWidth - 36 * p, height: compactHeight + (rowHeight - compactHeight) * p, alignment: .topLeading).contentShape(Rectangle())
                        }.buttonStyle(.plain).focused(focus, equals: "soon-\(event.id)")
                        if p > 0.05 {
                            Button { settings.toggleSavedEvent(event) } label: { Image(systemName: settings.savedEventIds.contains(event.id) ? "bell.fill" : "bell").foregroundStyle(RallyTheme.textSecondary) }
                                .buttonStyle(.plain).frame(width: 36 * p).opacity(Double(p)).help("Save game / reminder")
                        }
                    }.background(RallyTheme.surfaceBase.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
                        .offset(x: compactX * (1 - p), y: CGFloat(index) * rowHeight * p)
                }
            }
        }.frame(height: compactHeight + (CGFloat(events.count) * rowHeight - compactHeight) * progress)
    }
}

struct RallyHero: View {
    let event: SportEvent
    var detailed = false
    var venueImageURL: String?
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.tvMetrics) private var m
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ZStack {
                    if let image = tvArt(Artwork.heroBackdrop(event: event)) { Image(nsImage: image).resizable().scaledToFill() }
                    if let string = venueImageURL ?? event.venueImageUrl, let url = URL(string: string) {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    }
                }.frame(width: proxy.size.width * 0.76, height: proxy.size.height + 32).clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.3), location: 0.2), .init(color: .white, location: 0.56), .init(color: .white, location: 0.92), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.15), .init(color: .white, location: 0.68), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .opacity(0.8).frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        Text(event.league).foregroundStyle(RallyTheme.textSecondary)
                        Text("·").foregroundStyle(RallyTheme.textSecondary)
                        if [.live, .halftime].contains(event.status) { Circle().fill(RallyTheme.liveRed).frame(width: 7, height: 7) }
                        Text(status).foregroundStyle([.live, .halftime].contains(event.status) ? RallyTheme.liveRed : RallyTheme.textSecondary)
                    }.font(RallyFont.font(size: 14, weight: .medium))
                    Text(event.rallyMatchup).font(RallyFont.display(m.width < 1000 ? 31 : 42)).tracking(-0.65)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(scoreSummary).font(RallyFont.font(size: m.width < 1000 ? 16 : 19, weight: .medium)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    if let venue = event.venue { Text(venue).font(RallyFont.font(size: 13)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1) }
                    HStack(spacing: 12) {
                        if [.live, .halftime].contains(event.status) {
                            Button { store.show(.player(event: event, channel: nil)) } label: { Label("Watch Live", systemImage: "play.fill") }.buttonStyle(RallyActionStyle(primary: true))
                        }
                        if detailed {
                            Button { settings.toggleSavedEvent(event) } label: {
                                Label(settings.savedEventIds.contains(event.id) ? "In Watchlist" : "Add to Watchlist", systemImage: settings.savedEventIds.contains(event.id) ? "checkmark" : "plus")
                            }.buttonStyle(RallyActionStyle())
                            Menu("More") {
                                Button("Pick Source") { store.show(.player(event: event, channel: nil, picker: true)) }
                                ForEach([event.awayTeam, event.homeTeam].compactMap { $0 }, id: \.id) { team in
                                    Button(team.name) { store.show(.team(FavoriteTeam(id: team.id, league: event.league, name: team.name, abbreviation: team.abbreviation, logoUrl: team.logoUrl))) }
                                    Button((settings.isFavoriteTeam(id: team.id, league: event.league) ? "Unfollow " : "Follow ") + team.name) { _ = settings.toggleFavoriteTeam(FavoriteTeam(id: team.id, league: event.league, name: team.name, abbreviation: team.abbreviation, logoUrl: team.logoUrl)) }
                                }
                            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.white)
                        } else {
                            Button("More Info") { store.show(.eventDetail(event)) }.buttonStyle(RallyActionStyle(primary: ![.live, .halftime].contains(event.status)))
                            if ![.live, .halftime].contains(event.status) { Button("Full Schedule") { store.destination = .schedule }.buttonStyle(RallyActionStyle()) }
                        }
                    }.padding(.top, 10)
                }.foregroundStyle(.white).frame(width: min(proxy.size.width * 0.66, 740), alignment: .leading)
                    .padding(.leading, 8)
            }
        }.frame(height: m.heroHeight).clipped()
    }
    private var status: String {
        switch event.status { case .live: "LIVE"; case .halftime: "HALFTIME"; case .finished: "FINAL"; case .notStarted: "UPCOMING"; case .delayed: "DELAYED"; case .canceled: "CANCELED" }
    }
    private var scoreSummary: String {
        if [.live, .halftime, .finished].contains(event.status) {
            return "\(event.awayTeam?.abbreviation ?? "") \(event.scoreAway.map(String.init) ?? "—") — \(event.homeTeam?.abbreviation ?? "") \(event.scoreHome.map(String.init) ?? "—")   |   \(event.gameStatusDetail ?? status)"
        }
        return event.startTime.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}
struct RallyStartingSoon: View {
    let event: SportEvent
    @EnvironmentObject private var store: RallyStore
    var body: some View {
        Button { store.show(.eventDetail(event)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(event.startTime.formatted(.dateTime.hour().minute())).font(RallyFont.font(size: 13)).foregroundStyle(RallyTheme.textSecondary)
                HStack(spacing: 10) {
                    RallyTeamLogo(team: event.awayTeam, size: 36)
                    RallyTeamLogo(team: event.homeTeam, size: 36)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.rallyMatchup).font(RallyFont.font(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                        Text(event.league).font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                .overlay(alignment: .trailing) { Rectangle().fill(RallyTheme.glassBorder).frame(width: 1) }
        }.buttonStyle(.plain)
    }
}
struct RallyActionStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(RallyFont.font(size: 14, weight: .medium))
            .padding(.horizontal, 22).padding(.vertical, 13)
            .foregroundStyle(primary ? .black : .white)
            .background(primary ? RallyTheme.offWhite : RallyTheme.surfaceBase.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(primary ? Color.clear : RallyTheme.glassBorder, lineWidth: 0.6))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
