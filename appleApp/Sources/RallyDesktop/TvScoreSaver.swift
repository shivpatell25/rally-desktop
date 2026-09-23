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
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 64, weight: .thin)).foregroundStyle(.white)
                Text(now.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.system(size: 15)).foregroundStyle(RallyTheme.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(cards) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.league).font(.system(size: 10, weight: .bold)).tracking(1)
                                .foregroundStyle(RallyTheme.rallyCyan)
                            Text(event.name).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                            if event.status == .live || event.status == .finished {
                                Text("\(event.awayTeam?.abbreviation ?? "") \(event.scoreAway.map(String.init) ?? "") – \(event.scoreHome.map(String.init) ?? "") \(event.homeTeam?.abbreviation ?? "")")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            } else {
                                Text(event.startTime.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 13)).foregroundStyle(RallyTheme.textSecondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 60)
                Text("Move to wake · scores keep updating underneath")
                    .font(.system(size: 12)).foregroundStyle(RallyTheme.textTertiary)
            }
        }
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
