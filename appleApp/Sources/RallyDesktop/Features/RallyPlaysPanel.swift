import RallyCore
import SwiftUI

struct RallyPlaysPanel: View {
    let plays: [GamePlay]
    var selectedPlayID: String?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(plays) { play in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(play.period.map { "P\($0)" } ?? "Play").font(.caption.bold())
                        Text(play.clock ?? "").font(.caption.monospacedDigit())
                    }.foregroundStyle(RallyTheme.textSecondary).frame(width: 46, alignment: .leading)
                    Text(play.text).font(RallyFont.font(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    if play.isScoringPlay { Image(systemName: "star.fill").foregroundStyle(RallyTheme.textPrimary) }
                    if let away = play.awayScore, let home = play.homeScore {
                        Text("\(away)–\(home)").font(.caption.bold()).monospacedDigit()
                    }
                }.padding(12).background(play.id == selectedPlayID ? RallyTheme.surfaceFocused : RallyTheme.surfaceBase, in: RoundedRectangle(cornerRadius: 8)).id(play.id)
            }
        }
    }
}
