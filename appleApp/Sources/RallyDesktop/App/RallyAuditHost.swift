#if DEBUG
import AppKit
import SwiftUI

/// Opt-in, app-owned QA: actual accessibility actions and view snapshots.
/// No listener or file access exists in a release build.
struct RallyAuditHost: NSViewRepresentable {
    static var playerInfo: () -> String = { "" }
    var info: () -> String = { "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view; context.coordinator.info = info; context.coordinator.start(); return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.info = info }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.timer?.invalidate() }
    final class Coordinator {
        weak var view: NSView?
        var timer: Timer?
        var lastID = ""
        var info: () -> String = { "" }
        func start() {
            guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--qa-control-file=") }) else { return }
            let path = String(arg.dropFirst("--qa-control-file=".count))
            timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self, let window = self.view?.window,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = command["id"] as? String, id != self.lastID else { return }
                self.lastID = id
                let targetWindow = (command["window"] as? String).flatMap { title in NSApp.windows.first { $0.title == title } } ?? (command["main"] as? Bool == true ? window : (window.attachedSheet ?? NSApp.keyWindow ?? window))
                let result = self.run(command, window: targetWindow)
                let output = ["id": id, "result": result]
                if let bytes = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted]) { try? bytes.write(to: URL(fileURLWithPath: path + ".result"), options: .atomic) }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        func elements(_ object: Any, depth: Int = 0) -> [NSAccessibilityElementProtocol] {
            guard depth < 30 else { return [] }
            guard let item = object as? NSAccessibilityElementProtocol else { return [] }
            let children = (item as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            return [item] + children.flatMap { elements($0, depth: depth + 1) }
        }
        func run(_ command: [String: Any], window: NSWindow) -> String {
            let action = command["action"] as? String ?? ""
            switch action {
            case "status": return info() + "\n" + RallyAuditHost.playerInfo()
            case "windows":
                return NSApp.windows.map { "\($0.title) | \($0.frame) | visible=\($0.isVisible) key=\($0.isKeyWindow) sheet=\($0.isSheet)" }.joined(separator: "\n")
            case "capture":
                guard let path = command["path"] as? String, let content = window.contentView,
                      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return "capture unavailable" }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { return "capture failed" }
                do { try data.write(to: URL(fileURLWithPath: path)); return "captured" } catch { return error.localizedDescription }
            case "dump":
                let rows = elements(window).map { element -> String in
                    let item = element as? NSAccessibilityProtocol
                    return "\(String(describing: item?.accessibilityRole())) | \(item?.accessibilityLabel() ?? "") | \(String(describing: item?.accessibilityValue())) | \(item?.accessibilityIdentifier() ?? "")"
                }
                return rows.joined(separator: "\n")
            case "press":
                let target = command["target"] as? String ?? ""
                for element in elements(window) {
                    guard let item = element as? NSAccessibilityProtocol else { continue }
                    if item.accessibilityLabel() == target || item.accessibilityIdentifier() == target {
                        if item.accessibilityPerformPress() { return "pressed" }
                    }
                }
                return "missing button: \(target)"
            case "key":
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                let code = UInt16(command["code"] as? Int ?? 0)
                var flags: NSEvent.ModifierFlags = command["command"] as? Bool == true ? .command : []
                if command["control"] as? Bool == true { flags.insert(.control) }
                let text = command["text"] as? String ?? ""
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { return "bad event" }
                if flags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return "menu key" }
                NSApp.postEvent(event, atStart: false); return "key queued"
            case "click":
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                guard let content = window.contentView else { return "no content" }
                let y = command["y"] as? Double ?? 0
                let local = CGPoint(x: command["x"] as? Double ?? 0, y: content.isFlipped ? y : content.bounds.height - y)
                let point = content.convert(local, to: nil)
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
                }
                return "clicked"
            case "scroll":
                let x = command["x"] as? Double ?? 600, y = command["y"] as? Double ?? 500
                guard let content = window.contentView else { return "no content" }
                let hit = content.hitTest(CGPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y))
                var parent = hit
                while let view = parent {
                    if let scroll = view as? NSScrollView {
                        let amount = command["amount"] as? Double ?? 300
                        let current = scroll.contentView.bounds.origin
                        let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: CGPoint(x: current.x, y: min(maxY, max(0, current.y + amount))))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        return "scrolled \(scroll.contentView.bounds.origin.y) / \(maxY)"
                    }
                    parent = view.superview
                }
                return "no scroll view"
            case "resize":
                window.setContentSize(CGSize(width: command["width"] as? Double ?? 1440, height: command["height"] as? Double ?? 900)); return "resized"
            default: return "unknown action"
            }
        }
    }
}
#endif
