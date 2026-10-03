import AppKit
import SwiftUI

/// Observe actual input in this window. Waking consumes the initiating input so
/// a hidden button never activates. A inactive window never steals key focus.
struct RallyWindowActivity: NSViewRepresentable {
    var sleeping: Bool
    var activity: () -> Void
    var keyChanged: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.sleeping = sleeping; c.activity = activity; c.keyChanged = keyChanged
        DispatchQueue.main.async { [weak c] in c?.attach() }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        weak var view: NSView?
        weak var window: NSWindow?
        var sleeping = false
        var activity: (() -> Void)?
        var keyChanged: ((Bool) -> Void)?
        var monitor: Any?
        var observers: [NSObjectProtocol] = []
        var lastReported = Date.distantPast
        func attach() {
            guard let next = view?.window, window !== next else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = next
            next.acceptsMouseMovedEvents = true
            let nc = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(nc.addObserver(forName: name, object: next, queue: .main) { [weak self] note in
                    guard let self else { return }
                    let active = note.name == NSWindow.didBecomeKeyNotification
                    self.keyChanged?(active)
                    if active { self.activity?() }
                })
            }
            keyChanged?(next.isKeyWindow)
        }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .magnify, .swipe]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.isKeyWindow else { return event }
                let wake = self.sleeping
                if wake || Date().timeIntervalSince(self.lastReported) > 0.5 {
                    self.lastReported = Date(); self.activity?()
                }
                return wake ? nil : event
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        }
        deinit { remove() }
    }
}
