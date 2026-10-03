import AppKit
import AVFoundation
import Foundation

public struct PlaybackTrack: Identifiable, Equatable {
    public var id: Int
    public var title: String
    public var selected: Bool
    public init(id: Int, title: String, selected: Bool = false) { self.id = id; self.title = title; self.selected = selected }
}
public struct PlaybackQuality: Identifiable, Equatable {
    public var id: Int { height }
    public var height: Int
    public var bitrate: Double
    public init(height: Int, bitrate: Double) { self.height = height; self.bitrate = bitrate }
}

@MainActor
public final class PlaybackController: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    @Published public private(set) var error: String?
    @Published public private(set) var audioTracks: [PlaybackTrack] = []
    @Published public private(set) var captionTracks: [PlaybackTrack] = []
    @Published public private(set) var qualities: [PlaybackQuality] = []
    public let player = AVPlayer()
    @Published public private(set) var ended = false
    private var endObserver: NSObjectProtocol?
    private var observation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var audioGroup: AVMediaSelectionGroup?
    private var captionGroup: AVMediaSelectionGroup?
    private var generation = UUID()
    public init() {
        observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }
    public func play(url: URL, headers: [String: String]? = nil, lowLatency: Bool = false) {
        error = nil; ended = false; audioGroup = nil; captionGroup = nil; audioTracks = []; captionTracks = []; qualities = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        generation = UUID()
        let current = generation
        let asset = AVURLAsset(url: url, options: headers.map { ["AVURLAssetHTTPHeaderFieldsKey": $0] } ?? [:])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = lowLatency ? 2 : 8
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard self?.generation == current else { return }
                if item.status == .failed { self?.error = item.error?.localizedDescription ?? "The stream could not be decoded." }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.generation == current else { return }; self.ended = true; self.isPlaying = false; self.isBuffering = false }
        }
        player.replaceCurrentItem(with: item); player.play()
        Task {
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let captions = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard generation == current else { return }
            audioGroup = audio; captionGroup = captions; refreshTracks()
        }
        Task {
            let options = await Self.loadQualities(url: url, headers: headers ?? [:])
            if generation == current { qualities = options }
        }
    }
    public nonisolated static func loadQualities(url: URL, headers: [String: String]) async -> [PlaybackQuality] {
        var request = URLRequest(url: url, timeoutInterval: 8)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            let type = response.mimeType?.lowercased() ?? ""
            guard ["m3u8", "mpd"].contains(url.pathExtension.lowercased()) || type.contains("mpegurl") || type.contains("dash+xml") else { return [] }
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 2_000_000 || Task.isCancelled { return [] } }
            return String(data: data, encoding: .utf8).map(parseQualities) ?? []
        } catch { return [] }
    }

    public func waitUntilReady(timeout: TimeInterval = 12) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout), current = generation
        while Date() < deadline && !Task.isCancelled && generation == current {
            if player.currentItem?.status == .failed { return false }
            if player.currentItem?.status == .readyToPlay { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
    public func refreshTracks() {
        guard let item = player.currentItem else { return }
        if let group = audioGroup {
            audioTracks = group.options.enumerated().map { PlaybackTrack(id: $0.offset, title: $0.element.displayName, selected: item.currentMediaSelection.selectedMediaOption(in: group) == $0.element) }
        }
        if let group = captionGroup {
            captionTracks = group.options.enumerated().map { PlaybackTrack(id: $0.offset, title: $0.element.displayName, selected: item.currentMediaSelection.selectedMediaOption(in: group) == $0.element) }
        }
    }
    public func selectTrack(_ id: Int, captions: Bool) {
        guard let group = captions ? captionGroup : audioGroup, let item = player.currentItem else { return }
        item.select(group.options.indices.contains(id) ? group.options[id] : nil, in: group); refreshTracks()
    }
    public func setQuality(_ quality: PlaybackQuality?) {
        player.currentItem?.preferredPeakBitRate = quality?.bitrate ?? 0
        player.currentItem?.preferredMaximumResolution = quality.map { CGSize(width: CGFloat($0.height) * 16 / 9, height: CGFloat($0.height)) } ?? .zero
    }
    public var seekRange: ClosedRange<Double>? {
        guard let item = player.currentItem else { return nil }
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            if start.isFinite && end.isFinite && end > start { return start...end }
        }
        let duration = item.duration.seconds
        return duration.isFinite && duration > 0 ? 0...duration : nil
    }
    public func seek(fraction: Double) {
        guard let range = seekRange else { return }
        seek(seconds: range.lowerBound + (range.upperBound - range.lowerBound) * min(1, max(0, fraction)))
    }
    public func seek(seconds: Double) {
        guard let range = seekRange else { return }
        player.seek(to: CMTime(seconds: min(range.upperBound, max(range.lowerBound, seconds)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    public func seekRelative(_ seconds: Double) { seek(seconds: player.currentTime().seconds + seconds) }
    public func watchFromStart() { if let range = seekRange { seek(seconds: range.lowerBound) } }
    public func goLive() { if let range = seekRange { seek(seconds: max(range.lowerBound, range.upperBound - 1)) }; resume() }
    public func position() -> (fraction: Double, clock: String)? {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return nil }
        let s = max(0, Int(seconds)), range = seekRange
        let fraction = range.map { (seconds - $0.lowerBound) / ($0.upperBound - $0.lowerBound) } ?? 0
        return (max(0, min(1, fraction)), String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60))
    }
    public func pause() { player.pause() }
    public func resume() { ended = false; player.play() }
    public func stop() {
        generation = UUID(); statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        ended = false; audioGroup = nil; captionGroup = nil; audioTracks = []; captionTracks = []
        player.pause(); player.replaceCurrentItem(with: nil); isPlaying = false; isBuffering = false
    }
    public nonisolated static func parseQualities(_ manifest: String) -> [PlaybackQuality] {
        var values: [Int: Double] = [:]
        if manifest.contains("<MPD") {
            let tags = try? NSRegularExpression(pattern: #"<Representation\b[^>]*>"#)
            let ns = manifest as NSString
            for match in tags?.matches(in: manifest, range: NSRange(location: 0, length: ns.length)) ?? [] {
                let tag = ns.substring(with: match.range)
                func attribute(_ key: String) -> Double? {
                    guard let regex = try? NSRegularExpression(pattern: key + #"=["']([0-9]+)["']"#),
                          let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
                    return Double((tag as NSString).substring(with: match.range(at: 1)))
                }
                if let height = attribute("height"), height > 0 { values[Int(height)] = max(values[Int(height)] ?? 0, attribute("bandwidth") ?? 0) }
            }
        }
        for line in manifest.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let resolution = line.components(separatedBy: "RESOLUTION=").dropFirst().first?.components(separatedBy: ",").first
            guard let height = resolution?.components(separatedBy: "x").last.flatMap(Int.init) else { continue }
            let raw = line.components(separatedBy: "BANDWIDTH=").dropFirst().first?.components(separatedBy: ",").first ?? "0"
            values[height] = max(values[height] ?? 0, Double(raw) ?? 0)
        }
        return values.map { PlaybackQuality(height: $0.key, bitrate: $0.value) }.sorted { $0.height > $1.height }
    }
}
