import RallyCore
import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.tvMetrics) private var metrics
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var league = "All Leagues"
    @State private var status = "All"
    @State private var sport = "All Sports"
    private var dates: [Date] {
        (-1...7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: Date())) }
    }
    private var filtered: [SportEvent] {
        store.scheduleEvents.filter {
            Calendar.current.isDate($0.startTime, inSameDayAs: date) && (league == "All Leagues" || $0.league == league) && (sport == "All Sports" || $0.sport == sport)
                && (status == "All" || (status == "Live" && [.live, .halftime].contains($0.status))
                    || (status == "Upcoming" && [.notStarted, .delayed].contains($0.status))
                    || (status == "Final" && $0.status == .finished))
        }.sorted { $0.startTime < $1.startTime }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Schedule").font(RallyFont.display(34)).foregroundStyle(.white)
                Spacer()
                Button { Task { await store.refreshSchedule() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh schedule").disabled(store.scheduleLoading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dates, id: \.self) { day in
                        Button { date = day } label: {
                            VStack(spacing: 4) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                                Text(day.formatted(.dateTime.month(.abbreviated).day())).font(RallyFont.font(size: 14, weight: .semibold))
                            }.frame(width: 88, height: 54)
                                .foregroundStyle(date == day ? .black : RallyTheme.textPrimary)
                                .background(date == day ? RallyTheme.offWhite : RallyTheme.surfaceBase.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 20) {
                Menu {
                    Button("All Sports") { sport = "All Sports" }
                    ForEach(Array(Set(store.scheduleEvents.map(\.sport))).sorted(), id: \.self) { name in Button(name.capitalized) { sport = name } }
                } label: { Text(sport.capitalized) }.menuStyle(.borderlessButton).fixedSize()
                Menu {
                    Button("All Leagues") { league = "All Leagues" }
                    ForEach(Array(Set(store.scheduleEvents.map(\.league))).sorted(), id: \.self) { name in Button(name) { league = name } }
                } label: { Label(league, systemImage: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize()
                RallyTabs(items: ["All", "Live", "Upcoming", "Final"].map { ($0, $0) }, selection: $status, compact: true)
                Text("\(filtered.count) games").font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary).fixedSize()
            }.foregroundStyle(.white)
            HStack {
                Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(RallyFont.font(size: 22, weight: .semibold))
                Spacer()
                Button("Clear Filters") { league = "All Leagues"; sport = "All Sports"; status = "All" }.buttonStyle(.plain).foregroundStyle(RallyTheme.textSecondary)
            }
            if let error = store.scheduleError {
                HStack { Text(error).font(.callout); Button("Try Again") { Task { await store.refreshSchedule() } } }
            }
            if store.scheduleLoading && store.scheduleEvents.isEmpty {
                ProgressView("Loading schedule…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                RallyEmptyState(eyebrow: "Schedule", title: "No games in this selection.", message: "Choose another date or clear the league and status filters.")
                Button("Clear Filters") { league = "All Leagues"; sport = "All Sports"; status = "All" }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(filtered) { RallyEventRow(event: $0) } }
                        .background(RallyTheme.surfaceBase.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RallyTheme.glassBorder, lineWidth: 0.6))
                }
            }
        }.padding(.horizontal, metrics.hPad).padding(.top, 22).padding(.bottom, 28)
            .task { await store.refreshSchedule(); if !dates.contains(date), let first = dates.first { date = first } }
    }
}

struct RallyEventRow: View {
    let event: SportEvent
    @EnvironmentObject var store: RallyStore
    @EnvironmentObject var settings: SettingsStore
    @State private var hover = false
    var body: some View {
        HStack(spacing: 16) {
            Text(event.startTime.formatted(.dateTime.hour().minute())).font(RallyFont.font(size: 14)).foregroundStyle(RallyTheme.textSecondary).frame(width: 88, alignment: .leading)
            Button { store.show(.eventDetail(event)) } label: {
                HStack(spacing: 18) {
                    HStack(spacing: 12) { RallyTeamLogo(team: event.awayTeam); RallyTeamLogo(team: event.homeTeam) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.rallyMatchup).font(RallyFont.font(size: 16, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Text(event.gameStatusDetail ?? event.venue ?? event.sport.capitalized).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    if [.live, .halftime, .finished].contains(event.status), let away = event.scoreAway, let home = event.scoreHome {
                        Text("\(away) — \(home)").font(RallyFont.font(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    }
                    Text(event.league).font(RallyFont.font(size: 12)).foregroundStyle(RallyTheme.textSecondary).frame(width: 58)
                    if [.live, .halftime, .delayed, .canceled].contains(event.status) { StatusBadge(status: event.status) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(event.name)
            Button { settings.toggleSavedEvent(event) } label: {
                Image(systemName: settings.savedEventIds.contains(event.id) ? "bell.badge.fill" : "bell").font(RallyFont.font(size: 17))
                    .foregroundStyle(settings.savedEventIds.contains(event.id) ? RallyTheme.textPrimary : RallyTheme.textSecondary)
            }.buttonStyle(.plain).help(settings.savedEventIds.contains(event.id) ? "Remove from watchlist" : "Save game / reminder")
        }.padding(.horizontal, 18).padding(.vertical, 15)
            .background(hover ? Color.white.opacity(0.04) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(RallyTheme.glassBorder).frame(height: 0.6) }
            .onHover { hover = $0 }
            .contextMenu {
                Button("Open Event") { store.show(.eventDetail(event)) }
                Button("Watch") { store.show(.player(event: event, channel: nil)) }
                Button(settings.savedEventIds.contains(event.id) ? "Remove from Watchlist" : "Add to Watchlist") { settings.toggleSavedEvent(event) }
            }
    }
}
