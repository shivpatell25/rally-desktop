import AppKit
import SwiftUI

/// Delivers Escape even when AppKit controls consume SwiftUI's exit command.
/// Scope the monitor to this view's window so Settings and popovers keep their
/// own native keyboard handling.
struct RallyEscapeHandler: NSViewRepresentable {
    var enabled = true
    let dismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.dismiss = dismiss
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        var enabled = false
        var dismiss: (() -> Void)?
        private var monitor: Any?
        func install(_ view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, self.enabled, event.keyCode == 53,
                      let window = view?.window, window === NSApp.keyWindow,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                self.dismiss?()
                return nil
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { remove() }
    }
}
