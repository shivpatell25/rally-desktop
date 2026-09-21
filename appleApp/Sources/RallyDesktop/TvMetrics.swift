import SwiftUI

/// Single scaling spine for all TV surfaces. Anchored at 1512pt (dev width):
/// layout at 1512 is pixel-identical to today; smaller/larger windows scale
/// geometry proportionally instead of stretching spacers.
struct TvMetrics {
    var width: CGFloat

    /// Geometry scale, clamped so type and touch targets stay usable.
    var scale: CGFloat { min(1.25, max(0.72, width / 1512)) }

    /// Scale a TV pt constant.
    func s(_ base: CGFloat) -> CGFloat { base * scale }

    var hPad: CGFloat { s(34) }
    var cardSpacing: CGFloat { 14 }
    var heroHeight: CGFloat { s(300) }
    var detailHeroHeight: CGFloat { s(300) }
    var liveCard: CGSize { CGSize(width: s(300), height: s(170)) }
    var sportCard: CGSize { CGSize(width: s(200), height: s(150)) }
    var portraitCard: CGSize { CGSize(width: s(250), height: s(375)) }
    var panelMinHeight: CGFloat { s(220) }

    /// Exact-fit card width so N cards fill the viewport (Phase 3 paging).
    func pageCardWidth(count: Int, aspect: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let w = (width - hPad * 2 - cardSpacing * CGFloat(count - 1)) / CGFloat(count)
        return (w, w / aspect)
    }

    static let reference = TvMetrics(width: 1512)
}

struct TvMetricsKey: EnvironmentKey {
    static let defaultValue = TvMetrics.reference
}

extension EnvironmentValues {
    var tvMetrics: TvMetrics {
        get { self[TvMetricsKey.self] }
        set { self[TvMetricsKey.self] = newValue }
    }
}
