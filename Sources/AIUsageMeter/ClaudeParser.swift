import Foundation

/// Reads Claude Code session logs (`~/.claude/projects/**/*.jsonl`) for token
/// counts.
///
/// These logs contain no allowance. Claude's percentage comes from two other
/// places, see `ClaudeReadings`:
/// - `ClaudeLiveUsage` asks Anthropic (optional, needs the Claude Code login).
/// - `scripts/claude-statusline.py` receives it from Claude Code's status line.
///
/// A log line holding usage is JSON-decoded in memory, which briefly includes
/// that message's content. Only numbers and the timestamp are kept.
enum ClaudeParser: LogParser {
    static let provider = Provider.claude
    static let noReadingNote =
        "Claude's logs hold token counts only, not your limit. Turn on "
        + "\"Check Claude usage live\" below, or set up the Claude Code status line "
        + "(see README → Claude without live checks)."

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    private static let usageMarker = Array("\"usage\"".utf8)

    static func parse(url: URL, from offset: UInt64,
                      onUsage: (Date, TokenTotals) throws -> Void,
                      onReading: (AllowanceReading) throws -> Void) throws -> UInt64 {
        try LineReader.forEachLine(url: url, from: offset) { buf in
            guard LineReader.contains(buf, usageMarker) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(buf)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = JSONPath.date(obj["timestamp"]) else { return }

            try onUsage(ts, TokenTotals(
                input: JSONPath.int(usage, "input_tokens"),
                output: JSONPath.int(usage, "output_tokens"),
                cacheRead: JSONPath.int(usage, "cache_read_input_tokens"),
                cacheWrite: JSONPath.int(usage, "cache_creation_input_tokens"),
                messages: 1))
        }
    }
}
