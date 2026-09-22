import Foundation

/// Atomic JSON disk cache with TTL. boring foundation for the schedule +
/// channel stores below (mirrors SportsEventDiskCache / Room serve-instantly).
public struct DiskCache: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("com.shiv.rally.macos", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private struct Envelope<T: Codable>: Codable {
        var savedAt: Date
        var payload: T
    }

    public func load<T: Codable>(_ name: String, maxAge: TimeInterval) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let env = try? JSONDecoder().decode(Envelope<T>.self, from: data),
              Date().timeIntervalSince(env.savedAt) < maxAge else { return nil }
        return env.payload
    }

    public func loadAny<T: Codable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let env = try? JSONDecoder().decode(Envelope<T>.self, from: data) else { return nil }
        return env.payload
    }

    public func save<T: Codable>(_ value: T, name: String) {
        let env = Envelope(savedAt: Date(), payload: value)
        guard let data = try? JSONEncoder().encode(env) else { return }
        // Atomic write: no torn reads after a crash or relaunch mid-save.
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

/// Last-known-good ESPN schedule. 72h TTL; stale data still beats an empty
/// shelf on airplane-mode/DNS-outage launches (Android SportsEventDiskCache).
public struct ScheduleStore: Sendable {
    public static let ttl: TimeInterval = 72 * 3600
    private static let name = "schedule.json"
    private let cache: DiskCache

    public init(directory: URL? = nil) {
        cache = DiskCache(directory: directory)
    }

    public func loadFresh() -> [SportEvent]? {
        let events: [SportEvent]? = cache.load(Self.name, maxAge: Self.ttl)
        return (events?.isEmpty == false) ? events : nil
    }

    public func loadAny() -> [SportEvent]? {
        let events: [SportEvent]? = cache.loadAny(Self.name)
        return (events?.isEmpty == false) ? events : nil
    }

    public func save(_ events: [SportEvent]) {
        guard !events.isEmpty else { return }
        cache.save(events, name: Self.name)
    }
}

/// Persisted IPTV channel catalog, identity-gated like the in-memory cache
/// (portal|mac or xtream identity). 15-min fresh TTL; stale fallback keeps
/// Live TV usable when the portal is briefly unreachable.
public struct ChannelDiskStore: Sendable {
    public static let ttl: TimeInterval = 15 * 60
    private let cache: DiskCache

    public init(directory: URL? = nil) {
        cache = DiskCache(directory: directory)
    }

    public static func fileName(identity: String) -> String {
        let safe = identity.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return "channels-\(safe.prefix(64)).json"
    }

    public func loadFresh(identity: String) -> [IptvChannel]? {
        let channels: [IptvChannel]? = cache.load(Self.fileName(identity: identity), maxAge: Self.ttl)
        return (channels?.isEmpty == false) ? channels : nil
    }

    public func loadAny(identity: String) -> [IptvChannel]? {
        let channels: [IptvChannel]? = cache.loadAny(Self.fileName(identity: identity))
        return (channels?.isEmpty == false) ? channels : nil
    }

    public func save(_ channels: [IptvChannel], identity: String) {
        guard !channels.isEmpty else { return }
        cache.save(channels, name: Self.fileName(identity: identity))
    }
}
