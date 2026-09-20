import Foundation
import Sparkle

/// Sparkle 2 updater. Feed: `appleApp/appcast.xml` served raw from GitHub
/// (`SUFeedURL` is set in the .app Info.plist at packaging time).
/// `UpdateChecker` (GitHub Releases API) stays as the fallback that deep-links
/// to the release page when Sparkle has nothing staged.
@MainActor
public final class SparkleUpdater: ObservableObject {
    public static let feedURL = "https://raw.githubusercontent.com/shivpatell25/rally-desktop/main/appleApp/appcast.xml"

    private let controller: SPUStandardUpdaterController

    public init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    public var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
