import RallyCore
import SwiftUI

struct RallyPlayersPanel: View {
    let tables: [PlayerStatTable]
    @State private var query = ""
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Find a player", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Find a player")
            ForEach(GamePlayers.teams(from: tables)) { team in
                HStack(spacing: 8) {
                    playerPhoto(team.logoURL, size: 28)
                    Text(team.name).font(RallyFont.font(size: compact ? 13 : 16, weight: .semibold))
                    Spacer()
                    Text("\(team.players.count) players").font(RallyFont.font(size: 10)).foregroundStyle(RallyTheme.textSecondary)
                }
                ForEach(team.players.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { player in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 9) {
                            playerPhoto(player.imageURL, size: compact ? 30 : 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(player.name).font(RallyFont.font(size: compact ? 12 : 14, weight: .medium))
                                Text([player.position, player.jersey.map { "#\($0)" }].compactMap { $0 }.joined(separator: " · ")).font(RallyFont.font(size: 10)).foregroundStyle(RallyTheme.textSecondary)
                            }
                        }
                        ForEach(Array(player.categories.enumerated()), id: \.offset) { _, category in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.name.capitalized).font(RallyFont.font(size: 10, weight: .semibold)).foregroundStyle(RallyTheme.textSecondary)
                                // Wrapping keeps every statistic available without clipping a wide table.
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 70 : 92), alignment: .leading)], alignment: .leading, spacing: 6) {
                                    ForEach(Array(category.values.enumerated()), id: \.offset) { _, stat in
                                        HStack(spacing: 5) { Text(stat.label).foregroundStyle(RallyTheme.textSecondary); Text(stat.value).monospacedDigit().fontWeight(.medium) }.font(RallyFont.font(size: compact ? 10 : 12))
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 8)
                    Divider().opacity(0.25)
                }
            }
            if tables.isEmpty { Text("Player statistics have not been published yet.").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary) }
        }.foregroundStyle(.white)
    }
    private func playerPhoto(_ value: String?, size: CGFloat) -> some View {
        Group {
            if let value, let url = URL(string: value) { AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(RallyTheme.textSecondary) } }
            else { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(RallyTheme.textSecondary) }
        }.frame(width: size, height: size)
    }
}
