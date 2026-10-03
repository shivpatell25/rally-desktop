import Foundation

/// Measures wall time rather than trusting a player's nominal playing state.
public struct PlaybackProgress {
    private var position: Double?
    private var advancedAt = Date()
    private var healthySince: Date?
    public private(set) var reconnects = 0
    public init() {}
    public mutating func reset(now: Date = Date(), keepBudget: Bool = false) {
        position = nil; advancedAt = now; healthySince = nil
        if !keepBudget { reconnects = 0 }
    }
    public mutating func stalled(position current: Double?, paused: Bool, now: Date = Date(), timeout: TimeInterval = 15) -> Bool {
        if paused { position = current; advancedAt = now; healthySince = nil; return false }
        if let current, current.isFinite, position == nil || abs(current - (position ?? 0)) > 0.1 {
            position = current; advancedAt = now
            if healthySince == nil { healthySince = now }
            if let since = healthySince, now.timeIntervalSince(since) >= 60 { reconnects = 0 }
            return false
        }
        guard now.timeIntervalSince(advancedAt) >= timeout else { return false }
        healthySince = nil; advancedAt = now
        return true
    }
    public mutating func consumeReconnect() -> Bool {
        guard reconnects < 2 else { return false }
        reconnects += 1; return true
    }
}
