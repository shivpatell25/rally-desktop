import XCTest
@testable import RallyCore

/// Device profiles, tuning options, adaptive fallback (Android PlaybackCapabilities).
final class PlaybackPolicyTests: XCTestCase {
    func testProfileTiers() {
        let low = PlaybackProfile.resolve(memoryBytes: 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(low.tier, .constrained)
        XCTAssertEqual(low.maxTiles, 2)
        let std = PlaybackProfile.resolve(memoryBytes: 32 * 1024 * 1024 * 1024)
        XCTAssertEqual(std.tier, .standard)
        XCTAssertEqual(std.maxTiles, 4)
        XCTAssertGreaterThan(std.networkCachingMs, 0)
        XCTAssertLessThan(
            PlaybackProfile.resolve(memoryBytes: 32 * 1024 * 1024 * 1024, lowLatency: true).networkCachingMs,
            std.networkCachingMs)
    }

    func testTuningOptions() {
        let plain = PlaybackTuning()
        XCTAssertEqual(plain.mediaOptions["network-caching"], "4000")
        XCTAssertNil(plain.mediaOptions["audio-filter"])
        let tuned = PlaybackTuning(lowLatency: true, audioNormalization: true, networkCachingMs: 1500)
        XCTAssertEqual(tuned.mediaOptions["network-caching"], "1500")
        XCTAssertEqual(tuned.mediaOptions["audio-filter"], "compressor")
        XCTAssertEqual(tuned.mediaOptions["compressor-ratio"], "4.0")
    }

    func testAdaptiveFallback() {
        func cand(_ id: String) -> PlayCandidate {
            PlayCandidate(id: id, title: id, url: "https://cdn/\(id).m3u8", kind: .stremio,
                          exactMatch: true, rank: 500)
        }
        let cands = [cand("a"), cand("b"), cand("c")]
        // Below threshold: no step-down.
        XCTAssertNil(AdaptivePolicy.fallback(afterStalls: 2, candidates: cands, currentId: "a", failedIds: []))
        // At threshold: next rank with a reason.
        let next = AdaptivePolicy.fallback(afterStalls: 3, candidates: cands, currentId: "a", failedIds: [])
        XCTAssertEqual(next?.candidate.id, "b")
        XCTAssertTrue(next?.reason.contains("3 stalls") == true)
        // Skips blacklisted.
        let skip = AdaptivePolicy.fallback(afterStalls: 3, candidates: cands, currentId: "a", failedIds: ["b"])
        XCTAssertEqual(skip?.candidate.id, "c")
        // Last candidate: nothing below.
        XCTAssertNil(AdaptivePolicy.fallback(afterStalls: 9, candidates: cands, currentId: "c", failedIds: []))
        // Single candidate: no step-down possible.
        XCTAssertNil(AdaptivePolicy.fallback(afterStalls: 9, candidates: [cand("a")], currentId: "a", failedIds: []))
    }
}
