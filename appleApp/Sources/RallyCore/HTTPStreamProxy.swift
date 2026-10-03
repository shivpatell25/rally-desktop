import Foundation
import Network

/// A session-scoped loopback relay for transports that libVLC cannot authenticate.
/// Media stays streamed with backpressure; playlists keep relative paths intact.
public final class HTTPStreamProxy: @unchecked Sendable {
    private let root: URL
    private let headers: [String: String]
    private let session: URLSession
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let queue = DispatchQueue(label: "Rally.StreamRelay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var started = false
    private var origins: Set<String> = []
    private var connections: [UUID: NWConnection] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    public init(url: URL, headers: [String: String], session: URLSession = .shared) {
        root = url; self.headers = StreamRequestHeaders.sanitized(headers); self.session = session
    }
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    self.port = listener.port?.rawValue ?? 0
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error): self.started = true; continuation.resume(throwing: error)
                case .cancelled: self.started = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return try localURL(for: root)
    }
    public func stop() {
        listener?.cancel(); listener = nil
        let active = lock.withLock { () -> ([NWConnection], [Task<Void, Never>]) in
            let value = (Array(connections.values), Array(requests.values))
            connections = [:]; requests = [:]; return value
        }
        active.1.forEach { $0.cancel() }; active.0.forEach { $0.cancel() }
    }
    deinit { stop() }
    private func localURL(for url: URL) throws -> URL {
        guard let remote = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(remote.scheme ?? ""), let host = remote.host else { throw URLError(.badURL) }
        var origin = URLComponents(); origin.scheme = remote.scheme; origin.host = host; origin.port = remote.port
        // Credentials already embedded in provider URLs remain part of the upstream origin.
        origin.user = remote.user; origin.password = remote.password
        guard let originText = origin.string else { throw URLError(.badURL) }
        lock.withLock { _ = origins.insert(originText) }
        let encoded = Data(originText.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var local = URLComponents(); local.scheme = "http"; local.host = "127.0.0.1"; local.port = Int(port)
        local.percentEncodedPath = "/\(token)/\(encoded)" + (remote.percentEncodedPath.isEmpty ? "/" : remote.percentEncodedPath)
        local.percentEncodedQuery = remote.percentEncodedQuery
        guard let result = local.url else { throw URLError(.badURL) }
        return result
    }
    private func remoteURL(_ path: String) -> URL? {
        guard let local = URLComponents(string: path) else { return nil }
        let parts = local.percentEncodedPath.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == Substring(token) else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let origin = String(data: data, encoding: .utf8),
              lock.withLock({ origins.contains(origin) }), var remote = URLComponents(string: origin) else { return nil }
        remote.percentEncodedPath = "/" + (parts.count == 3 ? String(parts[2]) : "")
        remote.percentEncodedQuery = local.percentEncodedQuery
        return remote.url
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.withLock { connections[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.finish(id) }
            else if case .failed = state { self?.finish(id) }
        }
        connection.start(queue: queue)
        receiveHeader(connection, id: id, bytes: Data())
    }
    private func finish(_ id: UUID) {
        let task = lock.withLock { () -> Task<Void, Never>? in
            connections.removeValue(forKey: id); return requests.removeValue(forKey: id)
        }
        task?.cancel()
    }
    private func receiveHeader(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = bytes; if let data { buffer.append(data) }
            guard buffer.count <= 16384, error == nil else { connection.cancel(); return }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                let task = Task { await self.serve(text, connection: connection); connection.cancel() }
                self.lock.withLock { self.requests[id] = task }
            } else if complete { connection.cancel() }
            else { self.receiveHeader(connection, id: id, bytes: buffer) }
        }
    }
    private func send(_ data: Data, connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func serve(_ header: String, connection: NWConnection) async {
        var sentResponse = false
        do {
            let lines = header.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])), let url = remoteURL(String(first[1])) else {
                try await send(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), connection: connection); return
            }
            var request = URLRequest(url: url, timeoutInterval: 20); request.httpMethod = String(first[0])
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if !["m3u8", "mpd"].contains(url.pathExtension.lowercased()), let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
                request.setValue(String(range.dropFirst(6)).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
            }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let mime = response.mimeType ?? "application/octet-stream"
            let isManifest = request.httpMethod != "HEAD" && (request.value(forHTTPHeaderField: "Range") == nil || request.value(forHTTPHeaderField: "Range") == "bytes=0-") && (200..<300).contains(response.statusCode) &&
                (["m3u8", "mpd"].contains(url.pathExtension.lowercased()) || mime.lowercased().contains("mpegurl") || mime.lowercased().contains("dash+xml"))
            var result = "HTTP/1.1 \(isManifest ? 200 : response.statusCode) Response\r\nContent-Type: \(mime)\r\nConnection: close\r\n"
            if !isManifest, let range = response.value(forHTTPHeaderField: "Content-Range") { result += "Content-Range: \(range)\r\nAccept-Ranges: bytes\r\n" }
            if request.httpMethod == "HEAD" {
                if response.expectedContentLength >= 0 { result += "Content-Length: \(response.expectedContentLength)\r\n" }
                try await send(Data((result + "\r\n").utf8), connection: connection); return
            }
            if isManifest {
                var data = Data()
                for try await byte in bytes { data.append(byte); if data.count > 2_000_000 { throw URLError(.dataLengthExceedsMaximum) } }
                if let text = String(data: data, encoding: .utf8) { data = Data(try rewrite(text, base: response.url ?? url).utf8) }
                result += "Content-Length: \(data.count)\r\n\r\n"
                try await send(Data(result.utf8), connection: connection); try await send(data, connection: connection)
            } else {
                try await send(Data((result + "Transfer-Encoding: chunked\r\n\r\n").utf8), connection: connection)
                sentResponse = true
                var chunk = Data(); chunk.reserveCapacity(65536)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 65536 { try await sendChunk(chunk, connection: connection); chunk.removeAll(keepingCapacity: true) }
                }
                if !chunk.isEmpty { try await sendChunk(chunk, connection: connection) }
                try await send(Data("0\r\n\r\n".utf8), connection: connection)
            }
        } catch {
            if !sentResponse { try? await send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), connection: connection) }
        }
    }
    private func sendChunk(_ chunk: Data, connection: NWConnection) async throws {
        var packet = Data((String(chunk.count, radix: 16) + "\r\n").utf8); packet.append(chunk); packet.append(Data("\r\n".utf8))
        try await send(packet, connection: connection)
    }
    func rewrite(_ text: String, base: URL) throws -> String {
        // Only media URI fields are rewritten; XML namespaces and metadata are preserved.
        let isHLS = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
        let pattern = isHLS ? #"(?m)^[^#\r\n][^\r\n]*|(?<=URI=")[^"]+"# : #"<BaseURL(?:\s[^>]*)?>([^<]+)|(?:media|initialization|sourceURL|href)=["']([^"']+)["']"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let target = isHLS ? match.range : (match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2))
            let value = ns.substring(with: target).trimmingCharacters(in: .whitespacesAndNewlines)
            // Relative DASH references inherit potentially nested BaseURLs. Preserve
            // that hierarchy, rewriting only references that leave the local relay.
            if !isHLS && !value.hasPrefix("http://") && !value.hasPrefix("https://") && !value.hasPrefix("/") { continue }
            guard let url = URL(string: value.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? ""), let range = Range(target, in: result) else { continue }
            let local = try localURL(for: url).absoluteString.replacingOccurrences(of: "&", with: isHLS ? "&" : "&amp;")
            result.replaceSubrange(range, with: local)
        }
        return result
    }
}
