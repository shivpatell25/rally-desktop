import XCTest
@testable import RallyCore

/// Disk-cache primitives: schedule reseed, channel identity gating, TTL expiry.
final class ResilienceTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RallyResilience-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleEvent() -> SportEvent {
        SportEvent(id: "e1", name: "Game", startTime: Date(), status: .notStarted,
                   sport: "football", league: "NFL")
    }

    private func sampleChannel() -> IptvChannel {
        IptvChannel(id: "c1", number: "1", name: "ESPN 1080p", streamUrl: "https://x/1.m3u8")
    }

    // MARK: DiskCache envelope

    func testDiskRoundTripAndExpiry() {
        let cache = DiskCache(directory: tempDir())
        cache.save(["a", "b"], name: "t.json")
        XCTAssertEqual(cache.load("t.json", maxAge: 60) as [String]?, ["a", "b"])
        XCTAssertNil(cache.load("t.json", maxAge: 0) as [String]?)
        XCTAssertNil(cache.load("missing.json", maxAge: 60) as [String]?)
    }

    func testDiskCorruptFileReadsNil() {
        let dir = tempDir()
        try! "not json".write(to: dir.appendingPathComponent("t.json"), atomically: true, encoding: .utf8)
        let cache = DiskCache(directory: dir)
        XCTAssertNil(cache.load("t.json", maxAge: 60) as [String]?)
    }

    // MARK: ScheduleStore

    func testScheduleSaveLoadFreshAndAny() {
        let store = ScheduleStore(directory: tempDir())
        XCTAssertNil(store.loadFresh())
        XCTAssertNil(store.loadAny())
        store.save([sampleEvent()])
        XCTAssertEqual(store.loadFresh()?.count, 1)
        XCTAssertEqual(store.loadAny()?.count, 1)
        store.save([]) // empty saves are dropped — last-known-good survives
        XCTAssertEqual(store.loadFresh()?.count, 1)
    }

    // MARK: ChannelDiskStore

    func testChannelIdentityGating() {
        let store = ChannelDiskStore(directory: tempDir())
        store.save([sampleChannel()], identity: "portal|mac")
        XCTAssertEqual(store.loadFresh(identity: "portal|mac")?.count, 1)
        XCTAssertNil(store.loadFresh(identity: "other|mac"))
        XCTAssertNil(store.loadAny(identity: "other|mac"))
    }

    func testChannelFileNameSanitized() {
        let name = ChannelDiskStore.fileName(identity: "https://host.tv:8080/c|00:1A:79:AA:BB:CC")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasPrefix("channels-"))
        XCTAssertTrue(name.hasSuffix(".json"))
    }
}
