import Foundation

/// Reads Codex CLI session logs (`~/.codex/sessions/**/*.jsonl`).
///
/// Two kinds of line matter:
/// - `token_usage_record`: token counts for a turn.
/// - `event_msg` / `token_count` with a `rate_limits` block: the allowance as
///   OpenAI reported it when the line was written.
///
/// Only numbers, ids and timestamps are kept. `~/.codex/auth.json` holds
/// credentials and is never opened. See docs/DATA-SOURCES.md for the formats.
enum CodexParser: LogParser {
    static let provider = Provider.codex
    static let noReadingNote =
        "No Codex limit found in recent logs. It appears after Codex runs."

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    // Byte markers checked before JSON decoding, so most lines are never decoded.
    private static let rateMarker = Array("rate_limits".utf8)
    private static let usageMarker = Array("token_usage_record".utf8)

    static func parse(url: URL, from offset: UInt64,
                      onUsage: (Date, TokenTotals) throws -> Void,
                      onReading: (AllowanceReading) throws -> Void) throws -> UInt64 {
        try LineReader.forEachLine(url: url, from: offset) { buf in
            let hasRate = LineReader.contains(buf, rateMarker)
            let hasUsage = LineReader.contains(buf, usageMarker)
            guard hasRate || hasUsage else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(buf)) as? [String: Any],
                  let ts = JSONPath.date(obj["timestamp"]) else { return }
            let payload = obj["payload"] as? [String: Any]

            if hasUsage, obj["type"] as? String == "token_usage_record",
               let usage = payload?["usage"] as? [String: Any] {
                // `input_tokens` includes the cached part; split it out so cached
                // tokens aren't counted twice.
                let cached = JSONPath.int(usage, "cached_input_tokens")
                try onUsage(ts, TokenTotals(
                    input: max(0, JSONPath.int(usage, "input_tokens") - cached),
                    output: JSONPath.int(usage, "output_tokens"),
                    cacheRead: cached,
                    cacheWrite: JSONPath.int(usage, "cache_write_input_tokens"),
                    messages: 1))
            }

            if hasRate, let rl = payload?["rate_limits"] as? [String: Any],
               let reading = reading(from: rl, recordedAt: ts) {
                try onReading(reading)
            }
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
