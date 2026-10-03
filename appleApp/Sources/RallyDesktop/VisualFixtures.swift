import AppKit
import Foundation
import RallyCore
import SwiftUI

/// Opt-in launch data for deterministic visual verification. Never selected
/// unless the process is launched with `--visual-fixture`.
enum VisualFixtures {
    static let events: [SportEvent] = {
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let rows: [(String, String, String, String, String, EventStatus, Int?, Int?)] = [
            ("NFL", "football", "Kansas City Chiefs", "Baltimore Ravens", "4th · 3:42", .live, 24, 20),
            ("NCAAF", "football", "Michigan", "Ohio State", "SAT · 12:00 PM", .notStarted, nil, nil),
            ("NBA", "basketball", "Boston Celtics", "Los Angeles Lakers", "FINAL", .finished, 112, 106),
            ("NCAAB", "basketball", "Duke", "North Carolina", "HALFTIME", .halftime, 38, 41),
            ("MLB", "baseball", "New York Yankees", "Los Angeles Dodgers", "TUE · 7:10 PM", .notStarted, nil, nil),
            ("NHL", "hockey", "New York Rangers", "Boston Bruins", "1ST · 12:14", .live, 1, 0),
            ("EPL", "soccer", "Arsenal", "Liverpool", "SUN · 4:30 PM", .notStarted, nil, nil),
            ("La Liga", "soccer", "Real Madrid", "Barcelona", "SUN · 8:00 PM", .notStarted, nil, nil),
            ("Champions League", "soccer", "Bayern Munich", "Paris Saint-Germain", "WED · 8:00 PM", .notStarted, nil, nil),
            ("Serie A", "soccer", "Inter Milan", "AC Milan", "SAT · 7:45 PM", .notStarted, nil, nil)
        ]
        return rows.enumerated().map { index, row in
            let (league, sport, home, away, detail, status, homeScore, awayScore) = row
            return SportEvent(
                id: "visual-\(index)",
                name: "\(away) at \(home)",
                homeTeam: Team(id: "visual-home-\(index)", name: home,
                               abbreviation: abbreviation(home), logoUrl: logo(home, league: league), colors: [color(home)]),
                awayTeam: Team(id: "visual-away-\(index)", name: away,
                               abbreviation: abbreviation(away), logoUrl: logo(away, league: league), colors: [color(away)]),
                startTime: base.addingTimeInterval(Double(index) * 7_200),
                status: status,
                scoreHome: homeScore,
                scoreAway: awayScore,
                sport: sport,
                league: league,
                venue: "Rally Arena",
                gameStatusDetail: detail,
                broadcasts: ["Rally Sports"]
            )
        }
    }()

    private static func color(_ name: String) -> String {
        ["Kansas City Chiefs":"#E31837", "Baltimore Ravens":"#241773", "Boston Celtics":"#007A33", "Los Angeles Lakers":"#552583", "Duke":"#003087", "North Carolina":"#7BAFD4", "New York Rangers":"#0038A8", "Boston Bruins":"#FFB81C"][name] ?? "#303943"
    }
    private static func logo(_ name: String, league: String) -> String? {
        let ids = ["Kansas City Chiefs":"12", "Baltimore Ravens":"33", "Boston Celtics":"2", "Los Angeles Lakers":"13", "New York Yankees":"10", "Los Angeles Dodgers":"19", "New York Rangers":"13", "Boston Bruins":"1", "Michigan":"130", "Ohio State":"194", "Duke":"150", "North Carolina":"153"]
        guard let id = ids[name] else { return nil }
        let path = league == "NCAAF" || league == "NCAAB" ? "ncaa" : league.lowercased()
        return "https://a.espncdn.com/i/teamlogos/\(path)/500/\(id).png"
    }

    private static func abbreviation(_ name: String) -> String {
        let words = name.split(separator: " ")
        if words.count > 1 { return words.prefix(3).compactMap(\.first).map(String.init).joined() }
        return String(name.prefix(3)).uppercased()
    }
}

/// Resolves the hosting NSWindow after SwiftUI attaches the view, avoiding
/// scene-restoration dimensions during deterministic visual captures.
struct VisualWindowConfigurator: NSViewRepresentable {
    var size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = view.window else { return }
            window.setContentSize(size)
            window.center()
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
