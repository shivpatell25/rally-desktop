import Foundation

/// Lightweight availability check that never downloads a video body.
/// 1:1 port of `data/remote/network/StreamPreflightProbe.kt`: HEAD first,
/// Range `bytes=0-1023` fallback, HTML bodies rejected.
public struct StreamPreflightResult: Sendable, Equatable {
    public var passed: Bool
    public var latencyMs: Int64
    public var contentType: String?
    public var statusCode: Int?
    public var detail: String
    public init(passed: Bool, latencyMs: Int64, contentType: String? = nil,
                statusCode: Int? = nil, detail: String) {
        self.passed = passed; self.latencyMs = latencyMs; self.contentType = contentType
        self.statusCode = statusCode; self.detail = detail
    }
}

public struct StreamPreflightProbe: Sendable {
    public static let shared = StreamPreflightProbe()
    private static let retryStatuses: Set<Int> = [403, 405, 501]
    private let session: URLSession
    public init(callTimeout: TimeInterval = 3, protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = callTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config)
    }

    public func probe(url: String, headers: [String: String] = [:]) async -> StreamPreflightResult {
        guard url.hasPrefix("http://") || url.hasPrefix("https://"),
              let target = URL(string: url) else {
            return StreamPreflightResult(passed: false, latencyMs: 0,
                                         detail: "Provider link must be resolved first")
        }
        let started = Date()
        let base = StreamRequestHeaders.sanitized(headers)
        if let head = await attempt(url: target, headers: base, head: true, started: started),
           head.passed || !(head.statusCode.map(Self.retryStatuses.contains) ?? false) {
            return head
        }
        if let range = await attempt(url: target, headers: base, head: false, started: started) {
            return range
        }
        return StreamPreflightResult(passed: false, latencyMs: elapsedMs(since: started),
                                     detail: "Connection failed")
    }

    private func request(url: URL, headers: [String: String], head: Bool) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = head ? "HEAD" : "GET"
        req.setValue("Rally/1.0 macOS", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.apple.mpegurl, application/x-mpegURL, video/*, */*",
                     forHTTPHeaderField: "Accept")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        if !head { req.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }
        return req
    }

    private func attempt(url: URL, headers: [String: String], head: Bool, started: Date) async -> StreamPreflightResult? {
        do {
            let (_, response) = try await session.data(for: request(url: url, headers: headers, head: head))
            guard let http = response as? HTTPURLResponse else { return nil }
            let type = http.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            let html = type?.lowercased().contains("text/html") ?? false
            let passed = (200..<300).contains(http.statusCode) && !html
            return StreamPreflightResult(
                passed: passed, latencyMs: elapsedMs(since: started),
                contentType: type, statusCode: http.statusCode,
                detail: html ? "Received a web page instead of video"
                    : passed ? "Verified before playback"
                    : "Server returned \(http.statusCode)")
        } catch {
            return nil
        }
    }

    private func elapsedMs(since: Date) -> Int64 {
        Int64(Date().timeIntervalSince(since) * 1000)
    }
}
