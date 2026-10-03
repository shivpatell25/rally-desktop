import CryptoKit
import Foundation

/// Extended M3U channel catalogs, with HLS manifests kept intact.
public enum M3uClient {
    public enum PlaylistError: LocalizedError {
        case invalidSource, invalidPlaylist, tooLarge, empty, http(Int)
        public var errorDescription: String? {
            switch self {
            case .invalidSource: return "Enter a playlist URL or choose a local M3U file."
            case .invalidPlaylist: return "This response is not an M3U playlist."
            case .tooLarge: return "The playlist exceeds 16 MB or 20,000 channels."
            case .empty: return "No playable HTTP or HTTPS channels were found."
            case .http(let status): return "The playlist server returned HTTP \(status)."
            }
        }
    }
    public static func isSupportedSource(_ source: String) -> Bool {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.isFileURL || (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil)
    }
    public static func load(source: String, name: String, session: URLSession = .shared) async throws -> [IptvChannel] {
        guard isSupportedSource(source), let url = URL(string: source) else { throw PlaylistError.invalidSource }
        let data: Data
        let base: URL
        if url.isFileURL {
            data = try Data(contentsOf: url, options: .mappedIfSafe); base = url
        } else {
            let (bytes, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw PlaylistError.http(response.statusCode)
            }
            data = bytes; base = response.url ?? url
        }
        guard data.count <= 16 * 1024 * 1024 else { throw PlaylistError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw PlaylistError.invalidPlaylist }
        return try parse(text, source: base.absoluteString, name: name)
    }
    public static func parse(_ text: String, source: String, name: String = "") throws -> [IptvChannel] {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        func resolve(_ value: String) -> String? {
            guard !value.isEmpty, let url = URL(string: value, relativeTo: URL(string: source))?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url.absoluteString
        }
        let bare = lines.filter { !$0.hasPrefix("#") }
        guard lines.contains(where: { $0.uppercased().hasPrefix("#EXTM3U") || $0.uppercased().hasPrefix("#EXTINF:") })
                || (!bare.isEmpty && bare.allSatisfy { value in
                    guard let url = URL(string: value.components(separatedBy: "|")[0]), url.host != nil else { return false }
                    return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                }) else {
            throw PlaylistError.invalidPlaylist
        }
        func channel(_ url: String, title: String, group: String, logo: String?, number: String, headers: [String: String]) -> IptvChannel {
            let identity = url + headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            let id = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return IptvChannel(id: "m3u:\(id)", number: number, name: title, category: group,
                               logoUrl: logo, streamUrl: url, streamHeaders: headers)
        }
        if lines.contains(where: { $0.uppercased().hasPrefix("#EXT-X-") }) {
            guard let url = resolve(source) else { throw PlaylistError.invalidSource }
            return [channel(url, title: name.isEmpty ? "Live Stream" : name, group: "Live TV", logo: nil, number: "1", headers: [:])]
        }
        let regex = try NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s]+))"#)
        var result: [IptvChannel] = [], seen = Set<String>()
        var attrs: [String: String] = [:], title = "", group = "", headers: [String: String] = [:]
        func put(_ key: String, _ value: String) {
            guard !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value < 32 }) else { return }
            headers[key] = value
        }
        for line in lines {
            if line.uppercased().hasPrefix("#EXTINF:") {
                attrs = [:]; headers = [:]
                var quote: Character?, separator: String.Index?
                for index in line.indices {
                    let char = line[index]
                    if char == quote { quote = nil }
                    else if quote == nil && (char == "\"" || char == "'") { quote = char }
                    else if quote == nil && char == "," { separator = index; break }
                }
                let prefix = separator.map { String(line[..<$0]) } ?? line
                title = separator.map { String(line[line.index(after: $0)...]) } ?? ""
                for match in regex.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) {
                    guard let key = Range(match.range(at: 1), in: prefix) else { continue }
                    let value = (2...4).compactMap { Range(match.range(at: $0), in: prefix).map { String(prefix[$0]) } }.first ?? ""
                    attrs[String(prefix[key]).lowercased()] = value
                }
                group = attrs["group-title"] ?? ""
                if let ua = attrs["user-agent"] { put("User-Agent", ua) }
                if let ref = attrs["referrer"] { put("Referer", ref) }
            } else if line.uppercased().hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8))
            } else if line.uppercased().hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst(11).components(separatedBy: "=")
                if option.count >= 2 {
                    let keys = ["http-user-agent": "User-Agent", "http-referrer": "Referer", "http-referer": "Referer", "http-origin": "Origin"]
                    if let key = keys[option[0].lowercased()] { put(key, option.dropFirst().joined(separator: "=")) }
                }
            } else if !line.hasPrefix("#") {
                let parts = line.components(separatedBy: "|")
                if let url = resolve(parts[0]) {
                    if parts.count > 1 {
                        for pair in parts[1].components(separatedBy: "&") {
                            let item = pair.components(separatedBy: "=")
                            let keys = ["user-agent": "User-Agent", "referer": "Referer", "referrer": "Referer", "origin": "Origin"]
                            if let key = keys[item[0].lowercased()], item.count > 1 {
                                put(key, item.dropFirst().joined(separator: "=").removingPercentEncoding ?? "")
                            }
                        }
                    }
                    let entry = channel(url, title: title.isEmpty ? (attrs["tvg-name"] ?? "Channel \(result.count + 1)") : title,
                                        group: group.isEmpty ? "Live TV" : group, logo: resolve(attrs["tvg-logo"] ?? ""),
                                        number: attrs["tvg-chno"] ?? "\(result.count + 1)", headers: headers)
                    if seen.insert(entry.id).inserted { result.append(entry) }
                    guard result.count <= 20_000 else { throw PlaylistError.tooLarge }
                }
                attrs = [:]; title = ""; group = ""; headers = [:]
            }
        }
        guard !result.isEmpty else { throw PlaylistError.empty }
        return result
    }
}
