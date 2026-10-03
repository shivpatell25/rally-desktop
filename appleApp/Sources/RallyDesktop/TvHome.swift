import AppKit
import RallyCore
import SwiftUI

private let rallyArtCache = NSCache<NSString, NSImage>()
func tvArt(_ name: String) -> NSImage? {
    if let cached = rallyArtCache.object(forKey: name as NSString) { return cached }
    guard let url = Artwork.artURL(name) else { return nil }
    guard let image = NSImage(contentsOf: url) else { return nil }
    rallyArtCache.countLimit = 32
    rallyArtCache.setObject(image, forKey: name as NSString)
    return image
}

/// Window-filling ambient surface. Full-window destinations share the single
/// instance owned by ContentView so artwork never re-crops below the toolbar.
struct AmbientBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black
                if let image = tvArt("rally_tv_background_v8") {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped().opacity(0.42)
                }
            }
        }.allowsHitTesting(false).ignoresSafeArea()
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
    case home, live, schedule, leagues, highlights, myTeams
}
// MARK: - Store derivations (mirrors HomeViewModel state)

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
    var leagueShelves: [(title: String, events: [SportEvent])] {
        let ordered = settings.sportsOrder.filter { settings.isLeagueEnabled($0) }
        let extras = Set(events.map(\.league)).subtracting(ordered).sorted()
        return (ordered + extras).map { league in
            (league, events.filter { $0.league == league })
        }
    }
}

// MARK: - Live shelf card (mirrors HomeCompactLiveCard)

struct TvLiveCard: View {
    @Environment(\.tvMetrics) private var m
    var event: SportEvent
    var focus: FocusState<String?>.Binding
    var size: CGSize?
    var onSelect: (() -> Void)?
    @EnvironmentObject var store: RallyStore
    @State private var hovered = false
    private var id: String { "live-\(event.id)" }
    private var active: Bool { focus.wrappedValue == id || hovered }
    var body: some View {
        let dimensions = size ?? m.liveCard
        Button { if let onSelect { onSelect() } else { store.show(.eventDetail(event)) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    RallyMatchupArtwork(event: event)
                    if [.live, .halftime].contains(event.status) {
                        HStack(spacing: 6) { Circle().fill(RallyTheme.liveRed).frame(width: 7, height: 7); Text("LIVE").font(RallyFont.font(size: 11, weight: .semibold)).foregroundStyle(RallyTheme.liveRed) }.padding(12)
                    }
                }.frame(width: dimensions.width, height: dimensions.height).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? .white.opacity(0.55) : .white.opacity(0.1), lineWidth: 0.7))
                    .padding(.bottom, 6)
                Text(event.rallyMatchup).font(RallyFont.font(size: m.cardTitleSize, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 10) { Text(event.rallyMetadata).lineLimit(1) }.font(RallyFont.font(size: m.bodySize)).foregroundStyle(RallyTheme.textSecondary)
            }.frame(width: dimensions.width, alignment: .leading)
                .brightness(hovered ? 0.035 : 0).offset(y: hovered ? -2 : 0)
                .rallyAnimation(.easeOut(duration: 0.16), value: hovered)
        }.buttonStyle(.plain).focused(focus, equals: id).onHover { hovered = $0 }
        .accessibilityLabel("\(event.rallyMatchup), \(event.rallyMetadata)")
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
    @State private var hovered = false
    var onSelect: () -> Void = {}
    private var id: String { "sport-\(title)" }
    private var liveCount: Int { events.count { $0.status == .live || $0.status == .halftime } }
    private var active: Bool { focus.wrappedValue == id || hovered }
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
                        Text("●  \(liveCount) LIVE").font(RallyFont.font(size: 9, weight: .bold))
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
                            .font(RallyFont.font(size: 22, weight: .bold)).tracking(1)
                            .foregroundStyle(RallyTheme.offWhite)
                            .frame(height: m.s(56))
                    }
                    Spacer()
                    Text(Artwork.displayLeague(title).uppercased())
                        .font(RallyFont.font(size: 10, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.white).lineLimit(1)
                }
                .padding(12)
            }
            .frame(width: (size ?? m.sportCard).width, height: (size ?? m.sportCard).height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(active ? RallyTheme.rallyCyan : RallyTheme.glassBorder,
                        lineWidth: active ? 2 : 1))
            .scaleEffect(active ? RallyTheme.cardFocusScale : 1)
            .rallyAnimation(.spring(response: 0.3, dampingFraction: 0.75), value: active)
        }
        .buttonStyle(.plain)
        .focused(focus, equals: id)
        .onHover { hovered = $0 }
    }
}

// MARK: - LIVE destination

// MARK: - HIGHLIGHTS destination (event-linked clips, mirrors HighlightsScreen)

