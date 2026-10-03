import AppKit
import SwiftUI

/// SwiftUI's named scroll coordinate space is stationary in the macOS host.
/// Observe the actual clip view so guide morphing follows native wheel inertia.
struct RallyScrollObserver: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onScroll = onScroll; context.coordinator.attach(view) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }
    final class Coordinator {
        var onScroll: (CGFloat) -> Void
        weak var clip: NSClipView?
        var observer: NSObjectProtocol?
        init(onScroll: @escaping (CGFloat) -> Void) { self.onScroll = onScroll }
        func attach(_ view: NSView) {
            guard let scroll = view.enclosingScrollView, clip !== scroll.contentView else { return }
            detach(); clip = scroll.contentView
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self, let clip = self.clip else { return }
                self.onScroll(clip.bounds.origin.y)
            }
        }
        func detach() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
        deinit { detach() }
    }
}
