import Foundation

/// 1:1 port of `sanitizedStreamHeaders` + `normalizedBearerToken` in
/// `presentation/player/StreamRequestHeaders.kt`.
public enum StreamRequestHeaders {
    private static let allowed: Set<String> = [
        "accept", "accept-language", "authorization", "cookie", "origin", "referer", "user-agent",
    ]

    public static func sanitized(_ headers: [String: String]?) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in headers ?? [:] {
            guard allowed.contains(name.lowercased()),
                  name.count <= 64, value.count <= 4096,
                  !containsNewline(name), !containsNewline(value) else { continue }
            out[name] = value
        }
        return out
    }

    /// Scalar-level check: Swift grapheme `contains("\n")` misses a CR+LF
    /// pair (one cluster), so inspect scalars like the Kotlin Char check.
    private static func containsNewline(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 10 || $0.value == 13 }
    }

    public static func normalizedBearerToken(_ token: String) -> String {
        token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
    }
}
