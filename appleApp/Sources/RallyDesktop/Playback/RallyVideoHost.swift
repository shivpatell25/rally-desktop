import AppKit
import RallyCore

/// The video renderer owns only `surface`. A sibling mark stays above it without
/// changing VLC's OpenGL hierarchy when a source or quality change recreates it.
final class RallyVideoHost: NSView {
    let surface = NSView()
    private let watermark = PassivePlayerMark()
    override init(frame: NSRect) {
        super.init(frame: frame)
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.black.cgColor
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        if let url = Artwork.artURL("rally_mark_ui") { watermark.image = NSImage(contentsOf: url) }
        watermark.imageScaling = .scaleProportionallyUpOrDown
        watermark.alphaValue = 0
        watermark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(watermark)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            watermark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            watermark.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            watermark.widthAnchor.constraint(equalToConstant: 24),
            watermark.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("RallyVideoHost is created in code") }
}
private final class PassivePlayerMark: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
