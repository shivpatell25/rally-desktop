import RallyCore
import SwiftUI

/// Responsive geometry shared by every full-window TV surface.
/// Rally composition proportions stay consistent while rails expose more cards.
struct TvMetrics {
    enum Layout {
        case compact
        case standard
        case wide
    }

    var width: CGFloat
    var height: CGFloat = 900
    var largeText = false
    private var typeScale: CGFloat { largeText ? 1.2 : 1 }

    var layout: Layout {
        if width < 1180 { return .compact }
        if width >= 1680 { return .wide }
        return .standard
    }

    /// Legacy geometry scale for media surfaces. Type and chrome use named
    /// metrics below and therefore stay stable while the window resizes.
    var scale: CGFloat { min(1.15, max(0.78, width / 1512)) }
    func s(_ base: CGFloat) -> CGFloat { base * scale }

    var hPad: CGFloat { min(100, max(32, width * 0.06)) }
    var contentMaxWidth: CGFloat { 1720 }
    var contentWidth: CGFloat { min(width - hPad * 2, contentMaxWidth) }
    var cardSpacing: CGFloat { layout == .compact ? 12 : 16 }
    var sectionSpacing: CGFloat { layout == .compact ? 26 : 32 }
    var pageTopPadding: CGFloat { layout == .compact ? 16 : 22 }
    var toolbarHeight: CGFloat { layout == .compact ? 82 : 96 }
    var wordmarkWidth: CGFloat { layout == .compact ? 184 : (layout == .wide ? 252 : 220) }
    var navItemWidth: CGFloat { layout == .compact ? 64 : 76 }
    var navHorizontalPadding: CGFloat { layout == .compact ? 10 : 16 }
    var toolbarActionSize: CGFloat { layout == .compact ? 44 : 48 }
    var eyebrowSize: CGFloat { (layout == .compact ? 10 : 11) * typeScale }
    var pageTitleSize: CGFloat { (layout == .compact ? 26 : 30) * typeScale }
    var sectionTitleSize: CGFloat { (layout == .compact ? 20 : 23) * typeScale }
    var cardTitleSize: CGFloat { (layout == .compact ? 16 : 18) * typeScale }
    var bodySize: CGFloat { (layout == .compact ? 13 : 14) * typeScale }

    var heroHeight: CGFloat { min(340, max(230, (height - 90) * 0.35)) }
    var detailHeroHeight: CGFloat { heroHeight }
    var mediaWidth: CGFloat { max(200, (contentWidth - cardSpacing * 2) / 3) }
    var liveCard: CGSize { CGSize(width: mediaWidth, height: mediaWidth / 2.65) }
    var sportCard: CGSize { CGSize(width: s(200), height: s(150)) }
    var portraitCard: CGSize { CGSize(width: s(250), height: s(375)) }
    var panelMinHeight: CGFloat { s(220) }

    func pageCardWidth(count: Int, aspect: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let w = (contentWidth - cardSpacing * CGFloat(count - 1)) / CGFloat(count)
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
                        activeColor: Color = .white.opacity(0.65),
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
