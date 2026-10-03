import AppKit
import RallyCore
import SwiftUI

struct RallyNavigation: View {
    @ObservedObject var store: RallyStore
    @Environment(\.tvMetrics) private var m
    private let tabs: [(String, TvDestination)] = [("Home", .home), ("Live", .live), ("Schedule", .schedule), ("Leagues", .leagues), ("Highlights", .highlights), ("My Rally", .myTeams)]
    var body: some View {
        HStack(spacing: m.width < 1050 ? 14 : 24) {
            Button { store.navigate(.home) } label: {
                if let image = tvArt("rally_wordmark") { Image(nsImage: image).resizable().scaledToFit().frame(width: m.width < 1050 ? 106 : 144, height: 42) }
            }.buttonStyle(.plain).accessibilityLabel("Rally Home")
            Spacer(minLength: 0)
            HStack(spacing: m.width < 1050 ? 2 : 10) {
                ForEach(tabs, id: \.0) { title, value in
                    Button { store.navigate(value) } label: {
                        Text(title).font(RallyFont.font(size: m.width < 1050 ? 13 : 17, weight: store.destination == value ? .medium : .regular))
                            .foregroundStyle(store.destination == value ? .white : RallyTheme.textSecondary).fixedSize()
                            .padding(.horizontal, m.width < 1050 ? 8 : 14).padding(.vertical, 10)
                            .background { if store.destination == value { RallySelectionSurface() } }
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityIdentifier("rally.navigation.\(value)")
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: m.width < 1050 ? 16 : 24) {
                Button { store.show(.search) } label: { Image(systemName: "magnifyingglass") }.help("Search (⌘F)")
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings (⌘,)")
            }.font(RallyFont.font(size: 20)).foregroundStyle(.white).buttonStyle(.plain)
        }.padding(.horizontal, m.hPad).frame(height: m.width < 1050 ? 76 : 90)
    }
}
let rallyAccent = LinearGradient(colors: [RallyTheme.rallyLime, RallyTheme.rallyMint, RallyTheme.rallyCyan], startPoint: .leading, endPoint: .trailing)
struct RallySelectionSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2), lineWidth: 0.7))
    }
}
struct RallyTabs<Value: Hashable>: View {
    let items: [(String, Value)]
    @Binding var selection: Value
    var compact = false
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 2 : 8) {
                ForEach(items, id: \.1) { title, value in
                    Button { selection = value } label: {
                        Text(title).font(RallyFont.font(size: compact ? 11 : 15, weight: selection == value ? .semibold : .regular))
                            .foregroundStyle(selection == value ? .white : RallyTheme.textSecondary).fixedSize()
                            .padding(.horizontal, compact ? 10 : 16).padding(.vertical, compact ? 9 : 10)
                            .background { if selection == value { RallySelectionSurface() } }
                    }.buttonStyle(.plain).accessibilityLabel(title)
                }
            }.padding(.vertical, 2)
        }.rallyAnimation(.easeOut(duration: 0.15), value: selection)
    }
}
struct RallySectionTitle: View {
    let title: String
    var actionTitle = "See All"
    var action: (() -> Void)?
    @Environment(\.tvMetrics) private var m
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(RallyFont.font(size: 13, weight: .semibold)).tracking(1.65).foregroundStyle(RallyTheme.textSecondary).padding(.leading, 8)
            Spacer()
            if let action {
                Button(action: action) { HStack(spacing: 8) { Text(actionTitle.uppercased()).tracking(1.15); Image(systemName: "chevron.right") } }
                    .font(RallyFont.font(size: 13)).foregroundStyle(RallyTheme.textSecondary).buttonStyle(.plain)
            }
        }
    }
}
struct RallyTeamLogo: View {
    let team: Team?
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let string = team?.logoUrl, let url = URL(string: string) {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
            } else {
                Text(team?.abbreviation ?? "—").font(RallyFont.font(size: size / 3, weight: .semibold)).foregroundStyle(RallyTheme.textSecondary)
            }
        }.frame(width: size, height: size)
    }
}
struct RallyLeagueMark: View {
    let league: String
    var size: CGFloat = 38
    var body: some View {
        Group {
            if let name = Artwork.leagueMark(league: league), let image = tvArt(name) {
                Image(nsImage: image).renderingMode(league == "Champions League" ? .template : .original).resizable().scaledToFit().foregroundStyle(.white)
            } else if league == "NCAAF" || league == "NCAAB" {
                ZStack { Circle().fill(Color(red: 0.07, green: 0.38, blue: 0.78)); Text("NCAA").font(RallyFont.font(size: size * 0.2, weight: .black)).foregroundStyle(.white) }
            } else if league == "Soccer" {
                Image(systemName: "soccerball").resizable().scaledToFit().foregroundStyle(.white)
            } else if league == "Tennis" {
                Image(systemName: "tennisball.fill").resizable().scaledToFit().foregroundStyle(Color(red: 0.73, green: 0.87, blue: 0.36))
            } else { Text(Artwork.leagueShortMark(league: league)).font(RallyFont.font(size: size * 0.36, weight: .bold)) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct RallyLeagueShortcut: View {
    let league: String
    var compact = false
    var width: CGFloat = 124
    var action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 6 : 8) {
                RallyLeagueMark(league: league, size: compact ? 28 : 38)
                Text(league.uppercased()).font(RallyFont.font(size: compact ? 9 : 10, weight: .medium)).tracking(0.8).lineLimit(1)
            }.foregroundStyle(.white).frame(width: width, height: compact ? 58 : 78)
                .background(LinearGradient(colors: [.white.opacity(hover || focused ? 0.12 : 0.035), .black.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(hover || focused ? 0.45 : 0.12), lineWidth: 0.7))
                .scaleEffect(hover || focused ? 1.025 : 1)
        }.buttonStyle(.plain).focused($focused).onHover { hover = $0 }.rallyAnimation(.easeOut(duration: 0.14), value: hover || focused)
    }
}
struct RallyMediaRail: View {
    let title: String
    let events: [SportEvent]
    var action: (() -> Void)?
    @Environment(\.tvMetrics) private var m
    @EnvironmentObject private var store: RallyStore
    @EnvironmentObject private var settings: SettingsStore
    @FocusState private var focus: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RallySectionTitle(title: title, action: action)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: m.cardSpacing) {
                    ForEach(events) { event in
                        TvLiveCard(event: event, focus: $focus, size: m.liveCard, onSelect: { store.show(.eventDetail(event)) })
                            .contextMenu {
                                Button("Watch") { store.show(.player(event: event, channel: nil)) }
                                Button(settings.savedEventIds.contains(event.id) ? "Remove from Watchlist" : "Add to Watchlist") { settings.toggleSavedEvent(event) }
                            }
                    }
                } .padding(.vertical, 6)
            }
        }
    }
}
extension SportEvent {
    var rallyMatchup: String {
        guard let away = awayTeam, let home = homeTeam else { return name }
        return "\(rallyTeamName(away, league: league)) vs \(rallyTeamName(home, league: league))"
    }
    var rallyMetadata: String {
        if status == .notStarted { return "\(league)  ·  \(startTime.formatted(.dateTime.hour().minute()))" }
        return "\(league)  ·  \(gameStatusDetail ?? status.rawValue.capitalized)"
    }
}
func rallyTeamName(_ team: Team?, league: String) -> String {
    guard let team else { return "TBD" }
    guard ["NFL", "NBA", "MLB", "NHL"].contains(league) else { return team.name }
    let compound = ["Trail Blazers", "Red Sox", "White Sox", "Blue Jays", "Red Wings", "Blue Jackets", "Golden Knights", "Maple Leafs"]
    if let name = compound.first(where: { team.name.hasSuffix($0) }) { return name }
    return team.name.split(separator: " ").last.map(String.init) ?? team.name
}

