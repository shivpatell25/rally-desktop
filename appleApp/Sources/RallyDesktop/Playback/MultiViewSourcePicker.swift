import RallyCore
import SwiftUI

struct MultiViewSourcePicker: View {
    @EnvironmentObject var store: RallyStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: MultiViewState
    @State private var query = ""
    @State private var event: SportEvent?
    @State private var sources: [PlayCandidate] = []
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(event?.name ?? "Add a broadcast").font(.title3.bold()); Spacer(); Button("Done") { dismiss() } }
            if event != nil { Button("Back to Games and Channels") { event = nil } }
            TextField("Filter games and channels", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if loading { ProgressView("Finding sources…") }
                    else if event != nil {
                        if sources.isEmpty {
                            RallyEmptyState(eyebrow: "Sources", title: "No playable source found.", message: "Configure an IPTV provider or addon in Settings, or choose another game.")
                        }
                        ForEach(sources) { candidate in sourceRow(candidate) }
                    } else {
                        Text("Games").font(.headline)
                        ForEach((store.liveEvents + store.upcomingEvents).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { game in
                            Button { event = game } label: {
                                HStack { Text(game.name); Spacer(); StatusBadge(status: game.status); Image(systemName: "chevron.right") }.rallySurface(padding: 12)
                            }.buttonStyle(.plain)
                        }
                        Text("Channels").font(.headline).padding(.top, 12)
                        ForEach(store.channels.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(100)) { channel in
                            if let candidate = StreamResolver.channelCandidates([channel]).first { sourceRow(candidate) }
                        }
                    }
                }
            }
        }.padding(24).frame(width: 620, height: 520).background(RallyTheme.deepNavy)
            .task { await store.ensureChannels() }
            .task(id: event?.id) {
                sources = []
                guard let event else { loading = false; return }
                loading = true
                let options = await withTaskGroup(of: [StremioStreamOption].self) { group in
                    for addon in store.settings.stremioAddonUrls { group.addTask { await store.stremioClient.findStreams(for: event, addonBase: addon) } }
                    var values: [StremioStreamOption] = []
                    for await result in group { values += result }
                    return values
                }
                guard !Task.isCancelled else { return }
                sources = StreamResolver.candidates(event: event, channels: store.channels, stremioOptions: options)
                loading = false
            }
    }
    private func sourceRow(_ candidate: PlayCandidate) -> some View {
        Button {
            state.add(candidate: candidate, event: event); dismiss()
        } label: {
            HStack { Text(candidate.title).lineLimit(2); Spacer(); Image(systemName: "plus.circle") }.rallySurface(padding: 12)
        }.buttonStyle(.plain).disabled(!state.canAdd || state.tiles.contains(where: { $0.candidate.id == candidate.id }))
    }
}
