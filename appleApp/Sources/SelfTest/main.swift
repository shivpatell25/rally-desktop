import RallyCore
import Foundation

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
