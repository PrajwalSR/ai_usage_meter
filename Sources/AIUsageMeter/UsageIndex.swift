import Foundation

/// Turns Codex's log files and the Claude reading files into a `UsageReport`.
///
/// Each pass has two steps:
/// 1. **Ingest** (one transaction): read only bytes appended to Codex's logs
///    since last time, store any limit readings, save the new file offsets. Load
///    the Claude reading files. If any write fails the transaction is rolled
///    back, and the next pass retries.
/// 2. **Build**: read the stored readings back and assemble the report.
///
/// The app does not count tokens, so Claude Code's logs are never read.
///
/// Owned by one background task; not thread-safe.
final class UsageIndex {
    private let db: Database
    /// How old a log file may be and still be worth reading.
    static let retention: TimeInterval = 7 * 86400

    init(url: URL = Database.defaultURL) throws {
        db = try Database(url: url)
    }

    func refresh(now: Date = Date()) -> UsageReport {
        let t0 = Date()
        var errors: [String] = []
        var seen = 0, read = 0

        do {
            try db.begin()
            (seen, read) = try ingest(CodexParser.self, now: now, errors: &errors)
            try store(ClaudeReadings.load(), for: .claude)
            try store(CodexReadings.load(), for: .codex)
            try db.pruneReadings(before: now.addingTimeInterval(-30 * 86400))
            try db.commit()
        } catch {
            db.rollback()
            errors.append("Couldn't update the local cache (\(error)). Nothing was saved; "
                          + "it will retry on the next update.")
            read = 0
        }

        let codex = build(.codex, now: now, seen: seen, read: read, errors: &errors)
        let claude = build(.claude, now: now, seen: 0, read: 0, errors: &errors)
        return UsageReport(claude: claude, codex: codex, scannedAt: now,
                           scanDuration: Date().timeIntervalSince(t0), errors: errors)
    }

    /// Saves readings that came from a file rather than a log. Each such source
    /// reports its complete set of limits every time, so its previous rows are
    /// replaced — otherwise a limit that vanished, or one stored under an older
    /// name, would hang around as a duplicate.
    private func store(_ readings: [AllowanceReading], for provider: Provider) throws {
        for source in Set(readings.map(\.source)) {
            try db.deleteReadings(provider: provider.rawValue, source: source)
        }
        for reading in readings {
            try db.addReading(provider: provider.rawValue, reading)
        }
    }

    // MARK: - Ingest

    /// Returns (files seen, files with new bytes). Throws only database errors.
    private func ingest(_ parser: LogParser.Type, now: Date,
                        errors: inout [String]) throws -> (Int, Int) {
        let key = parser.provider.rawValue
        var known = try db.fileStates(provider: key)
        let files = recentJSONLFiles(root: parser.root,
                                     modifiedAfter: now.addingTimeInterval(-Self.retention))

        // A replaced or shortened log means the stored offsets are meaningless.
        // Readings already saved stay: each is a point-in-time record, keyed by
        // when it was taken, so re-reading a file can only re-add the same rows.
        let replaced = files.contains { url in
            guard let prior = known[url.path], let attrs = fileAttributes(url) else { return false }
            return prior.inode != attrs.inode || attrs.size < prior.offset
        }
        if replaced {
            try db.resetFileOffsets(provider: key)
            known = [:]
            errors.append("\(parser.provider.displayName): a log file was replaced or "
                          + "shortened, so its logs were read again.")
        }

        var readCount = 0
        for url in files {
            guard let attrs = fileAttributes(url) else { continue }
            let start = known[url.path]?.offset ?? 0
            if known[url.path] != nil, start == attrs.size { continue }  // nothing new

            // Readings and the new offset are saved together or not at all.
            try db.savepoint("file")
            do {
                let newOffset = try parser.parse(url: url, from: start) { reading in
                    try self.db.addReading(provider: key, reading)
                }
                try db.setFileState(provider: key, path: url.path, inode: attrs.inode,
                                    offset: newOffset, mtime: attrs.mtime)
                try db.release("file")
                readCount += 1
            } catch let dbError as Database.DBError {
                db.rollback(to: "file")
                throw dbError                     // abort and roll back the whole pass
            } catch {
                db.rollback(to: "file")           // unreadable file: skip, retry next pass
            }
        }
        return (files.count, readCount)
    }

    private func fileAttributes(_ url: URL) -> (size: UInt64, inode: UInt64, mtime: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.uint64Value,
              let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value,
              let mtime = a[.modificationDate] as? Date else { return nil }
        return (size, inode, mtime)
    }

    // MARK: - Build

    private func build(_ provider: Provider, now: Date, seen: Int, read: Int,
                       errors: inout [String]) -> ProviderReading {
        do {
            return ProviderReading(
                provider: provider,
                // Every newest-per-source-and-limit reading. Which to show is
                // decided at display time, when expiry is known.
                readings: try db.latestReadings(provider: provider.rawValue),
                unavailableNote: provider == .claude ? ClaudeReadings.noReadingNote
                                                     : CodexParser.noReadingNote,
                filesSeen: seen,
                filesReadThisPass: read)
        } catch {
            errors.append("Couldn't read \(provider.displayName) data from the cache (\(error)).")
            return ProviderReading(provider: provider, readings: [],
                                   unavailableNote: "The local cache couldn't be read.")
        }
    }
}
