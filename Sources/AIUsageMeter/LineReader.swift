import Foundation

/// Streams a file line by line without loading it into memory. The log
/// directories run to hundreds of megabytes, so nothing here reads a whole file.
///
/// A trailing fragment with no newline is treated as an incomplete line and is
/// NOT returned: the CLI may be mid-write, and half a JSON object is not data.
///
/// Lines longer than `maxLineBytes` are skipped, not delivered. Their bytes still
/// count toward the returned offset once the line's newline is reached, so a
/// later pass resumes after the line instead of re-reading (and re-counting)
/// everything that followed it.
struct LineReader {
    static let maxLineBytes = 64 << 20

    /// Calls `onLine` for each complete line. Returns the byte offset just past
    /// the last complete line (skipped oversized lines included), so a later run
    /// can resume from there.
    @discardableResult
    static func forEachLine(
        url: URL,
        from offset: UInt64 = 0,
        chunkSize: Int = 1 << 20,
        maxLineBytes: Int = LineReader.maxLineBytes,
        onLine: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var carry = Data()
        var consumed = offset
        // Bytes of an oversized line already discarded. Added to `consumed` only
        // when that line's newline arrives; if the file ends first, the line is
        // incomplete and the next pass must start from its beginning again.
        var skippedBytes: UInt64 = 0
        var skipping = false

        while true {
            // Each `read` returns an autoreleased Data; over a multi-hundred-MB
            // scan those pile up unless the pool is drained every chunk.
            var done = false
            try autoreleasepool { () -> Void in
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { done = true; return }
                carry.append(chunk)

                var searchStart = carry.startIndex
                while let nl = carry[searchStart...].firstIndex(of: 0x0A) {
                    let lineLength = UInt64(carry.distance(from: searchStart, to: nl))
                    if skipping {
                        // Tail of an oversized line: discard it, don't deliver.
                        skipping = false
                    } else if lineLength > UInt64(maxLineBytes) {
                        // Oversized line that fit inside the buffer: skip it too.
                    } else if lineLength > 0 {
                        let line = carry[searchStart..<nl]
                        // JSONSerialization returns autoreleased objects; drain
                        // per line so they don't live until the scan ends.
                        try autoreleasepool {
                            try line.withUnsafeBytes { try onLine($0) }
                        }
                    }
                    consumed += skippedBytes + lineLength + 1
                    skippedBytes = 0
                    searchStart = carry.index(after: nl)
                }
                carry.removeSubrange(carry.startIndex..<searchStart)

                // A line with no newline yet that is already too long: stop
                // buffering it, remember how much was dropped, skip to its end.
                if carry.count > maxLineBytes {
                    skippedBytes += UInt64(carry.count)
                    skipping = true
                    carry.removeAll(keepingCapacity: false)
                }
            }
            if done { break }
        }
        return consumed
    }

    /// Cheap substring test on raw bytes, so we only pay for JSON parsing on
    /// the small fraction of lines that can possibly carry usage data.
    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count, !needle.isEmpty else { return false }
        let first = needle[0]
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}

enum JSONPath {
    static func int(_ dict: [String: Any], _ key: String) -> Int {
        if let i = dict[key] as? Int { return i }
        if let d = dict[key] as? Double { return Int(d) }
        return 0
    }

    static func double(_ dict: [String: Any], _ key: String) -> Double? {
        if let d = dict[key] as? Double { return d }
        if let i = dict[key] as? Int { return Double(i) }
        return nil
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }
}

/// Finds *.jsonl under a root, newest first, skipping files untouched before
/// `modifiedAfter` so a 7-day view doesn't reread years of history.
func recentJSONLFiles(root: URL, modifiedAfter: Date?, limit: Int? = nil) -> [URL] {
    let fm = FileManager.default
    guard let en = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var found: [(URL, Date)] = []
    for case let url as URL in en {
        guard url.pathExtension == "jsonl" else { continue }
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard vals?.isRegularFile == true else { continue }
        let mtime = vals?.contentModificationDate ?? .distantPast
        if let modifiedAfter, mtime < modifiedAfter { continue }
        found.append((url, mtime))
    }
    found.sort { $0.1 > $1.1 }
    let urls = found.map(\.0)
    if let limit { return Array(urls.prefix(limit)) }
    return urls
}
