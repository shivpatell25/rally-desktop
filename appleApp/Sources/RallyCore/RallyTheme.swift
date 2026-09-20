import SwiftUI

/// 1:1 color tokens from `presentation/theme/AppleTvTheme.kt`.
/// Same hex, same roles — glass alpha layers, no realtime blur (cheap on low-end GPUs).
public enum RallyTheme {
    public static let rallyLime = Color(red: 0xEA/255, green: 0xFB/255, blue: 0x78/255)
    public static let rallyMint = Color(red: 0xB8/255, green: 0xF3/255, blue: 0xC7/255)
    public static let rallyCyan = Color(red: 0x6F/255, green: 0xCF/255, blue: 0xF6/255)
    public static let deepNavy = Color(red: 0x05/255, green: 0x08/255, blue: 0x0F/255)
    public static let slate = Color(red: 0x0F/255, green: 0x17/255, blue: 0x24/255)
    public static let graphite = Color(red: 0x20/255, green: 0x28/255, blue: 0x34/255)
    public static let offWhite = Color(red: 0xF5/255, green: 0xF7/255, blue: 0xFA/255)

    public static let background = deepNavy
    public static let backgroundElevated = slate
    public static let glassSurface = Color(red: 0x0A/255, green: 0x10/255, blue: 0x1B/255, opacity: 0xA6/255)
    public static let glassBorder = Color(red: 0x6B/255, green: 0x89/255, blue: 0xA5/255, opacity: 0x59/255)
    public static let glassBorderFocused = rallyCyan
    public static let surfaceBase = Color(red: 0x0A/255, green: 0x10/255, blue: 0x1B/255)
    public static let surfaceRaised = Color(red: 0x11/255, green: 0x1B/255, blue: 0x2A/255)
    public static let surfaceFocused = Color(red: 0x17/255, green: 0x24/255, blue: 0x37/255)

    public static let accent = rallyCyan
    public static let liveRed = Color(red: 1, green: 0x45/255, blue: 0x3A/255)
    public static let goldBadge = Color(red: 1, green: 0xD6/255, blue: 0x0A/255)

    public static let textPrimary = offWhite
    public static let textSecondary = offWhite.opacity(0xB8/255)
    public static let textTertiary = offWhite.opacity(0x73/255)

    public static let heroCorner: CGFloat = 12
    public static let cardCorner: CGFloat = 10
    public static let buttonCorner: CGFloat = 8
    /// Matches `CardFocusScale` 1.025 — subtle lift, no large-layer overdraw.
    public static let cardFocusScale: CGFloat = 1.025
}
