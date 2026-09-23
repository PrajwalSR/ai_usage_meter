import Foundation

/// The ChatGPT (Codex) reading that doesn't come from a log file.
///
/// Codex's logs only change when Codex runs on this Mac, so they can't show usage
/// from a phone or another machine. chatgpt.com can: it is the same account-wide
/// number, asked from inside the app's signed-in page.
enum CodexReadings {
    /// Written by `WebUsageSource` from the signed-in chatgpt.com page.
    static var webFileURL: URL {
        ClaudeReadings.directory.appendingPathComponent("codex-web.json")
    }

    static func load(webURL: URL = webFileURL) -> [AllowanceReading] {
        [ClaudeReadings.read(webURL, source: .chatgptWeb)].compactMap { $0 }
    }
}
