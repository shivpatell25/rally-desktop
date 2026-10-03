import RallyCore
import Foundation
import AppKit

func check(_ cond: Bool, _ label: String) {
    if !cond { print("FAIL: \(label)"); exit(1) }
    print("ok: \(label)")
}

check(parseQualityFromChannelName("ESPN 4K HDR").resolution == "4K", "4k token")
check(parseQualityFromChannelName("ESPN 4K HDR").isHdr, "hdr token")
check(parseQualityFromChannelName("Sky Sports 1080p 60fps").is60Fps, "60fps token")
let plain = parseQualityFromChannelName("Random Channel 12")
check(plain.resolution == nil && !plain.isHdr && !plain.is4K, "no-guess quality")
check(StreamSelector.qualityRank(StreamQualityInfo(resolution: "4K", is4K: true))
    > StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p")), "rank 4k>1080p")
check(StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p", isHdr: true))
    > StreamSelector.qualityRank(StreamQualityInfo(resolution: "1080p")), "rank hdr tiebreak")

let home = Team(id: "1", name: "Dallas Cowboys", abbreviation: "DAL")
let away = Team(id: "2", name: "Philadelphia Eagles", abbreviation: "PHI")
let event = SportEvent(id: "e1", name: "DAL @ PHI", homeTeam: home, awayTeam: away,
    startTime: Date(), status: .notStarted, sport: "football", league: "NFL")
check(StreamSelector.textMatchesEvent("Dallas Cowboys vs Philadelphia Eagles 1080p", event: event), "full-name match")
check(StreamSelector.textMatchesEvent("DAL vs PHI", event: event), "abbr match")
check(!StreamSelector.textMatchesEvent("Lakers vs Celtics", event: event), "non-match")
check(UpdateChecker().compareVersions("v1.2.0", "1.1.0") > 0, "version compare")
print("SELFTEST PASS")

@MainActor
func networkSmoke() async {
    let client = EspnClient()
    let feed = await client.fetchAllLeagues()
    check(!feed.isEmpty, "real ESPN sports feed")
    print("SPORTS: \(feed.count) events / \(Set(feed.map(\.league)).count) leagues")
    let schedule = await client.fetchScheduleWindow()
    check(!schedule.isEmpty, "real multi-day schedule")
    if let game = feed.first(where: { $0.status == .live || $0.status == .finished }), let path = EspnClient.path(forLeague: game.league) {
        let detail = await client.fetchSummary(sport: path.sport, league: path.path, eventId: game.id)
        check(detail.isAvailable, "real event summary")
        print("DETAIL: \(detail.teamStats.count) stats / \(detail.plays.count) plays / \(detail.clips.count) clips")
    }
    let controller = PlaybackController()
    controller.player.isMuted = true
    let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
    controller.play(url: url)
    check(await controller.waitUntilReady(timeout: 20), "AVFoundation real HLS ready")
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    check(controller.player.currentTime().seconds > 0, "real video clock advances")
    controller.refreshTracks()
    print("PLAYER: audio=\(controller.audioTracks.count) captions=\(controller.captionTracks.count) qualities=\(controller.qualities.count) seek=\(controller.seekRange != nil)")
    check(!controller.audioTracks.isEmpty, "published audio tracks")
    check(!controller.captionTracks.isEmpty, "published caption tracks")
    check(!controller.qualities.isEmpty, "published HLS quality variants")
    if let track = controller.captionTracks.first {
        controller.selectTrack(track.id, captions: true)
        check(controller.captionTracks.contains(where: { $0.id == track.id && $0.selected }), "caption selection")
        controller.selectTrack(-1, captions: true)
    }
    if let track = controller.audioTracks.last {
        controller.selectTrack(track.id, captions: false)
        check(controller.audioTracks.contains(where: { $0.id == track.id && $0.selected }), "audio selection")
    }
    controller.setQuality(controller.qualities.last)
    controller.seekRelative(10)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    check(controller.player.currentTime().seconds > 8, "seek forward")
    controller.watchFromStart()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    check(controller.player.currentTime().seconds < 5, "watch from start")
    controller.stop()
    let dash = URL(string: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd")!
    let dashQualities = await PlaybackController.loadQualities(url: dash, headers: [:])
    check(!dashQualities.isEmpty, "published DASH quality variants")
    _ = NSApplication.shared
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    host.wantsLayer = true
    let vlc = VlcEngine(); let slot = "dash-smoke"
    check(vlc.reserve(slotId: slot), "compatibility engine reservation")
    do {
        let proxied = try await vlc.prepareURL(slotId: slot, url: dash, headers: ["Origin": "https://reference.dashif.org", "User-Agent": "Rally/macOS"])
        try vlc.play(slotId: slot, title: "DASH test", url: proxied, drawable: host, maxHeight: dashQualities.last?.height ?? 0, renderVideo: false)
        vlc.setMuted(slotId: slot, muted: true)
        let deadline = Date().addingTimeInterval(20)
        while !vlc.isPlaying(slotId: slot) && !vlc.hasError(slotId: slot) && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        check(vlc.isPlaying(slotId: slot), "real DASH playback through authenticated relay")
        let clockDeadline = Date().addingTimeInterval(20)
        while vlc.position(slotId: slot)?.clock == "0:00:00" && !vlc.hasError(slotId: slot) && Date() < clockDeadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        print("DASH position: \(String(describing: vlc.position(slotId: slot)))")
        check(vlc.position(slotId: slot)?.clock != "0:00:00", "DASH video clock advances")
        check(vlc.seekable(slotId: slot), "DASH VOD seeking")
        vlc.seekRelative(slotId: slot, seconds: 10)
        check(!vlc.tracks(slotId: slot, captions: false).isEmpty, "DASH published audio tracks")
    } catch { check(false, "DASH playback: \(error.localizedDescription)") }
    vlc.releaseAll()
    print("NETWORK / PLAYBACK SMOKE PASS")
}
if CommandLine.arguments.contains("--network") { await networkSmoke() }
