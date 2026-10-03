import AVFoundation
import RallyCore
import SwiftUI

/// Idle ambient scores (Android ScoreSaver): clock + top cards after 5 idle
/// minutes, suppressed while sheets, player, or onboarding own the screen.
struct ScoreSaverOverlay: View {
    @EnvironmentObject var store: RallyStore
    @State private var now = Date()

    private var cards: [SportEvent] {
        let live = store.events.filter { $0.status == .live || $0.status == .halftime }
        let rest = store.events.filter { $0.status != .live && $0.status != .halftime }
        return Array((live + rest).prefix(4))
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 680
            let columns = geo.size.width >= 1180 ? 4 : geo.size.width >= 620 ? 2 : 1
            let inset: CGFloat = geo.size.width < 620 ? 24 : 48
            ZStack {
                AmbientBackground()
                Color.black.opacity(0.38).ignoresSafeArea()
                VStack(spacing: compact ? 16 : 26) {
                    if let wordmark = tvArt("rally_wordmark") {
                        Image(nsImage: wordmark).resizable().scaledToFit().frame(width: 116, height: 42)
                    }
                    VStack(spacing: 8) {
                        Text(now.formatted(date: .omitted, time: .shortened))
                            .font(RallyFont.font(size: compact ? 54 : 76, weight: .light))
                            .foregroundStyle(.white).monospacedDigit()
                        Text(now.formatted(.dateTime.weekday(.wide).month().day()))
                            .font(RallyFont.font(size: 15)).foregroundStyle(RallyTheme.textSecondary)
                    }
                    if !cards.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), spacing: 16) {
                            ForEach(cards) { event in
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(event.league).tracking(1.2)
                                        Spacer()
                                        Text([EventStatus.live, .halftime].contains(event.status) ? "LIVE" : event.status == .finished ? "FINAL" : "UPCOMING")
                                            .foregroundStyle([EventStatus.live, .halftime].contains(event.status) ? RallyTheme.liveRed : RallyTheme.textSecondary)
                                    }.font(RallyFont.font(size: 10, weight: .semibold))
                                    HStack(spacing: 12) {
                                        RallyTeamLogo(team: event.awayTeam, size: 32)
                                        Text([EventStatus.live, .halftime].contains(event.status) || event.status == .finished
                                             ? "\(event.scoreAway.map(String.init) ?? "—") — \(event.scoreHome.map(String.init) ?? "—")"
                                             : event.startTime.formatted(date: .omitted, time: .shortened))
                                            .font(RallyFont.font(size: 20, weight: .semibold)).monospacedDigit()
                                            .frame(maxWidth: .infinity)
                                        RallyTeamLogo(team: event.homeTeam, size: 32)
                                    }
                                    Text(event.rallyMatchup).font(RallyFont.font(size: 13, weight: .medium))
                                        .lineLimit(2).frame(height: 34, alignment: .top)
                                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    Text("Move the pointer or press a key to return")
                        .font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textTertiary)
                }.padding(.horizontal, inset).frame(maxWidth: min(1320, geo.size.width))
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }.accessibilityLabel("Rally ambient scores")
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}

/// One-shot spoken score summary (Android spokenScoreSummaries).
enum ScoreAnnouncer {
    private static let speech = AVSpeechSynthesizer()

    static func announce(_ events: [SportEvent]) {
        let lines = events.prefix(3).map { event -> String in
            switch event.status {
            case .live, .halftime:
                return "\(event.name), \(event.awayTeam?.abbreviation ?? "") \(event.scoreAway.map(String.init) ?? "") to \(event.scoreHome.map(String.init) ?? "") \(event.homeTeam?.abbreviation ?? "")"
            case .finished:
                return "\(event.name), final"
            default:
                return "\(event.name), upcoming"
            }
        }
        guard !lines.isEmpty else { return }
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: lines.joined(separator: ". ")))
    }
}
