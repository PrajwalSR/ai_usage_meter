import Foundation

/// Claude's allowance readings, which come from outside the session logs.
///
/// Two sources, each in its own file so neither can overwrite the other:
///
/// | File                            | Written by                     | Source              |
/// |---------------------------------|--------------------------------|---------------------|
/// | `statusline/claude.json`        | `scripts/claude-statusline.py` | `.claudeStatusLine` |
///
/// Which one is shown is decided by `choose(_:now:)`.
enum ClaudeReadings {
    /// Directory the app watches for new Claude readings. It is a subdirectory on
    /// purpose: watching its parent would also see the app's own SQLite writes
    /// and trigger rescans in a loop.
    static var directory: URL {
        Database.defaultURL.deletingLastPathComponent().appendingPathComponent("statusline")
    }
    static var statusLineFileURL: URL { directory.appendingPathComponent("claude.json") }
    /// Written by `WebUsageSource` from the signed-in claude.ai web view.
    static var webFileURL: URL { directory.appendingPathComponent("claude-web.json") }

    /// Shown when there is no Claude reading at all.
    static let noReadingNote =
        "Claude doesn't write your limit to any file on this Mac. Sign in to Claude "
        + "under ⚙ → Accounts, or set up the Claude Code status line."

    /// All readings currently on disk.
    static func load(statusLineURL: URL = statusLineFileURL,
                     webURL: URL = webFileURL) -> [AllowanceReading] {
        [read(statusLineURL, source: .claudeStatusLine),
         read(webURL, source: .claudeWeb)].compactMap { $0 }
    }

    /// The single Claude reading to show. Thin wrapper over the shared rule in
    /// `ReadingSelection`, kept because Claude only ever has one limit.
    static func choose(_ readings: [AllowanceReading], now: Date) -> AllowanceReading? {
        ReadingSelection.choose(provider: .claude, readings: readings, now: now)
            .max { $0.recordedAt < $1.recordedAt }
    }

    /// Parses one reading file:
    ///
    ///     { "received_at": 1789580000.0, "plan_type": "plus",   // plan optional
    ///       "rate_limits": { "five_hour": { "used_percentage": 38, "resets_at": 1789590000 },
    ///                        "seven_day": { … } } }
    ///
    /// `recorded_at` is accepted for files written by older builds.
    static func read(_ url: URL, source: ReadingSource) -> AllowanceReading? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = obj["rate_limits"] as? [String: Any],
              let stamp = JSONPath.double(obj, "received_at") ?? JSONPath.double(obj, "recorded_at")
        else { return nil }

        // Known window names have known lengths; anything else keeps its own
        // name as the limit id and uses `window_minutes` when the writer sent one.
        let knownMinutes = ["five_hour": 300, "seven_day": 10080]
        var windows: [AllowanceWindow] = []
        for (key, value) in rl {
            guard let w = value as? [String: Any],
                  let used = JSONPath.double(w, "used_percentage") else { continue }
            windows.append(AllowanceWindow(
                usedPercent: used,
                windowMinutes: JSONPath.double(w, "window_minutes").map { Int($0) } ?? knownMinutes[key],
                resetsAt: JSONPath.double(w, "resets_at").map(Date.init(timeIntervalSince1970:)),
                limitId: knownMinutes[key] == nil ? key : nil))
        }
        windows.sort { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
        guard !windows.isEmpty else { return nil }

        return AllowanceReading(recordedAt: Date(timeIntervalSince1970: stamp),
                                source: source, planType: obj["plan_type"] as? String,
                                windows: windows)
    }
}
