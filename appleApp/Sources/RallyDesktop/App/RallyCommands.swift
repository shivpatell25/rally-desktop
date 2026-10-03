import AppKit
import RallyCore
import SwiftUI

struct RallyCommands: Commands {
    @ObservedObject var store: RallyStore
    private func go(_ destination: TvDestination) {
        store.navigate(destination)
    }
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openSettings() }.keyboardShortcut(",")
        }
        CommandMenu("Navigate") {
            Button("Home") { go(.home) }.keyboardShortcut("1")
            Button("Live") { go(.live) }.keyboardShortcut("2")
            Button("Schedule") { go(.schedule) }.keyboardShortcut("3")
            Button("Leagues") { go(.leagues) }.keyboardShortcut("4")
            Button("My Rally") { go(.myTeams) }.keyboardShortcut("5")
            Button("Highlights") { go(.highlights) }.keyboardShortcut("6")
            Divider()
            Button("Search…") { store.show(.search) }.keyboardShortcut("f")
            Button("Refresh") { Task { await store.refresh(); if store.destination == .schedule { await store.refreshSchedule() } } }
                .keyboardShortcut("r")
            Button("Close Overlay") { if store.hasPlayer { post(.dismiss) } else { store.show(nil) } }.keyboardShortcut(.escape, modifiers: [])
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { post(.togglePlay) }.keyboardShortcut(.space, modifiers: []).disabled(!store.hasPlayer)
            Button("Seek Back 10 Seconds") { post(.seekBack) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!store.hasPlayer)
            Button("Seek Forward 10 Seconds") { post(.seekForward) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!store.hasPlayer)
            Button("Mute / Unmute") { post(.mute) }.keyboardShortcut("m", modifiers: []).disabled(!store.hasPlayer)
            Button("Restart") { post(.fromStart) }.disabled(!store.hasPlayer)
            Button("Go to Live Edge") { post(.liveEdge) }.disabled(!store.hasPlayer)
            Button("Pick Source") { post(.source) }.keyboardShortcut("s", modifiers: []).disabled(!store.hasPlayer)
            Divider()
            Button("Enter / Exit Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.command, .control])
        }
    }
    private func post(_ action: PlayerCommand) {
        NotificationCenter.default.post(name: .rallyPlayerCommand, object: action)
    }
}

func openSettings() {
    NotificationCenter.default.post(name: .rallyOpenSettings, object: nil)
}
@available(macOS 14, *)
struct SettingsBridge: View {
    @Environment(\.openSettings) private var showSettings
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .rallyOpenSettings)) { _ in
                showSettings(); NSApp.activate(ignoringOtherApps: true)
            }
    }
}
struct LegacySettingsBridge: View {
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .rallyOpenSettings)) { _ in
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
    }
}

enum PlayerCommand { case togglePlay, play, pause, seekBack, seekForward, mute, fromStart, liveEdge, source, dismiss }
extension Notification.Name {
    static let rallyOpenSettings = Notification.Name("Rally.OpenSettings")
    static let rallyPlayerCommand = Notification.Name("Rally.PlayerCommand") }
extension RallyStore {
    var hasEventDetail: Bool { if case .eventDetail = sheet { return true }; return false }
    var hasMultiView: Bool { if case .multiView = sheet { return true }; return false }
    var hasPlayer: Bool { if case .player = sheet { return true }; return false }
}
