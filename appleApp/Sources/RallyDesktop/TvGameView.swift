import AppKit
import RallyCore
import SwiftUI

/// Game-view mode: mini tabs, 16:9 split with info tabs, live row, highlights.
/// Shares PlayerView's engine slot and video host — no stream restart on switch.
extension PlayerView {
    var gameViewLayout: some View {
        ZStack {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                playerButton("‹ Watch") { gameMode = false }
                gameTopTab("Game View", 0)
                gameTopTab("Live Highlights", 1)
                Spacer()
                if state.detailLoading { ProgressView().scaleEffect(0.7) }
                playerButton("Close") { store.show(nil) }
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            if topTab == 0 {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 16) {
                            videoCard
                                .frame(maxWidth: .infinity)
                            infoCard
                                .frame(width: 380)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                        .padding(.horizontal, 28)
                        liveRow
                            .padding(.bottom, 20)
                    }
                }
            } else {
                highlightsList
            }
        }
        if let clip = state.clipOverlay {
            Color.black.opacity(0.75).ignoresSafeArea()
                .onTapGesture { state.closeClipOverlay() }
            VStack(spacing: 12) {
                HStack {
                    Text(clip.title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    playerButton("Close clip") { state.closeClipOverlay() }
                }
                VideoHost(host: state.clipHost)
                    .frame(minWidth: 640, minHeight: 360)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Live game keeps playing underneath.")
                    .font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
            }
            .padding(28)
        }
        }
        .background(RallyTheme.background)
    }

    private func gameTopTab(_ label: String, _ tag: Int) -> some View {
        Button { topTab = tag } label: {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(topTab == tag ? Color.black : RallyTheme.textPrimary)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(topTab == tag ? RallyTheme.offWhite : Color.white.opacity(0.08))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(RallyTheme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                infoTabButton("Analytics", 0)
                infoTabButton("Players", 1)
                infoTabButton("Game Info", 2)
            }
            Divider().opacity(0.25)
            if infoTab == 0 { analyticsTab }
            else if infoTab == 1 { playersTab }
            else { gameInfoTab }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background(LinearGradient(colors: [Color(red: 23/255, green: 36/255, blue: 55/255, opacity: 0.72),
                                            Color(red: 7/255, green: 13/255, blue: 22/255, opacity: 0.56)],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }

    private func infoTabButton(_ label: String, _ tag: Int) -> some View {
        Button { infoTab = tag } label: {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(infoTab == tag ? RallyTheme.rallyCyan : RallyTheme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(infoTab == tag ? Color.white.opacity(0.1) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var analyticsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let event {
                matchupLine(team: event.awayTeam, score: event.scoreAway)
                matchupLine(team: event.homeTeam, score: event.scoreHome)
                Divider().opacity(0.25)
            }
            if let home = state.homeWinPct, let away = state.awayWinPct {
                Text("WIN PROBABILITY").font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(RallyTheme.textSecondary)
                winProbBar(home: home, away: away)
                Divider().opacity(0.25)
            }
            if let p = state.primary {
                diagRow("Stream", specsLine(p))
                let h = store.settings.streamHealth(target: p.url)
                diagRow("Source health", "\(healthLabel(h.score)) · \(h.score)")
            }
            diagRow("Status", event.map(statusText) ?? channel?.name ?? "Live")
        }
    }

    private func winProbBar(home: Double, away: Double) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(RallyTheme.rallyCyan)
                        .frame(width: geo.size.width * CGFloat(away / max(1, home + away)))
                    Rectangle().fill(Color.white.opacity(0.25))
                        .frame(width: geo.size.width * CGFloat(home / max(1, home + away)))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                Text("\(event?.awayTeam?.abbreviation ?? "AWY") \(Int(away))%")
                Spacer()
                Text("\(Int(home))% \(event?.homeTeam?.abbreviation ?? "HME")")
            }
            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
        }
    }

    private func matchupLine(team: Team?, score: Int?) -> some View {
        HStack {
            Text(team?.abbreviation ?? "TBD").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 52, alignment: .leading)
            Text(team?.records.compactMap { $0.summary }.joined(separator: " · ") ?? "–")
                .font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
            Spacer()
            if let score {
                Text(String(score)).font(.system(size: 18, weight: .black)).foregroundStyle(.white)
            }
        }
    }

    private var playersTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.detailLoading && state.tables.isEmpty && state.leaders.isEmpty {
                ProgressView("Loading leaders…")
            } else if !state.tables.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    teamColumn(team: event?.awayTeam)
                    teamColumn(team: event?.homeTeam)
                }
            } else if !state.leaders.isEmpty {
                ForEach(state.leaders.prefix(8), id: \.playerShortName) {
                    leaderRow($0)
                }
            } else {
                Text("Player stats appear closer to game time.")
                    .font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary)
            }
        }
    }

    private func teamColumn(team: Team?) -> some View {
        let table = state.tables.first(where: {
            $0.teamId == team?.id || (!$0.teamAbbreviation.isEmpty && $0.teamAbbreviation == team?.abbreviation)
        })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let logo = table?.teamLogoUrl ?? team?.logoUrl, let link = URL(string: logo) {
                    AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                        Text(team?.abbreviation ?? "").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                }
                Text(table?.teamName ?? team?.name ?? "").font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            }
            if let table {
                let headers = Array(table.labels.prefix(3))
                HStack {
                    Text("#").frame(width: 24, alignment: .leading)
                    Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(headers, id: \.self) { h in
                        Text(h).frame(width: 34, alignment: .trailing)
                    }
                }
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(RallyTheme.textTertiary)
                ForEach(table.rows.prefix(5), id: \.displayName) { row in
                    HStack {
                        Text(row.jersey ?? "").frame(width: 24, alignment: .leading)
                        Text(row.shortName ?? row.displayName).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(0..<headers.count, id: \.self) { k in
                            Text(row.stats.count > k ? row.stats[k] : "–").frame(width: 34, alignment: .trailing)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(RallyTheme.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func leaderRow(_ leader: PlayerLeader) -> some View {
        HStack(spacing: 10) {
            if let url = leader.headshotUrl ?? leader.teamLogoUrl, let link = URL(string: url) {
                AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                    Circle().fill(Color.white.opacity(0.1)).frame(width: 30, height: 30)
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            } else {
                Circle().fill(Color.white.opacity(0.1)).frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(leader.playerShortName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(leader.category).font(.system(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(leader.statDisplay).font(.system(size: 13, weight: .bold)).foregroundStyle(RallyTheme.rallyCyan)
        }
    }

    private var gameInfoTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let event {
                diagRow("Matchup", "\(event.awayTeam?.name ?? "Away") at \(event.homeTeam?.name ?? "Home")")
                diagRow("League", Artwork.displayLeague(event.league))
                diagRow("Venue", event.venue ?? "TBD")
                diagRow("Start", event.startTime.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                diagRow("Status", statusText(event))
            } else if let channel {
                diagRow("Channel", channel.name)
                diagRow("Category", channel.category)
                if let now = channel.guide?.now?.title { diagRow("Now", now) }
                if let next = channel.guide?.next?.title { diagRow("Next", next) }
            }
        }
    }

    private func statusText(_ event: SportEvent) -> String {
        switch event.status {
        case .live: "LIVE"; case .halftime: "HALFTIME"; case .finished: "FINAL"
        case .notStarted: "UPCOMING"; case .delayed: "DELAYED"; case .canceled: "CANCELED"
        }
    }

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OTHER LIVE GAMES").font(.system(size: 13, weight: .bold)).tracking(2)
                .foregroundStyle(RallyTheme.textPrimary)
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(otherLive) { other in
                        TvLiveCard(event: other, focus: $liveFocus, size: CGSize(width: 240, height: 136), onSelect: { switchEvent(other) })
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 4)
            }
        }
        .padding(.top, 12)
    }

    private var otherLive: [SportEvent] {
        store.liveEvents.filter { $0.id != event?.id }.prefix(10).map { $0 }
    }

    private var highlightsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if state.detailLoading && state.clips.isEmpty {
                    ProgressView("Loading highlights…").padding()
                } else if state.clips.isEmpty {
                    VStack(spacing: 8) {
                        Text("No highlights yet").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        Text("Clips from this game appear here as the broadcaster publishes them.")
                            .font(.callout).foregroundStyle(RallyTheme.textSecondary)
                    }
                    .padding(40)
                }
                ForEach(state.clips) { clip in
                    Button {
                        state.openClipOverlay(clip)
                    } label: {
                        HStack(spacing: 12) {
                            if let thumb = clip.thumbnailUrl, let link = URL(string: thumb) {
                                AsyncImage(url: link) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)).frame(width: 160, height: 90)
                                }
                                .frame(width: 160, height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)).frame(width: 160, height: 90)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(clip.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                                if let desc = clip.description {
                                    Text(desc).font(.system(size: 12)).foregroundStyle(RallyTheme.textSecondary).lineLimit(2)
                                }
                                if let dur = clip.durationSeconds {
                                    Text("\(dur / 60):\(String(format: "%02d", dur % 60))")
                                        .font(.system(size: 11)).foregroundStyle(RallyTheme.textTertiary)
                                }
                            }
                            Spacer()
                            if clip.streamUrl != nil {
                                Image(systemName: "play.circle.fill").font(.system(size: 26))
                                    .foregroundStyle(RallyTheme.rallyCyan)
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyTheme.glassBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(clip.streamUrl == nil)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
    }

    private var videoCard: some View {
        ZStack {
            VideoHost(host: host)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
            if controlsVisible {
                VStack(spacing: 0) {
                    hudTop
                    Spacer()
                    hudBottom
                }
            }
            if state.paused {
                Button { state.togglePause() } label: {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.55)).frame(width: 76, height: 76)
                        Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyTheme.glassBorder, lineWidth: 1))
    }

    private func switchEvent(_ new: SportEvent) {
        Task { await state.load(event: new, channel: nil, store: store, drawable: host) }
    }
}
