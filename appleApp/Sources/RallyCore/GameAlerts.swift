import Foundation
import UserNotifications

/// Game alerts for favorite teams. Mirrors `GameAlertManager.evaluate`:
/// kickoff, score change, overtime, close game, final, plus a RedZone
/// touchdown heuristic — all deduped and delivered as user notifications
/// that deep-link back via `rally://event/{id}`.
public struct GameAlert: Sendable, Equatable {
    public enum Kind: String, Sendable { case kickoff, score, overtime, closeGame, final, redZone }
    public var kind: Kind
    public var eventId: String
    public var title: String
    public var body: String
}

public enum GameAlerts {
    /// Favorite identity: `league:id` keys or raw team ids (both accepted).
    public static func involvesFavorite(_ event: SportEvent, favIds: Set<String>) -> Bool {
        for team in [event.homeTeam, event.awayTeam].compactMap({ $0 }) {
            if favIds.contains(team.id) || favIds.contains("\(event.league):\(team.id)") { return true }
        }
        return false
    }

    private static func closeGameMargin(sport: String) -> Int {
        switch sport.lowercased() {
        case "football": return 8
        case "basketball": return 8
        case "baseball": return 2
        case "hockey": return 2
        case "soccer": return 1
        default: return 5
        }
    }

    private static func margin(_ e: SportEvent) -> Int? {
        guard let h = e.scoreHome, let a = e.scoreAway else { return nil }
        return abs(h - a)
    }

    private static func scoreLine(_ e: SportEvent) -> String {
        "\(e.awayTeam?.abbreviation ?? "AWY") \(e.scoreAway.map(String.init) ?? "-") – " +
            "\(e.scoreHome.map(String.init) ?? "-") \(e.homeTeam?.abbreviation ?? "HME")"
    }

    /// Pure transition scan over a refresh (previous vs current snapshots).
    public static func evaluate(previous: [SportEvent], current: [SportEvent],
                                favIds: Set<String>, redZoneEnabled: Bool) -> [GameAlert] {
        let prevById = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        var out: [GameAlert] = []
        for e in current {
            guard involvesFavorite(e, favIds: favIds) else { continue }
            let prev = prevById[e.id]
            let title = e.name.isEmpty ? "Game update" : e.name
            // Kickoff.
            if (prev == nil || prev?.status == .notStarted) && (e.status == .live || e.status == .halftime) {
                out.append(GameAlert(kind: .kickoff, eventId: e.id, title: title, body: "Kickoff — \(scoreLine(e))"))
            }
            // Score change while live.
            if let p = prev, e.status == .live,
               (p.scoreHome, p.scoreAway) != (e.scoreHome, e.scoreAway),
               e.scoreHome != nil || e.scoreAway != nil {
                out.append(GameAlert(kind: .score, eventId: e.id, title: title, body: scoreLine(e)))
                // RedZone touchdown heuristic: NFL live jump of 6+ points.
                if redZoneEnabled, e.league.lowercased() == "nfl",
                   let ph = p.scoreHome, let pa = p.scoreAway,
                   let h = e.scoreHome, let a = e.scoreAway,
                   (h + a) - (ph + pa) >= 6 {
                    out.append(GameAlert(kind: .redZone, eventId: e.id, title: "RedZone · \(title)",
                                         body: "Touchdown — \(scoreLine(e))"))
                }
            }
            // Overtime callout.
            if e.status == .live, let detail = e.gameStatusDetail?.lowercased(),
               detail.contains("overtime") || detail.contains(" ot"),
               !(prev?.gameStatusDetail?.lowercased().contains("overtime") == true) {
                out.append(GameAlert(kind: .overtime, eventId: e.id, title: title, body: "Overtime — \(scoreLine(e))"))
            }
            // Close game: live and within one score for the sport.
            if e.status == .live, let m = margin(e), m <= closeGameMargin(sport: e.sport),
               prev.flatMap(margin) != m || prev?.status != .live {
                out.append(GameAlert(kind: .closeGame, eventId: e.id, title: title,
                                     body: "Close game — \(scoreLine(e))"))
            }
            // Final.
            if e.status == .finished, prev?.status != .finished {
                out.append(GameAlert(kind: .final, eventId: e.id, title: title,
                                     body: "Final — \(scoreLine(e))"))
            }
        }
        return out
    }
}

/// Delivery: dedupe + UNUserNotificationCenter posting with deep-link payload.
public final class GameAlertCenter: NSObject, Sendable, UNUserNotificationCenterDelegate {
    public static let openEventNotification = Notification.Name("RallyOpenEvent")
    private var delivered: Set<String> = []
    private let lock = NSLock()

    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        UNUserNotificationCenter.current().delegate = self
    }

    private func dedupeKey(_ alert: GameAlert, event: SportEvent) -> String {
        "\(alert.eventId)-\(alert.kind.rawValue)-\(event.scoreAway.map(String.init) ?? "-")-\(event.scoreHome.map(String.init) ?? "-")"
    }

    /// Posts alerts not already delivered (per launch session + score state).
    public func deliver(_ alerts: [GameAlert], events: [SportEvent]) {
        let byId = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            guard let event = byId[alert.eventId] else { continue }
            let key = dedupeKey(alert, event: event)
            guard lock.withLock({ delivered.insert(key).inserted }) else { continue }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.userInfo = ["eventId": alert.eventId]
            let req = UNNotificationRequest(identifier: key, content: content, trigger: nil)
            center.add(req)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["eventId"] as? String {
            NotificationCenter.default.post(name: Self.openEventNotification, object: id)
        }
        completionHandler()
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
