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

public enum UpdatePoll: Sendable, Equatable {
    case upToDate
    case available(RallyRelease)
    case failed(String)
}

public final class UpdateChecker: Sendable {
    public static let releasesURL = "https://api.github.com/repos/shivpatell25/rally-desktop/releases/latest"
    /// Release assets must come from our own repo (Android TRUSTED_RELEASE_PREFIX).
    public static let trustedAssetPrefix = "https://github.com/shivpatell25/rally-desktop/releases/download/"
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func check(currentVersion: String) async -> RallyRelease? {
        if case .available(let rel) = await poll(currentVersion: currentVersion) { return rel }
        return nil
    }

    /// Distinguishes up-to-date from network/parse/no-asset failures (nil-masked before).
    public func poll(currentVersion: String) async -> UpdatePoll {
        guard let url = URL(string: Self.releasesURL) else { return .failed("Bad update URL") }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Rally/macOS", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await session.data(for: req),
              let gh = try? JSONDecoder().decode(GHRelease.self, from: data) else {
            return .failed("Couldn't reach the update server. Check your connection and retry.")
        }
        guard let tag = gh.tag_name, !tag.isEmpty else { return .failed("The release feed had no version.") }
        guard compareVersions(tag, currentVersion) > 0 else { return .upToDate }
        let assets = gh.assets ?? []
        // macOS disk image only — never fall back to a foreign artifact (APK/ZIP).
        guard let asset = assets.first(where: {
            let n = ($0.name ?? "").lowercased()
            return n.hasSuffix(".dmg") || (n.contains("mac") && (n.hasSuffix(".zip") || n.hasSuffix(".dmg")))
        }), let assetUrl = asset.browser_download_url, !assetUrl.isEmpty else {
            return .failed("Version \(tag) is available but has no macOS disk image yet.")
        }
        guard assetUrl.hasPrefix(Self.trustedAssetPrefix) else {
            return .failed("Version \(tag) offers an asset outside our releases — refusing it.")
        }
        return .available(RallyRelease(tag: tag, title: gh.name ?? tag, notes: gh.body ?? "",
            pageUrl: gh.html_url ?? "", assetName: asset.name ?? tag, assetUrl: assetUrl, assetSize: asset.size ?? 0))
    }

    /// Port of `compareVersions` in RallyUpdateManager.kt: core padded to 3,
    /// channels rank stable(3) > rc(2) > beta(1) > other(0) with numeric suffix,
    /// so beta installs are offered the stable release.
    public func compareVersions(_ first: String, _ second: String) -> Int {
        func parts(_ v: String) -> (core: [Int], channel: Int, channelNum: Int) {
            let clean = v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV")).lowercased()
            let coreStr: String
            var channel = 3
            var channelNum = 0
            if let dash = clean.firstIndex(of: "-") {
                coreStr = String(clean[..<dash])
                let suffix = String(clean[clean.index(after: dash)...])
                func num(_ s: String, _ prefix: String) -> Int? {
                    guard s.hasPrefix(prefix) else { return nil }
                    return Int(String(s.dropFirst(prefix.count).prefix(while: { $0.isNumber })))
                }
                if let n = num(suffix, "rc") { channel = 2; channelNum = n }
                else if let n = num(suffix, "beta") { channel = 1; channelNum = n }
                else { channel = 0; channelNum = Int(String(suffix.prefix(while: { $0.isNumber }))) ?? 0 }
            } else {
                coreStr = clean
            }
            var core = coreStr.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber }).description) ?? 0 }
            while core.count < 3 { core.append(0) }
            return (core, channel, channelNum)
        }
        let a = parts(first), b = parts(second)
        for i in 0..<3 {
            if a.core[i] != b.core[i] { return a.core[i] < b.core[i] ? -1 : 1 }
        }
        if a.channel != b.channel { return a.channel < b.channel ? -1 : 1 }
        if a.channelNum != b.channelNum { return a.channelNum < b.channelNum ? -1 : 1 }
        return 0
    }
}
