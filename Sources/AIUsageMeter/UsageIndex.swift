import Foundation

/// Turns log files and reading files into a `UsageReport`.
///
/// Each pass has two steps:
/// 1. **Ingest** (one transaction): read only bytes appended since the last pass,
///    add token counts to 5-minute buckets, store allowance readings, save new
///    file offsets. If any write fails the transaction is rolled back, so token
///    totals and offsets can never disagree. The next pass retries.
/// 2. **Build**: read totals and readings back and assemble the report.
///
/// Owned by one background task; not thread-safe.
final class UsageIndex {
    private let db: Database
    /// How far back token totals go, and how old a log file may be to be read.
    static let retention: TimeInterval = 7 * 86400
    private static let bucketSeconds: Int64 = 300

    init(url: URL = Database.defaultURL) throws {
        db = try Database(url: url)
    }

    func refresh(now: Date = Date()) -> UsageReport {
        let t0 = Date()
        var errors: [String] = []
        var readCounts: [Provider: Int] = [:]
        var seenCounts: [Provider: Int] = [:]

        do {
            try db.begin()
            for parser in [CodexParser.self, ClaudeParser.self] as [LogParser.Type] {
                let (seen, read) = try ingest(parser, now: now, errors: &errors)
                seenCounts[parser.provider] = seen
                readCounts[parser.provider] = read
            }
            for reading in ClaudeReadings.load() {
                try db.addReading(provider: Provider.claude.rawValue, reading)
            }
            try db.pruneBuckets(before: now.addingTimeInterval(-Self.retention))
            try db.pruneReadings(before: now.addingTimeInterval(-30 * 86400))
            try db.commit()
        } catch {
            db.rollback()
            errors.append("Couldn't update the local cache (\(error)). Nothing was saved; "
                          + "it will retry on the next update.")
            readCounts = [:]
        }

        let codex = build(.codex, now: now, seen: seenCounts[.codex] ?? 0,
                          read: readCounts[.codex] ?? 0, errors: &errors)
        let claude = build(.claude, now: now, seen: seenCounts[.claude] ?? 0,
                           read: readCounts[.claude] ?? 0, errors: &errors)
        return UsageReport(claude: claude, codex: codex, scannedAt: now,
                           scanDuration: Date().timeIntervalSince(t0), errors: errors)
    }

    // MARK: - Ingest

    /// Returns (files seen, files with new bytes). Throws only database errors.
    private func ingest(_ parser: LogParser.Type, now: Date,
                        errors: inout [String]) throws -> (Int, Int) {
        let key = parser.provider.rawValue
        let cutoff = now.addingTimeInterval(-Self.retention)
        var known = try db.fileStates(provider: key)

        // A file untouched since the cutoff can't hold entries inside the window.
        let files = recentJSONLFiles(root: parser.root, modifiedAfter: cutoff)

        // Replaced or truncated logs: that file's earlier tokens are already in
        // the buckets and can't be subtracted, so rebuild this provider's totals.
        // Checked up front so the rebuild happens once, before any reading.
        let replaced = files.contains { url in
            guard let prior = known[url.path], let attrs = fileAttributes(url) else { return false }
            return prior.inode != attrs.inode || attrs.size < prior.offset
        }
        if replaced {
            try db.resetTokens(provider: key)
            known = [:]
            errors.append("\(parser.provider.displayName): a log file was replaced or "
                          + "shortened, so token totals were rebuilt.")
        }

        var readCount = 0
        for url in files {
            guard let attrs = fileAttributes(url) else { continue }
            let start = known[url.path]?.offset ?? 0
            if known[url.path] != nil, start == attrs.size { continue }  // nothing new

            // A file's tokens and its new offset are saved together or not at
            // all: a read error halfway through must not leave half its tokens
            // counted with the old offset, or the retry would count them twice.
            try db.savepoint("file")
            do {
                let newOffset = try parser.parse(url: url, from: start, onUsage: { ts, totals in
                    guard ts >= cutoff else { return }
                    let bucket = (Int64(ts.timeIntervalSince1970) / Self.bucketSeconds) * Self.bucketSeconds
                    try self.db.addUsage(provider: key, bucket: bucket, totals)
                }, onReading: { reading in
                    try self.db.addReading(provider: key, reading)
                })
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
        let key = provider.rawValue
        do {
            return ProviderReading(
                provider: provider,
                // Every newest-per-source-and-limit reading. Which to show is
                // decided at display time, when expiry is known.
                readings: try db.latestReadings(provider: key),
                unavailableNote: provider == .claude ? ClaudeParser.noReadingNote
                                                     : CodexParser.noReadingNote,
                last5Hours: try db.totals(provider: key, since: now.addingTimeInterval(-5 * 3600)),
                last7Days: try db.totals(provider: key, since: now.addingTimeInterval(-Self.retention)),
                filesSeen: seen,
                filesReadThisPass: read,
                newestLogEntry: try db.newestBucket(provider: key))
        } catch {
            errors.append("Couldn't read \(provider.displayName) data from the cache (\(error)).")
            return ProviderReading(provider: provider, readings: [],
                                   unavailableNote: "The local cache couldn't be read.",
                                   last5Hours: TokenTotals(), last7Days: TokenTotals(),
                                   filesSeen: seen, filesReadThisPass: read, newestLogEntry: nil)
        }
    }
}
