// 1:1 port of sanitizedStreamHeaders + normalizedBearerToken in
// presentation/player/StreamRequestHeaders.kt.
namespace Rally.Core;

public static class StreamRequestHeaders
{
    private static readonly HashSet<string> Allowed = new(StringComparer.OrdinalIgnoreCase)
        { "accept", "accept-language", "authorization", "cookie", "origin", "referer", "user-agent" };

    public static Dictionary<string, string> Sanitize(Dictionary<string, string>? headers)
    {
        var out_ = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (headers is null) return out_;
        foreach (var (name, value) in headers)
        {
            if (!Allowed.Contains(name)) continue;
            if (name.Length > 64 || value.Length > 4096) continue;
            // Ordinal (code-unit) check: catches lone CR, lone LF, and CR+LF pairs.
            // (Swift needs a scalar check here; C# ordinal Contains is sufficient.)
            if (name.Contains('\n') || name.Contains('\r')) continue;
            if (value.Contains('\n') || value.Contains('\r')) continue;
            out_[name] = value;
        }
        return out_;
    }

    public static string NormalizedBearerToken(string token) =>
        token.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? token : "Bearer " + token;
}
