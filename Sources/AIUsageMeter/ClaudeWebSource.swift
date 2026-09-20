import Foundation

/// Turns claude.ai's own usage reply into a reading file.
///
/// The reply's shape isn't documented, so the parser is deliberately loose: it
/// looks for any block holding a percentage, works out which window it is from
/// its key, and keeps anything it doesn't recognise as its own limit rather than
/// dropping it. The raw reply is also saved once, so the shape can be checked.
enum ClaudeWebSource {
    /// How often the app may ask claude.ai. The website polls itself about this
    /// often, and this backend isn't the rate-limited one.
    static let pollInterval: TimeInterval = 60

    static var rawDumpURL: URL {
        ClaudeReadings.directory.appendingPathComponent("claude-web-raw.json")
    }

    /// Parses the JSON from `ClaudeWebSession.fetchRawUsage` and writes the
    /// reading file. Returns a description of the problem on failure.
    @discardableResult
    static func store(rawJSON: String, now: Date = Date()) -> String? {
        guard let data = rawJSON.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = top["usage"] else { return "no usage in reply" }

        // Keep the raw reply for inspection; usage numbers only, no cookie.
        try? FileManager.default.createDirectory(at: ClaudeReadings.directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? rawJSON.data(using: .utf8)?.write(to: rawDumpURL, options: .atomic)

        let windows = parseWindows(usage)
        guard !windows.isEmpty else { return "no percentages found in claude.ai reply" }

        var rateLimits: [String: Any] = [:]
        for (key, w) in windows {
            var entry: [String: Any] = ["used_percentage": w.usedPercent]
            if let r = w.resetsAt { entry["resets_at"] = r.timeIntervalSince1970 }
            if let m = w.windowMinutes { entry["window_minutes"] = m }
            rateLimits[key] = entry
        }
        let payload: [String: Any] = ["received_at": now.timeIntervalSince1970,
                                      "rate_limits": rateLimits]
        guard let out = try? JSONSerialization.data(withJSONObject: payload),
              (try? out.write(to: ClaudeReadings.webFileURL, options: .atomic)) != nil else {
            return "could not save the claude.ai reading"
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: ClaudeReadings.webFileURL.path)
        return nil
    }

    /// Finds every block that carries a percentage, keyed by a name the reading
    /// file understands (`five_hour`, `seven_day`) or the original key.
    static func parseWindows(_ any: Any) -> [(String, AllowanceWindow)] {
        var found: [(String, AllowanceWindow)] = []
        walk(any, key: nil, into: &found)
        return found
    }

    private static func walk(_ any: Any, key: String?, into found: inout [(String, AllowanceWindow)]) {
        guard let dict = any as? [String: Any] else { return }

        if let key, let percent = percentage(in: dict) {
            let name = normalize(key)
            let minutes = windowMinutes(for: key, dict: dict)
            let resets = resetDate(in: dict)
            // claude.ai's reply carries internal entries (code names like
            // "nimbus_quill") that are 0% with no window and no reset. They are
            // not usage limits, so only keep a window we can name, or one that
            // says when it resets.
            let isRealWindow = minutes != nil || resets != nil
            if isRealWindow {
                found.append((name, AllowanceWindow(
                    usedPercent: percent,
                    windowMinutes: minutes,
                    resetsAt: resets,
                    limitId: knownNames.contains(name) ? nil : name)))
            }
            return                                   // don't descend into a window
        }
        for (k, v) in dict { walk(v, key: k, into: &found) }
    }

    private static let knownNames: Set<String> = ["five_hour", "seven_day"]

    private static func percentage(in dict: [String: Any]) -> Double? {
        for name in ["utilization", "used_percentage", "used_percent", "percent_used", "percentage"] {
            if let v = JSONPath.double(dict, name) { return v }
        }
        return nil
    }

    private static func resetDate(in dict: [String: Any]) -> Date? {
        for name in ["resets_at", "reset_at", "resets", "next_reset"] {
            if let n = JSONPath.double(dict, name) { return Date(timeIntervalSince1970: n) }
            if let d = JSONPath.date(dict[name]) { return d }
        }
        return nil
    }

    /// claude.ai names windows differently from the status line, so map the
    /// familiar ones and leave the rest under their own name.
    private static func normalize(_ key: String) -> String {
        let k = key.lowercased()
        if k.contains("five") || k.contains("5h") || k.contains("session") { return "five_hour" }
        if k.contains("seven") || k.contains("7d") || k.contains("week") { return "seven_day" }
        return key
    }

    private static func windowMinutes(for key: String, dict: [String: Any]) -> Int? {
        if let m = JSONPath.double(dict, "window_minutes") { return Int(m) }
        switch normalize(key) {
        case "five_hour": return 300
        case "seven_day": return 10080
        default: return nil
        }
    }
}
