import Foundation

/// Claude's allowance readings, which come from outside the session logs.
///
/// Two sources, each in its own file so neither can overwrite the other:
///
/// | File                            | Written by                     | Source              |
/// |---------------------------------|--------------------------------|---------------------|
/// | `statusline/claude-live.json`   | `ClaudeLiveUsage` (this app)   | `.anthropicLive`    |
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
    static var liveFileURL: URL { directory.appendingPathComponent("claude-live.json") }
    static var statusLineFileURL: URL { directory.appendingPathComponent("claude.json") }
    /// Written by `ClaudeWebSource` from the signed-in claude.ai web view.
    static var webFileURL: URL { directory.appendingPathComponent("claude-web.json") }

    /// A live check this recent always wins, even if the status line wrote more
    /// recently. The status line only says when *it received* a figure, and
    /// Claude Code may be repeating one from its last API response, so a fresh
    /// check with Anthropic is the better source.
    static let liveFreshness: TimeInterval = 15 * 60

    /// All readings currently on disk.
    static func load(liveURL: URL = liveFileURL,
                     statusLineURL: URL = statusLineFileURL,
                     webURL: URL = webFileURL) -> [AllowanceReading] {
        [read(liveURL, defaultSource: .anthropicLive),
         read(statusLineURL, defaultSource: .claudeStatusLine),
         read(webURL, defaultSource: .claudeWeb)].compactMap { $0 }
    }

    /// Precedence:
    /// 1. The newest live reading under `liveFreshness` old **that still has a
    ///    valid window**.
    /// 2. Otherwise the newest reading of either source that still has a valid
    ///    window.
    /// 3. Otherwise the newest reading at all, which the UI shows as "unknown".
    ///
    /// Validity is checked first so an expired reading can't hide a usable one.
    static func choose(_ readings: [AllowanceReading], now: Date) -> AllowanceReading? {
        let usable = readings.filter { !$0.liveWindows(now: now).isEmpty }
        // claude.ai can be asked often, so a recent reading from there is the
        // best answer available.
        if let web = usable.filter({ $0.source == .claudeWeb })
            .max(by: { $0.recordedAt < $1.recordedAt }),
           now.timeIntervalSince(web.recordedAt) <= liveFreshness {
            return web
        }
        let newestLive = usable.filter { $0.source == .anthropicLive }
            .max { $0.recordedAt < $1.recordedAt }
        if let newestLive, now.timeIntervalSince(newestLive.recordedAt) <= liveFreshness {
            return newestLive
        }
        return usable.max { $0.recordedAt < $1.recordedAt }
            ?? readings.max { $0.recordedAt < $1.recordedAt }
    }

    /// Parses one reading file:
    ///
    ///     { "received_at": 1789580000.0,
    ///       "rate_limits": { "five_hour": { "used_percentage": 38, "resets_at": 1789590000 },
    ///                        "seven_day": { … } } }
    ///
    /// `recorded_at` is accepted for files written by older builds, and so is
    /// their `"source": "anthropic-usage-endpoint"` marker.
    static func read(_ url: URL, defaultSource: ReadingSource) -> AllowanceReading? {
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

        let source: ReadingSource = (obj["source"] as? String) == "anthropic-usage-endpoint"
            ? .anthropicLive : defaultSource
        return AllowanceReading(recordedAt: Date(timeIntervalSince1970: stamp),
                                source: source, planType: nil, windows: windows)
    }
}
