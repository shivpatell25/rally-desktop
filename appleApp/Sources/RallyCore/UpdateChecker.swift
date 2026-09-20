import Foundation

/// In-app update check against GitHub Releases. Mirrors `RallyUpdateManager.kt` state machine
/// minus the Android APK install step (macOS: download + mount, user drags to /Applications).
public struct RallyRelease: Sendable, Equatable {
    public var tag: String
    public var title: String
    public var notes: String
    public var pageUrl: String
    public var assetName: String
    public var assetUrl: String
    public var assetSize: Int64
    public init(tag: String, title: String, notes: String, pageUrl: String, assetName: String, assetUrl: String, assetSize: Int64) {
        self.tag = tag; self.title = title; self.notes = notes; self.pageUrl = pageUrl
        self.assetName = assetName; self.assetUrl = assetUrl; self.assetSize = assetSize
    }
}

private struct GHRelease: Decodable {
    var tag_name: String?
    var name: String?
    var body: String?
    var html_url: String?
    var assets: [GHAsset]?
}
private struct GHAsset: Decodable {
    var name: String?
    var browser_download_url: String?
    var size: Int64?
}

public final class UpdateChecker: Sendable {
    public static let releasesURL = "https://api.github.com/repos/shivpatell25/rally-desktop/releases/latest"
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func check(currentVersion: String) async -> RallyRelease? {
        guard let url = URL(string: Self.releasesURL) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await session.data(for: req),
              let gh = try? JSONDecoder().decode(GHRelease.self, from: data),
              let tag = gh.tag_name, compareVersions(tag, currentVersion) > 0 else { return nil }
        let macAsset = (gh.assets ?? []).first {
            ($0.name ?? "").lowercased().contains("mac") || ($0.name ?? "").lowercased().hasSuffix(".dmg")
        } ?? (gh.assets ?? []).first
        guard let asset = macAsset, let assetUrl = asset.browser_download_url else { return nil }
        return RallyRelease(tag: tag, title: gh.name ?? tag, notes: gh.body ?? "",
            pageUrl: gh.html_url ?? "", assetName: asset.name ?? tag, assetUrl: assetUrl, assetSize: asset.size ?? 0)
    }

    /// Port of `compareVersions` in RallyUpdateManager.kt.
    public func compareVersions(_ first: String, _ second: String) -> Int {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".").map { Int($0.split(separator: "-").first.map(String.init) ?? "") ?? 0 }
        }
        let a = parts(first), b = parts(second)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