struct TvHighlights: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @FocusState private var focus: String?
    @State private var page = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: m.sectionSpacing) {
                RallyPageHeader(
                    eyebrow: "Highlights",
                    title: "The biggest moments, right now.",
                    subtitle: "Event-linked clips from supported leagues."
                )
                if store.highlights.isEmpty && !store.highlightsLoading {
                    RallyEmptyState(
                        eyebrow: "Recent coverage",
                        title: "No league clips have been published yet.",
                        message: "This page fills automatically as supported leagues release highlights."
                    )
                } else {
                    PagedShelf(title: nil as String?, items: store.highlights,
                               pageSize: m.layout == .compact ? 3 : 4,
                               aspect: 320.0 / 235.0,
                               idFor: { $0.id }, focus: $focus, page: $page) { item, size, focus in
                        TvHighlightCard(item: item, focus: focus, size: size)
                    }
                }
            }
            .frame(maxWidth: m.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, m.hPad)
            .padding(.top, m.pageTopPadding)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .overlay { if store.highlightsLoading && store.highlights.isEmpty { ProgressView() } }
        .task { await store.refreshHighlights() }
    }
}

struct TvHighlightCard: View {
    var item: GameHighlight
    var focus: FocusState<String?>.Binding
    var size: CGSize?
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @State private var hovered = false
    private var id: String { item.id }
    private var active: Bool { focus.wrappedValue == id || hovered }
    var body: some View {
        RallyClipCard(clip: item.clip, width: size?.width ?? m.mediaWidth, aspect: 2.65, metadata: "\(item.event.league) · \(item.event.rallyMatchup)") {
            if item.clip.streamUrl != nil { store.show(.player(event: item.event, channel: nil, clip: item.clip)) }
            else { store.show(.eventDetail(item.event)) }
        }.focused(focus, equals: id)
    }
}

// MARK: - MY TEAMS destination

struct TvMyTeams: View {
    @Environment(\.tvMetrics) private var m: TvMetrics
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore

    /// Games for favorites, soonest first (WatchlistViewModel). Matched on
    /// league:id — bare ESPN ids collide across leagues (e.g. id 1 is
    /// Falcons, Orioles, and Bruins in different leagues).
    private var gamesForYou: [SportEvent] {
        let keys = Set(settings.favoriteTeamProfiles.map(\.key))
        return store.events.filter {
            guard let h = $0.homeTeam?.id, let a = $0.awayTeam?.id else { return false }
            return keys.contains("\($0.league):\(h)") || keys.contains("\($0.league):\(a)")
        }.sorted { $0.startTime < $1.startTime }
    }
    private var savedGames: [SportEvent] {
        var seen = Set<String>()
        return (store.events + settings.savedEvents).filter { settings.savedEventIds.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.startTime < $1.startTime }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: m.sectionSpacing) {
                RallyPageHeader(
                    eyebrow: "My Rally",
                    title: "My Rally",
                    subtitle: "Follow favorites and jump directly into their team centers."
                )
                if settings.favoriteTeamProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        RallyEmptyState(
                            eyebrow: "Make Rally yours",
                            title: "Choose your favorite teams.",
                            message: "Their upcoming games, results, and team centers will appear here."
                        )
                        Button("Choose teams") { store.show(.settings) }
                            .font(RallyFont.font(size: m.cardTitleSize, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(RallyTheme.offWhite)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .buttonStyle(.plain)
                    }
                } else {
                    Text("Your Teams")
                        .font(RallyFont.font(size: m.sectionTitleSize, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(RallyTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(settings.favoriteTeamProfiles) { team in
                        Button { store.show(.team(team)) } label: {
                            HStack(spacing: 14) {
                                if let logo = team.logoUrl, let link = URL(string: logo) {
                                    AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                                        Color.clear
                                    }
                                    .frame(width: 44, height: 44)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(team.name)
                                        .font(RallyFont.font(size: m.cardTitleSize, weight: .bold))
                                        .foregroundStyle(.white)
                                    Text(team.league)
                                        .font(RallyFont.font(size: m.eyebrowSize, weight: .bold))
                                        .tracking(0.7)
                                        .foregroundStyle(RallyTheme.textPrimary)
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .rallySurface(padding: 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !settings.savedEventIds.isEmpty {
                    Text("Watchlist").font(RallyFont.font(size: m.sectionTitleSize, weight: .bold))
                    ForEach(savedGames) { event in RallyEventRow(event: event) }
                }
                if !gamesForYou.isEmpty {
                    Text("Your Games")
                        .font(RallyFont.font(size: m.sectionTitleSize, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(RallyTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(gamesForYou.prefix(20)) { event in
                        RallyEventRow(event: event)
                    }
                }
            }
            .frame(maxWidth: m.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, m.hPad)
            .padding(.top, m.pageTopPadding)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }.task { await store.refreshSavedEvents() }
    }
}
