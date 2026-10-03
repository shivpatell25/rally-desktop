import RallyCore
import SwiftUI

/// Shared title hierarchy for full-window destinations.
struct RallyPageHeader: View {
    @Environment(\.tvMetrics) private var metrics
    var eyebrow: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if title.caseInsensitiveCompare(eyebrow) != .orderedSame {
                Text(eyebrow.uppercased()).font(RallyFont.font(size: metrics.eyebrowSize, weight: .medium)).tracking(1.5).foregroundStyle(RallyTheme.textSecondary)
            }
            Text(title)
                .font(RallyFont.display(metrics.pageTitleSize, weight: .semibold))
                .tracking(-0.55)
                .foregroundStyle(RallyTheme.textPrimary)
            Text(subtitle)
                .font(RallyFont.font(size: metrics.bodySize, weight: .medium))
                .foregroundStyle(RallyTheme.textSecondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RallyEmptyState: View {
    @Environment(\.tvMetrics) private var metrics
    var eyebrow: String
    var title: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(RallyFont.font(size: metrics.eyebrowSize, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(RallyTheme.textPrimary)
            Text(title)
                .font(RallyFont.font(size: metrics.pageTitleSize - 5, weight: .bold))
                .foregroundStyle(RallyTheme.textPrimary)
            Text(message)
                .font(RallyFont.font(size: metrics.bodySize))
                .foregroundStyle(RallyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, metrics.layout == .compact ? 18 : 24)
    }
}

extension View {
    func rallySurface(radius: CGFloat = 8, padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(RallyTheme.glassSurface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(RallyTheme.glassBorder, lineWidth: 1)
            }
    }
}

private let rallyKnownStatLabels = [
    "totalPointsPerGame": "Points per game",
    "yardsPerGame": "Total yards",
    "passingYardsPerGame": "Passing yards",
    "rushingYardsPerGame": "Rushing yards",
    "totalPointsPerGameAllowed": "Points allowed",
    "yardsPerGameAllowed": "Yards allowed",
    "passingYardsPerGameAllowed": "Pass yards allowed",
    "rushingYardsPerGameAllowed": "Rush yards allowed",
]

func rallyStatLabel(_ raw: String) -> String {
    if let label = rallyKnownStatLabels[raw] { return label }
    let spaced = raw.replacingOccurrences(of: "_", with: " ")
    guard spaced == raw, raw.rangeOfCharacter(from: .uppercaseLetters) != nil else {
        return spaced.capitalized
    }
    var result = ""
    for scalar in raw.unicodeScalars {
        if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
            result.append(" ")
        }
        result.append(Character(scalar))
    }
    return result.capitalized
}

/// ESPN tables can expose 10+ columns. Pick the meaningful game line rather
/// than blindly showing the first columns, which are often minutes/attempts.
func rallyPreferredStatIndices(_ labels: [String], limit: Int = 4) -> [Int] {
    guard labels.count > limit else { return Array(labels.indices) }
    let upper = labels.map { $0.uppercased() }
    let preferred: [String]
    if upper.contains("PTS") {
        preferred = ["PTS", "REB", "AST", "FG"]
    } else if upper.contains("YDS") {
        preferred = ["C/ATT", "CAR", "REC", "YDS", "TD", "INT"]
    } else if upper.contains("RBI") {
        preferred = ["AB", "R", "H", "RBI"]
    } else if upper.contains("SOG") {
        preferred = ["G", "A", "PTS", "SOG"]
    } else {
        return Array(labels.indices.prefix(limit))
    }
    let selected = preferred.compactMap { wanted in upper.firstIndex(of: wanted) }
    return Array(selected.prefix(limit))
}
