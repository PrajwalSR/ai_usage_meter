import Foundation

/// The ChatGPT (Codex) reading, from chatgpt.com.
///
/// It is the account-wide number, asked from inside the app's signed-in page, so
/// it includes usage from a phone or another machine. Codex's own log files in
/// `~/.codex` are never read.
enum CodexReadings {
    /// Shown when there is no Codex reading at all.
    static let noReadingNote = "No Codex limit yet. Sign in to ChatGPT under ⚙ → Accounts."

    /// Written by `WebUsageSource` from the signed-in chatgpt.com page.
    static var webFileURL: URL {
        ClaudeReadings.directory.appendingPathComponent("codex-web.json")
    }

    static func load(webURL: URL = webFileURL) -> [AllowanceReading] {
        [ClaudeReadings.read(webURL, source: .chatgptWeb)].compactMap { $0 }
    }
}