/// Let macOS own window controls while Rally owns the visible canvas.
struct RallyWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { apply(view.window) }; return view }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { apply(view.window) } }
    private func apply(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 5/255, green: 5/255, blue: 7/255, alpha: 1)
    }
}

struct RallyClipCard: View {
    var clip: HighlightClip
    var width: CGFloat = 300
    var aspect: CGFloat = 16.0 / 9.0
    var metadata: String?
    var onSelect: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    if let value = clip.thumbnailUrl, let url = URL(string: value) {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { RallyTheme.surfaceRaised }.frame(width: width, height: width / aspect).clipped()
                    } else { RallyTheme.surfaceRaised }
                    if let duration = clip.durationSeconds {
                        Text("\(duration / 60):\(String(format: "%02d", duration % 60))").font(RallyFont.font(size: 11, weight: .medium))
                            .padding(5).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).padding(8)
                    }
                }.frame(width: width, height: width / aspect).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                    .brightness(hovered ? 0.035 : 0)
                Text(clip.title).font(RallyFont.font(size: 15, weight: .semibold)).lineLimit(2).frame(height: 38, alignment: .top)
                if let text = metadata ?? clip.description, text != clip.title {
                    Text(text).font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                }
            }.frame(width: width, alignment: .leading).foregroundStyle(.white).offset(y: hovered ? -2 : 0)
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}

struct RallyMatchupArtwork: View {
    let event: SportEvent
    var scoreOverride: String?
    private func teamColor(_ team: Team?) -> Color {
        guard let raw = team?.colors.first else { return Color(red: 0.19, green: 0.21, blue: 0.24) }
        let hex = raw.replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(hex, radix: 16), hex.count == 6 else { return Color(white: 0.2) }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(stops: [.init(color: teamColor(event.awayTeam), location: 0), .init(color: teamColor(event.awayTeam).opacity(0.8), location: 0.3), .init(color: teamColor(event.homeTeam).opacity(0.8), location: 0.7), .init(color: teamColor(event.homeTeam), location: 1)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.52)], startPoint: .top, endPoint: .bottom)
                HStack(spacing: 0) {
                    RallyTeamLogo(team: event.awayTeam, size: min(74, geo.size.height * 0.5)).frame(maxWidth: .infinity)
                    if [.live, .halftime, .finished].contains(event.status) {
                        Text(scoreOverride ?? "\(event.scoreAway.map(String.init) ?? "—")  –  \(event.scoreHome.map(String.init) ?? "—")").font(RallyFont.font(size: min(28, geo.size.height * 0.2), weight: .bold)).monospacedDigit().foregroundStyle(.white)
                    } else { Text("VS").font(RallyFont.font(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.7)) }
                    RallyTeamLogo(team: event.homeTeam, size: min(74, geo.size.height * 0.5)).frame(maxWidth: .infinity)
                }
            }
        }
    }
}
