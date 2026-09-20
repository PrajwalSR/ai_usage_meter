import Foundation

/// A provider whose session logs live in a directory of JSONL files.
///
/// Parsers only extract. They don't store anything or decide what to show:
/// `UsageIndex` does both.
protocol LogParser {
    static var provider: Provider { get }
    /// Directory scanned recursively for `*.jsonl`.
    static var root: URL { get }
    /// Shown when the provider has no allowance reading at all.
    static var noReadingNote: String { get }

    /// Reads `url` from byte `offset` and returns the offset just past the last
    /// complete line. Errors thrown by the callbacks (database failures)
    /// propagate so the whole index pass can be rolled back.
    static func parse(url: URL, from offset: UInt64,
                      onUsage: (Date, TokenTotals) throws -> Void,
                      onReading: (AllowanceReading) throws -> Void) throws -> UInt64
}
