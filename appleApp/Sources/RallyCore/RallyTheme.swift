import SwiftUI

/// Rally TV palette shared by the approved compositions and Apple TV reference.
public enum RallyTheme {
    public static let rallyLime = Color(red: 0xE5/255, green: 0xEE/255, blue: 0x92/255)
    public static let rallyMint = Color(red: 0xAA/255, green: 0xE7/255, blue: 0xCE/255)
    public static let rallyCyan = Color(red: 0x5E/255, green: 0xDB/255, blue: 0xF0/255)
    public static let deepNavy = Color(red: 0x05/255, green: 0x05/255, blue: 0x07/255)
    public static let slate = Color(red: 0x10/255, green: 0x13/255, blue: 0x17/255)
    public static let graphite = Color(red: 0x25/255, green: 0x2B/255, blue: 0x30/255)
    public static let offWhite = Color(red: 0xFF/255, green: 0xFF/255, blue: 0xFF/255)

    public static let background = deepNavy
    public static let backgroundElevated = slate
    public static let glassSurface = Color(red: 0x10/255, green: 0x13/255, blue: 0x17/255)
    public static let glassBorder = Color(red: 0x25/255, green: 0x2B/255, blue: 0x30/255)
    public static let glassBorderFocused = Color.white.opacity(0.65)
    public static let surfaceBase = Color(red: 0x10/255, green: 0x13/255, blue: 0x17/255)
    public static let surfaceRaised = Color(red: 0x17/255, green: 0x1B/255, blue: 0x20/255)
    public static let surfaceFocused = Color(red: 0x20/255, green: 0x26/255, blue: 0x2B/255)

    public static let accent = offWhite
    public static let liveRed = Color(red: 0xFF/255, green: 0x33/255, blue: 0x48/255)
    public static let goldBadge = Color(red: 1, green: 0xD6/255, blue: 0x0A/255)

    public static let textPrimary = offWhite
    public static let textSecondary = Color(red: 0xAE/255, green: 0xB4/255, blue: 0xBD/255)
    public static let textTertiary = Color(red: 0x73/255, green: 0x7C/255, blue: 0x88/255)

    public static let heroCorner: CGFloat = 12
    public static let cardCorner: CGFloat = 10
    public static let buttonCorner: CGFloat = 8
    /// Matches `CardFocusScale` 1.025 — subtle lift, no large-layer overdraw.
    public static let cardFocusScale: CGFloat = 1.025
}
