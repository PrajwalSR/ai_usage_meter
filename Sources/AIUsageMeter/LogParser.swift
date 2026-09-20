import Foundation

/// A provider whose session logs record its own usage limits.
///
/// Parsers only extract. They don't store anything or decide what to show:
/// `UsageIndex` does both.
///
/// Note there is no token counting here. The app deliberately does not count
/// tokens: it only shows limits a provider reported. That also means it never
/// needs to read Claude Code's logs at all.
protocol LogParser {
    static var provider: Provider { get }
    /// Directory scanned recursively for `*.jsonl`.
    static var root: URL { get }
    /// Shown when the provider has no allowance reading at all.
    static var noReadingNote: String { get }

    /// Reads `url` from byte `offset` and returns the offset just past the last
    /// complete line. Errors thrown by `onReading` (database failures) propagate
    /// so the whole index pass can be rolled back.
    static func parse(url: URL, from offset: UInt64,
                      onReading: (AllowanceReading) throws -> Void) throws -> UInt64
}
