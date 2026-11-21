import Foundation

/// Turns the reading files into a `UsageReport`.
///
/// Each pass has two steps:
/// 1. **Store** (one transaction): load the reading files the website checks and
///    the Claude Code status line write, and replace each source's stored rows.
///    If any write fails the transaction is rolled back, and the next pass retries.
/// 2. **Build**: read the stored readings back and assemble the report.
///
/// No log file is read: not Claude Code's, not Codex's.
///
/// Owned by one background task; not thread-safe.
final class UsageIndex {
    private let db: Database

    init(url: URL = Database.defaultURL) throws {
        db = try Database(url: url)
    }

    func refresh(now: Date = Date()) -> UsageReport {
        let t0 = Date()
        var errors: [String] = []

        do {
            try db.begin()
            try store(ClaudeReadings.load(), for: .claude,
                      fileSources: [.claudeStatusLine, .claudeWeb])
            try store(CodexReadings.load(), for: .codex, fileSources: [.chatgptWeb])
            try db.pruneReadings(before: now.addingTimeInterval(-30 * 86400))
            try db.commit()
        } catch {
            db.rollback()
            errors.append("Couldn't update the local cache (\(error)). Nothing was saved; "
                          + "it will retry on the next update.")
        }

        let codex = build(.codex, now: now, errors: &errors)
        let claude = build(.claude, now: now, errors: &errors)
        return UsageReport(claude: claude, codex: codex, scannedAt: now,
                           scanDuration: Date().timeIntervalSince(t0), errors: errors)
    }

    /// Saves the readings from the files. Each source reports its complete set of
    /// limits every time, so its previous rows are replaced — otherwise a limit
    /// that vanished, or one stored under an older name, would hang around as a
    /// duplicate. A source whose file is gone (signed out) loses its rows too, or
    /// its last numbers would stay on screen.
    private func store(_ readings: [AllowanceReading], for provider: Provider,
                       fileSources: Set<ReadingSource>) throws {
        for source in fileSources.union(readings.map(\.source)) {
            try db.deleteReadings(provider: provider.rawValue, source: source)
        }
        for reading in readings {
            try db.addReading(provider: provider.rawValue, reading)
        }
    }

    // MARK: - Build

    private func build(_ provider: Provider, now: Date,
                       errors: inout [String]) -> ProviderReading {
        do {
            return ProviderReading(
                provider: provider,
                // Every newest-per-source-and-limit reading. Which to show is
                // decided at display time, when expiry is known.
                readings: try db.latestReadings(provider: provider.rawValue),
                unavailableNote: provider == .claude ? ClaudeReadings.noReadingNote
                                                     : CodexReadings.noReadingNote)
        } catch {
            errors.append("Couldn't read \(provider.displayName) data from the cache (\(error)).")
            return ProviderReading(provider: provider, readings: [],
                                   unavailableNote: "The local cache couldn't be read.")
        }
    }
}
