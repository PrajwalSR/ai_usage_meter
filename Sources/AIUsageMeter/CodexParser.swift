import Foundation

/// Reads Codex CLI session logs (`~/.codex/sessions/**/*.jsonl`).
///
/// Only one kind of line matters: `event_msg` / `token_count` carrying a
/// `rate_limits` block, which is the allowance as OpenAI reported it when the
/// line was written.
///
/// Only limit numbers, ids and timestamps are kept; the app does not count
/// tokens. `~/.codex/auth.json` holds
/// credentials and is never opened. See docs/DATA-SOURCES.md for the formats.
enum CodexParser: LogParser {
    static let provider = Provider.codex
    static let noReadingNote =
        "No Codex limit found in recent logs. It appears after Codex runs."

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    // Byte marker checked before JSON decoding, so most lines are never decoded.
    private static let rateMarker = Array("rate_limits".utf8)

    static func parse(url: URL, from offset: UInt64,
                      onReading: (AllowanceReading) throws -> Void) throws -> UInt64 {
        try LineReader.forEachLine(url: url, from: offset) { buf in
            guard LineReader.contains(buf, rateMarker) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(buf)) as? [String: Any],
                  let ts = JSONPath.date(obj["timestamp"]),
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any],
                  let reading = reading(from: rl, recordedAt: ts) else { return }
            try onReading(reading)
        }
    }

    /// Converts a `rate_limits` block into a reading with every window in it.
    ///
    /// Window length always comes from `window_minutes`, never from the key:
    /// `primary` has been seen as a 7-day window with `secondary` null. Every
    /// window is kept, tagged with the block's `limit_id`, so an account with
    /// several limits is shown correctly.
    static func reading(from rl: [String: Any], recordedAt: Date) -> AllowanceReading? {
        let limitId = rl["limit_id"] as? String
        var windows: [AllowanceWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any],
                  let used = JSONPath.double(w, "used_percent") else { continue }
            windows.append(AllowanceWindow(
                usedPercent: used,
                windowMinutes: JSONPath.double(w, "window_minutes").map { Int($0) },
                resetsAt: JSONPath.double(w, "resets_at").map(Date.init(timeIntervalSince1970:)),
                limitId: limitId))
        }
        guard !windows.isEmpty else { return nil }
        return AllowanceReading(recordedAt: recordedAt, source: .codexLog,
                                planType: rl["plan_type"] as? String, windows: windows)
    }
}
