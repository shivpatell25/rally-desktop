import RallyCore
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

/// Accessibility intent, set once in ContentView from Settings (high-contrast
/// focus rings, motion calming). System Reduce Motion also feeds the motion flag.
struct RallyHighContrastKey: EnvironmentKey {
    static let defaultValue = false
}
struct RallyReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var tvMetrics: TvMetrics {
        get { self[TvMetricsKey.self] }
        set { self[TvMetricsKey.self] = newValue }
    }
    var rallyHighContrast: Bool {
        get { self[RallyHighContrastKey.self] }
        set { self[RallyHighContrastKey.self] = newValue }
    }
    var rallyReduceMotion: Bool {
        get { self[RallyReduceMotionKey.self] }
        set { self[RallyReduceMotionKey.self] = newValue }
    }
}
extension View {
    /// Focus ring honoring high-contrast (3pt + brighter cyan).
    func rallyFocusRing(active: Bool, radius: CGFloat = 10,
                        activeColor: Color = RallyTheme.rallyCyan,
                        inactiveColor: Color = RallyTheme.glassBorder) -> some View {
        modifier(RallyFocusRing(active: active, radius: radius,
                                activeColor: activeColor, inactiveColor: inactiveColor))
    }
    func rallyAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(RallyAnimation(animation: animation, value: value))
    }
}

private struct RallyFocusRing: ViewModifier {
    @Environment(\.rallyHighContrast) private var highContrast
    var active: Bool
    var radius: CGFloat
    var activeColor: Color
    var inactiveColor: Color
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: radius).stroke(
            active ? (highContrast ? .white : activeColor) : inactiveColor,
            lineWidth: active ? (highContrast ? 3 : 2) : 1))
    }
}

private struct RallyAnimation<V: Equatable>: ViewModifier {
    @Environment(\.rallyReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var animation: Animation?
    var value: V
    func body(content: Content) -> some View {
        content.animation((reduceMotion || systemReduceMotion) ? nil : animation, value: value)
    }
}
