import AppKit
import RallyCore
import SwiftUI

extension PlayerView {
    var gameViewLayout: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let contentWidth = width - 56
            let sidebarWidth = max(290, contentWidth * 0.31)
            let videoWidth = contentWidth - sidebarWidth - 20
            ZStack {
                AmbientBackground()
                VStack(spacing: 12) {
                    HStack {
                        Button { store.show(nil) } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain).help("Back (Escape)")
                        Spacer()
                        sourceMenu.fixedSize()
                        qualityMenu.fixedSize()
                        if let image = tvArt("rally_mark_ui") { Image(nsImage: image).resizable().scaledToFit().frame(width: 30, height: 30).padding(.leading, 14) }
                    }.font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary).menuStyle(.borderlessButton).padding(.vertical, 4)
                    if width >= 1050 && proxy.size.height >= videoWidth * 9 / 16 + 330 {
                        HStack(alignment: .top, spacing: 20) {
                            gameVideoColumn(width: videoWidth)
                            infoCard(height: videoWidth * 9 / 16 + 274).frame(width: sidebarWidth)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 20) { gameVideoColumn(width: min(contentWidth, 1050)); infoCard(height: 620).frame(maxWidth: 1050) }
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20)
                if let clip = state.clipOverlay {
                    Color.black.opacity(0.8).onTapGesture { state.closeClipOverlay() }
                    VStack(spacing: 14) {
                        HStack { Text(clip.title).font(RallyFont.font(size: 16, weight: .semibold)); Spacer(); Button("Close Clip") { state.closeClipOverlay() }.buttonStyle(RallyActionStyle()) }
                        NativePlayerView(controller: state.clipController).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        Text("The live broadcast continues in the background.").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary)
                    }.padding(30).frame(maxWidth: 980).foregroundStyle(.white)
                }
            }.environment(\.tvMetrics, TvMetrics(width: width, height: proxy.size.height, largeText: store.settings.largeText))
        }
    }
    private func gameVideoColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            scoreStrip.frame(height: 52)
            videoCard.frame(width: width, height: width * 9 / 16)
            gameActions.frame(height: 40)
            RallyTabs(items: [("Key Moments", 0), ("Other Live Games", 1)], selection: $momentsTab, compact: true).frame(height: 36)
            Group { if momentsTab == 0 { highlightsList(width: width) } else { liveRow(width: width) } }.frame(height: 98, alignment: .top)
        }.frame(width: width)
    }
    private var gameActions: some View {
        HStack(spacing: 7) {
            gameAction(state.paused ? "Play" : "Pause", symbol: state.paused ? "play.fill" : "pause.fill", primary: true) { state.togglePause() }
            gameAction("Fullscreen", symbol: "arrow.up.left.and.arrow.down.right") { gameMode = false; if NSApp.keyWindow?.styleMask.contains(.fullScreen) != true { toggleFullscreen() } }
            gameAction("Restart", symbol: "arrow.counterclockwise") { state.fromStart() }.disabled(!state.canSeek)
            gameAction("Multiview", symbol: "rectangle.split.2x2") { openMultiView() }
            audioMenu.frame(maxWidth: .infinity).padding(.vertical, 11).background(RallyTheme.surfaceBase.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            captionsMenu.frame(maxWidth: .infinity).padding(.vertical, 11).background(RallyTheme.surfaceBase.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            gameAction("Source", symbol: "dot.radiowaves.left.and.right") { pickerVisible = true }
        }.font(RallyFont.font(size: 10)).foregroundStyle(.white).menuStyle(.borderlessButton)
    }
    private func gameAction(_ title: String, symbol: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(RallyFont.font(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity).padding(.vertical, 11).foregroundStyle(primary ? .black : .white)
                .background(primary ? RallyTheme.offWhite : RallyTheme.surfaceBase.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
    private func infoCard(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RallyTabs(items: [("Stats", 0), ("Plays", 3), ("Players", 1), ("Sources", 4)], selection: $infoTab, compact: true)
            if infoTab == 0 { analyticsTab }
            else {
                ScrollViewReader { reader in
                    ScrollView {
                        if infoTab == 1 { RallyPlayersPanel(tables: state.tables, compact: true) }
                        else if infoTab == 3 { RallyPlaysPanel(plays: state.plays, selectedPlayID: requestedPlayID) }
                        else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(state.candidates) { candidate in
                                    Button { Task { await state.switchTo(candidate, store: store, drawable: host.surface) } } label: {
                                        HStack { Text(candidate.title).lineLimit(2); Spacer(); if state.primary?.id == candidate.id { Image(systemName: "checkmark") } }.padding(10).rallySurface(radius: 7)
                                    }.buttonStyle(.plain)
                                }
                                if state.candidates.isEmpty { Text("No sources available. Add a provider or addon in Settings.").foregroundStyle(RallyTheme.textSecondary) }
                                Button("Pick Source…") { pickerVisible = true }.buttonStyle(RallyActionStyle())
                            }.font(RallyFont.font(size: 12))
                        }
                    }.onChange(of: requestedPlayID) { id in if let id { reader.scrollTo(id, anchor: .center) } }
                        .onAppear { if let id = requestedPlayID { reader.scrollTo(id, anchor: .center) } }
                }
            }
            Spacer(minLength: 0)
        }.padding(14).frame(height: height, alignment: .topLeading)
            .background(RallyTheme.surfaceBase.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(RallyTheme.glassBorder, lineWidth: 0.7)).foregroundStyle(.white)
    }
    private var analyticsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Team Leaders").font(RallyFont.font(size: 15, weight: .semibold))
                HStack(alignment: .top, spacing: 10) { leadersColumn(team: event?.awayTeam); leadersColumn(team: event?.homeTeam) }
                if state.leaders.isEmpty { Text("Leaders have not been published yet.").foregroundStyle(RallyTheme.textSecondary) }
            }
            Divider().opacity(0.25)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Team Stats").font(RallyFont.font(size: 15, weight: .semibold)); Spacer(); Button("All Stats") { gameStatsExpanded.toggle() }.buttonStyle(.plain).font(RallyFont.font(size: 10)).foregroundStyle(RallyTheme.textSecondary) }
                HStack { Text(event?.awayTeam?.abbreviation ?? "Away"); Spacer(); Text(event?.homeTeam?.abbreviation ?? "Home") }.foregroundStyle(RallyTheme.textSecondary)
                ForEach(Array(displayTeamStats.enumerated()), id: \.offset) { _, stat in
                    HStack { Text(stat.awayValue).monospacedDigit().fontWeight(.semibold); Spacer(); Text(rallyStatLabel(stat.label)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1); Spacer(); Text(stat.homeValue).monospacedDigit().fontWeight(.semibold) }.padding(.vertical, 3)
                }
                if state.teamStats.isEmpty { Text("Stats have not been published yet.").foregroundStyle(RallyTheme.textSecondary) }
                if let home = state.homeWinPct, let away = state.awayWinPct {
                    HStack { Text("Win Probability").foregroundStyle(RallyTheme.textSecondary); Spacer(); Text("\(Int(away))% — \(Int(home))%") }.padding(.top, 5)
                }
            }
            Divider().opacity(0.25)
            VStack(alignment: .leading, spacing: 8) {
                Text(event?.sport == "football" && event?.status != .finished ? "Current Drive" : "Game Update").font(RallyFont.font(size: 15, weight: .semibold))
                ForEach(state.liveContext.keys.sorted().prefix(4), id: \.self) { key in diagRow(key, state.liveContext[key] ?? "") }
                Text(state.plays.first?.text ?? event?.gameStatusDetail ?? "Waiting for game updates.").lineLimit(3).foregroundStyle(RallyTheme.textSecondary)
            }
            if !state.plays.isEmpty {
                Divider().opacity(0.25)
                Text("Latest Plays").font(RallyFont.font(size: 15, weight: .semibold))
                ForEach(state.plays.prefix(2)) { play in
                    Button { requestedPlayID = play.id; infoTab = 3 } label: {
                        HStack(alignment: .top, spacing: 8) { Text(play.clock ?? "").monospacedDigit().foregroundStyle(RallyTheme.textSecondary); Text(play.text).lineLimit(2); Spacer(); Image(systemName: "chevron.right") }.font(RallyFont.font(size: 10))
                    }.buttonStyle(.plain)
                }
            }
        }.font(RallyFont.font(size: 11))
            .sheet(isPresented: $gameStatsExpanded) { ScrollView { VStack(alignment: .leading, spacing: 16) { HStack { Text("All Team Stats").font(.title3); Spacer(); Button("Done") { gameStatsExpanded = false } }; ForEach(state.teamStats, id: \.label) { stat in HStack { Text(stat.awayValue); Spacer(); Text(rallyStatLabel(stat.label)); Spacer(); Text(stat.homeValue) } } }.padding(24) }.frame(width: 540, height: 560).background(RallyTheme.background) }
    }
    private func leadersColumn(team: Team?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) { RallyTeamLogo(team: team, size: 24); Text(team?.abbreviation ?? "Team").fontWeight(.medium) }
            ForEach(Array(state.leaders.filter { $0.teamAbbr == team?.abbreviation }.prefix(3).enumerated()), id: \.offset) { _, leader in
                HStack(spacing: 6) {
                    if let image = leader.headshotUrl, let url = URL(string: image) { AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }.frame(width: 27, height: 27).clipShape(Circle()) }
                    VStack(alignment: .leading, spacing: 2) { Text(leader.playerShortName).lineLimit(1); Text(leader.category).font(RallyFont.font(size: 9)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1); Text(leader.statDisplay).font(RallyFont.font(size: 9)).foregroundStyle(.white).lineLimit(2) }
                }.font(RallyFont.font(size: 10))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var displayTeamStats: [TeamStatComparison] {
        let labels = ["Total Yards", "Passing", "Rushing", "1st Downs", "3rd down efficiency", "Possession"]
        let featured = labels.compactMap { label in state.teamStats.first { $0.label == label } }
        return featured.count >= 3 ? Array(featured.prefix(6)) : Array(state.teamStats.prefix(6))
    }
    private var scoreStrip: some View {
        HStack(spacing: 14) {
            RallyTeamLogo(team: event?.awayTeam, size: 40)
            Text(event?.awayTeam?.abbreviation ?? "").font(RallyFont.font(size: 17, weight: .medium))
            Text(event?.scoreAway.map(String.init) ?? "—").font(RallyFont.font(size: 34, weight: .semibold)).monospacedDigit()
            VStack(spacing: 3) {
                if let event { StatusBadge(status: event.status) }
                Text(event?.gameStatusDetail ?? "").font(RallyFont.font(size: 11)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
            }.frame(width: 136)
            Text(event?.scoreHome.map(String.init) ?? "—").font(RallyFont.font(size: 34, weight: .semibold)).monospacedDigit()
            Text(event?.homeTeam?.abbreviation ?? "").font(RallyFont.font(size: 17, weight: .medium))
            RallyTeamLogo(team: event?.homeTeam, size: 40)
        }.foregroundStyle(.white).frame(maxWidth: .infinity)
    }
    private var videoCard: some View {
        playbackSurface.aspectRatio(16.0 / 9.0, contentMode: .fit).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RallyTheme.glassBorder, lineWidth: 0.7)).onHover { gameVideoHovered = $0 }
    }
    private func highlightsList(width: CGFloat) -> some View {
        let clips = Array(state.clips.filter { $0.streamUrl != nil }.prefix(4))
        let scores = Array(state.plays.filter(\.isScoringPlay).prefix(max(0, 4 - clips.count)))
        let tileWidth = (width - 30) / 4
        return HStack(alignment: .top, spacing: 10) {
            ForEach(clips) { clip in
                Button { state.openClipOverlay(clip) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .bottomLeading) {
                            if let image = clip.thumbnailUrl, let url = URL(string: image) { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.black.opacity(0.4) }.frame(width: tileWidth, height: 58).clipped() }
                            else { Color.black.opacity(0.4) }
                            if let seconds = clip.durationSeconds { Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))").font(RallyFont.font(size: 9)).padding(4).background(.black.opacity(0.7)) }
                        }.frame(height: 58).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(clip.title).font(RallyFont.font(size: 10, weight: .medium)).lineLimit(2)
                    }.frame(width: tileWidth, alignment: .leading)
                }.buttonStyle(.plain)
            }
            ForEach(scores) { play in
                Button { requestedPlayID = play.id; infoTab = 3 } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack { if let event { RallyMatchupArtwork(event: event, scoreOverride: "\(play.awayScore ?? 0) — \(play.homeScore ?? 0)") } }.frame(height: 58).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(play.text).font(RallyFont.font(size: 10, weight: .medium)).lineLimit(2)
                    }.frame(width: tileWidth, alignment: .leading)
                }.buttonStyle(.plain)
            }
            if clips.isEmpty && scores.isEmpty { Text(state.detailLoading ? "Loading key moments…" : "Key moments appear as clips and scoring plays are published.").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary).padding(.vertical, 20) }
            Spacer(minLength: 0)
        }.foregroundStyle(.white)
    }
    private func liveRow(width: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) { ForEach(store.liveEvents.filter { $0.id != event?.id }) { other in TvLiveCard(event: other, focus: $liveFocus, size: CGSize(width: (width - 30) / 4, height: 58)) { Task { await state.load(event: other, channel: nil, store: store, drawable: host.surface) } } } }
        }
    }
    func openMultiView() {
        if let candidate = state.primary { store.multiView.add(candidate: candidate, event: event) }
        store.show(.multiView)
    }
}
