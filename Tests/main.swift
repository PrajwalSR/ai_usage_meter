import Foundation

// Regression tests using synthetic data only. Never point these at real logs.
//
// Run with: ./scripts/run-tests.sh
//
// A tiny harness instead of XCTest, which needs full Xcode. Compiled together
// with every app source except the app's own main.swift.

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String,
           file: String = #fileID, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failures += 1
        print("  FAIL \(file):\(line) — \(message)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  FAIL threw \(error)")
    }
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("aiusagemeter-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func writeFile(_ name: String, _ data: Data) -> URL {
    let url = tmp.appendingPathComponent(name)
    try! data.write(to: url)
    return url
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - LineReader

test("LineReader: oversized line is skipped and the offset still covers it") {
    // Codex review: a ~69 MB read returned an offset of ~1 MB. Reproduced here
    // with a small limit.
    var content = Data("first\n".utf8)
    content.append(Data(repeating: UInt8(ascii: "x"), count: 500))  // oversized
    content.append(Data("\nlast\n".utf8))
    let url = writeFile("oversized.jsonl", content)

    var lines: [String] = []
    let offset = try LineReader.forEachLine(url: url, chunkSize: 16, maxLineBytes: 64) {
        lines.append(String(decoding: $0, as: UTF8.self))
    }
    check(lines == ["first", "last"], "expected only normal lines, got \(lines.map { $0.prefix(10) })")
    check(offset == UInt64(content.count), "offset \(offset) should equal file size \(content.count)")

    // A second pass from that offset must read nothing (no recounting).
    var again = 0
    let offset2 = try LineReader.forEachLine(url: url, from: offset, chunkSize: 16, maxLineBytes: 64) { _ in
        again += 1
    }
    check(again == 0 && offset2 == offset, "resuming re-read \(again) lines")
}

test("LineReader: an unfinished oversized line at end of file is not consumed") {
    var content = Data("ok\n".utf8)
    content.append(Data(repeating: UInt8(ascii: "y"), count: 300))  // no newline yet
    let url = writeFile("oversized-partial.jsonl", content)
    let offset = try LineReader.forEachLine(url: url, chunkSize: 16, maxLineBytes: 64) { _ in }
    check(offset == 3, "offset should stop after the last complete line, got \(offset)")
}

test("LineReader: a half-written last line is not delivered or consumed") {
    let url = writeFile("partial.jsonl", Data("{\"a\":1}\n{\"b\":".utf8))
    var lines: [String] = []
    let offset = try LineReader.forEachLine(url: url) { lines.append(String(decoding: $0, as: UTF8.self)) }
    check(lines == ["{\"a\":1}"], "got \(lines)")
    check(offset == 8, "offset \(offset) should be 8")
}

test("LineReader: resuming from an offset delivers only new lines") {
    let url = writeFile("resume.jsonl", Data("one\ntwo\nthree\n".utf8))
    var lines: [String] = []
    _ = try LineReader.forEachLine(url: url, from: 4) { lines.append(String(decoding: $0, as: UTF8.self)) }
    check(lines == ["two", "three"], "got \(lines)")
}

// MARK: - Expiry at display time

func window(_ pct: Double, minutes: Int, resetsIn: TimeInterval, limitId: String? = nil) -> AllowanceWindow {
    AllowanceWindow(usedPercent: pct, windowMinutes: minutes,
                    resetsAt: now.addingTimeInterval(resetsIn), limitId: limitId)
}

func providerReading(_ provider: Provider, _ reading: AllowanceReading?) -> ProviderReading {
    ProviderReading(provider: provider, readings: reading.map { [$0] } ?? [], unavailableNote: "n/a")
}

test("Expiry: a reading whose windows have all reset shows as unknown, never 0%") {
    let r = providerReading(.claude, AllowanceReading(
        recordedAt: now.addingTimeInterval(-7200), source: .claudeWeb, planType: nil,
        windows: [window(80, minutes: 300, resetsIn: -60)]))
    if case .expired = r.display(now: now) {} else { check(false, "expected .expired") }
    check(UsageStore.menuBarText(r, now: now) == "?", "menu bar should show ?")
}

test("Expiry: the same reading is valid before reset and unknown after, without a rescan") {
    let r = providerReading(.codex, AllowanceReading(
        recordedAt: now, source: .codexLog, planType: nil,
        windows: [window(55, minutes: 10080, resetsIn: 120)]))
    if case .available = r.display(now: now) {} else { check(false, "expected .available before reset") }
    if case .expired = r.display(now: now.addingTimeInterval(121)) {} else {
        check(false, "expected .expired after reset")
    }
}

test("Expiry: an expired window is dropped while a valid one stays") {
    let r = providerReading(.claude, AllowanceReading(
        recordedAt: now, source: .claudeWeb, planType: nil,
        windows: [window(90, minutes: 300, resetsIn: -1), window(40, minutes: 10080, resetsIn: 86400)]))
    guard case .available(let head, let others, _) = r.display(now: now) else {
        return check(false, "expected .available")
    }
    check(head.windowMinutes == 10080 && head.usedPercent == 40, "headline should be the valid 7-day window")
    check(others.isEmpty, "expired 5-hour window must not appear")
}

test("Menu bar text: percentage and countdown") {
    let r = providerReading(.claude, AllowanceReading(
        recordedAt: now, source: .claudeWeb, planType: nil,
        windows: [window(38.4, minutes: 300, resetsIn: 2 * 3600 + 21 * 60 + 5)]))
    check(UsageStore.menuBarText(r, now: now) == "38% in 2h 21m",
          "got \(UsageStore.menuBarText(r, now: now))")
    check(UsageStore.menuBarText(providerReading(.codex, nil), now: now) == "—", "no reading should be —")
}

test("Menu bar colour: plain below 25%, then yellow, orange, red") {
    check(ProviderIcons.UsageBand(usedPercent: 0) == .plain, "0% should be plain")
    check(ProviderIcons.UsageBand(usedPercent: 24) == .plain, "24% should be plain")
    check(ProviderIcons.UsageBand(usedPercent: 25) == .low, "25% should be yellow")
    check(ProviderIcons.UsageBand(usedPercent: 49) == .low, "49% should be yellow")
    check(ProviderIcons.UsageBand(usedPercent: 50) == .medium, "50% should be orange")
    check(ProviderIcons.UsageBand(usedPercent: 79) == .medium, "79% should be orange")
    check(ProviderIcons.UsageBand(usedPercent: 80) == .high, "80% should be red")
    check(ProviderIcons.UsageBand(usedPercent: 100) == .high, "100% should be red")

    // The colour follows the number shown, which is rounded: 24.6% reads "25%".
    let r = providerReading(.claude, AllowanceReading(
        recordedAt: now, source: .claudeWeb, planType: nil,
        windows: [window(24.6, minutes: 300, resetsIn: 3600)]))
    check(UsageStore.menuBarFigure(r, now: now).usedPercent == 25, "colour should use the rounded figure")
    let expired = providerReading(.claude, AllowanceReading(
        recordedAt: now.addingTimeInterval(-7200), source: .claudeWeb, planType: nil,
        windows: [window(90, minutes: 300, resetsIn: -60)]))
    check(UsageStore.menuBarFigure(expired, now: now).usedPercent == nil, "an unknown figure gets no colour")
}

// MARK: - Codex windows and limit ids

test("Codex: every window and its limit_id are kept; headline is the one closest to its limit") {
    let rl: [String: Any] = [
        "limit_id": "codex",
        "plan_type": "prolite",
        "primary": ["used_percent": 54.0, "window_minutes": 10080, "resets_at": 1_800_100_000],
        "secondary": ["used_percent": 71.0, "window_minutes": 300, "resets_at": 1_800_010_000],
    ]
    guard let reading = CodexParser.reading(from: rl, recordedAt: now) else {
        return check(false, "no reading parsed")
    }
    check(reading.windows.count == 2, "expected 2 windows, got \(reading.windows.count)")
    check(reading.windows.allSatisfy { $0.limitId == "codex" }, "limit_id lost")
    check(reading.planType == "prolite", "plan lost")
    check(Provider.codex.headline(from: reading.windows)?.usedPercent == 71, "headline should be 71%")
}

test("Codex: window length comes from window_minutes, not from primary/secondary") {
    let rl: [String: Any] = [
        "primary": ["used_percent": 54.0, "window_minutes": 10080, "resets_at": 1_800_100_000],
        "secondary": NSNull(),
    ]
    let reading = CodexParser.reading(from: rl, recordedAt: now)
    check(reading?.windows.count == 1, "null secondary should be ignored")
    check(reading?.windows.first?.windowLabel == "1-week", "primary should be labeled 1-week")
}

test("Codex: a log file yields its limit reading, and nothing else is read") {
    let lines = [
        #"{"timestamp":"2027-01-15T08:00:00.000Z","type":"token_usage_record","payload":{"usage":{"input_tokens":1000,"output_tokens":50}}}"#,
        #"{"timestamp":"2027-01-15T08:00:01.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":12.5,"window_minutes":10080,"resets_at":1800000000}}}}"#,
        #"{"timestamp":"2027-01-15T08:00:02.000Z","type":"response_item","payload":{"text":"unrelated"}}"#,
    ].joined(separator: "\n") + "\n"
    let url = writeFile("codex.jsonl", Data(lines.utf8))
    var readings: [AllowanceReading] = []
    _ = try CodexParser.parse(url: url, from: 0) { readings.append($0) }
    check(readings.count == 1, "expected exactly one reading, got \(readings.count)")
    check(readings.first?.windows.first?.usedPercent == 12.5, "reading not parsed")
}

// MARK: - Claude sources

func claudeReading(_ source: ReadingSource, age: TimeInterval, pct: Double) -> AllowanceReading {
    AllowanceReading(recordedAt: now.addingTimeInterval(-age), source: source, planType: nil,
                     windows: [window(pct, minutes: 300, resetsIn: 3600)])
}

test("Claude: a fresh claude.ai reading wins over a newer status-line reading") {
    let web = claudeReading(.claudeWeb, age: 5 * 60, pct: 40)
    let status = claudeReading(.claudeStatusLine, age: 10, pct: 20)
    check(ClaudeReadings.choose([status, web], now: now)?.source == .claudeWeb, "claude.ai should win")
}

test("Claude: a stale claude.ai reading loses to a newer status-line reading") {
    let web = claudeReading(.claudeWeb, age: 60 * 60, pct: 40)
    let status = claudeReading(.claudeStatusLine, age: 10, pct: 20)
    check(ClaudeReadings.choose([web, status], now: now)?.source == .claudeStatusLine,
          "newer status line should win over hour-old claude.ai")
}

test("Claude: the two sources are read from separate files") {
    let webURL = writeFile("claude-web.json", Data(
        #"{"received_at":1800000000,"rate_limits":{"five_hour":{"used_percentage":38,"resets_at":1800003600}}}"#.utf8))
    let statusURL = writeFile("claude.json", Data(
        #"{"received_at":1799999000,"rate_limits":{"seven_day":{"used_percentage":63,"resets_at":1800500000}}}"#.utf8))
    // Point every source at the temp folder: a test must never read the real files.
    let all = ClaudeReadings.load(statusLineURL: statusURL, webURL: webURL)
    check(all.count == 2, "expected both readings")
    check(all.contains { $0.source == .claudeWeb && $0.windows.first?.windowMinutes == 300 }, "claude.ai missing")
    check(all.contains { $0.source == .claudeStatusLine && $0.windows.first?.windowMinutes == 10080 },
          "status line missing")
}

test("Claude: files from older builds (recorded_at) still load") {
    let url = writeFile("legacy.json", Data(
        #"{"recorded_at":1800000000,"source":"anthropic-usage-endpoint","rate_limits":{"five_hour":{"used_percentage":10}}}"#.utf8))
    let r = ClaudeReadings.read(url, source: .claudeStatusLine)
    check(r?.source == .claudeStatusLine && r?.windows.first?.usedPercent == 10, "legacy file should load")
}

// MARK: - Database

test("Database: a rolled-back pass leaves no readings and no offsets behind") {
    let db = try Database(url: tmp.appendingPathComponent("rollback.sqlite"))
    try db.begin()
    try db.addReading(provider: "codex", AllowanceReading(
        recordedAt: now, source: .codexLog, planType: nil,
        windows: [window(10, minutes: 10080, resetsIn: 600, limitId: "codex")]))
    try db.setFileState(provider: "codex", path: "/fake.jsonl", inode: 1, offset: 99, mtime: now)
    db.rollback()
    let readings = try db.latestReadings(provider: "codex")
    let offsets = try db.fileStates(provider: "codex")
    check(readings.isEmpty, "reading survived rollback")
    check(offsets.isEmpty, "offset survived rollback")
}

test("Database: a file's savepoint rollback undoes only that file") {
    let db = try Database(url: tmp.appendingPathComponent("savepoint.sqlite"))
    try db.begin()
    try db.setFileState(provider: "codex", path: "/first.jsonl", inode: 1, offset: 10, mtime: now)
    try db.savepoint("file")
    try db.setFileState(provider: "codex", path: "/second.jsonl", inode: 2, offset: 20, mtime: now)
    db.rollback(to: "file")
    try db.commit()
    let kept = try db.fileStates(provider: "codex")
    check(kept.count == 1 && kept["/first.jsonl"] != nil,
          "partial file writes should be undone, earlier writes kept: \(kept.keys.sorted())")
}

test("Database: write errors are thrown, not ignored") {
    let db = try Database(url: tmp.appendingPathComponent("errors.sqlite"))
    var threw = false
    do { try db.exec("INSERT INTO no_such_table VALUES (1);") } catch { threw = true }
    check(threw, "invalid write should throw")
}

test("Database: readings keep every window and the newest per source and limit") {
    let db = try Database(url: tmp.appendingPathComponent("readings.sqlite"))
    // Same limit id as `new`, so `new` replaces it. (Different ids are kept
    // separately; see the multi-limit test below.)
    let old = AllowanceReading(recordedAt: now.addingTimeInterval(-100), source: .codexLog, planType: "plus",
                               windows: [window(10, minutes: 10080, resetsIn: 1000, limitId: "codex")])
    let new = AllowanceReading(recordedAt: now, source: .codexLog, planType: "prolite",
                               windows: [window(20, minutes: 10080, resetsIn: 1000, limitId: "codex"),
                                         window(30, minutes: 300, resetsIn: 100, limitId: "codex")])
    try db.addReading(provider: "codex", old)
    try db.addReading(provider: "codex", new)
    let latest = try db.latestReadings(provider: "codex")
    check(latest.count == 1, "one source and limit → one latest reading, got \(latest.count)")
    check(latest.first?.windows.count == 2 && latest.first?.planType == "prolite", "windows or plan lost")
    check(latest.first?.windows.first?.limitId == "codex", "limit id lost")
}

// MARK: - Found in the second Codex review

test("Codex: a newer reading for one limit doesn't hide another still-valid limit") {
    let db = try Database(url: tmp.appendingPathComponent("multi-limit.sqlite"))
    let a = AllowanceReading(recordedAt: now.addingTimeInterval(-10), source: .codexLog, planType: nil,
                             windows: [window(80, minutes: 10080, resetsIn: 3600, limitId: "codex")])
    let b = AllowanceReading(recordedAt: now, source: .codexLog, planType: nil,
                             windows: [window(5, minutes: 10080, resetsIn: 3600, limitId: "other-limit")])
    try db.addReading(provider: "codex", a)
    try db.addReading(provider: "codex", b)
    let latest = try db.latestReadings(provider: "codex")
    let ids = latest.flatMap { $0.windows.compactMap(\.limitId) }
    check(Set(ids) == Set(["codex", "other-limit"]), "lost a still-valid limit: \(ids)")

    // …and the display shows both, headline = closest to its limit.
    let r = ProviderReading(provider: .codex, readings: latest, unavailableNote: "")
    guard case .available(let head, let others, _) = r.display(now: now) else {
        return check(false, "expected .available")
    }
    check(head.limitId == "codex" && head.usedPercent == 80, "headline should be the 80% codex limit")
    check(others.map(\.limitId) == ["other-limit"], "other limit should be listed")
}

test("Claude: an expired claude.ai reading doesn't hide a valid status-line reading") {
    let live = AllowanceReading(recordedAt: now.addingTimeInterval(-120), source: .claudeWeb, planType: nil,
                                windows: [window(99, minutes: 300, resetsIn: -1)])
    let status = claudeReading(.claudeStatusLine, age: 10, pct: 2)
    check(ClaudeReadings.choose([live, status], now: now)?.source == .claudeStatusLine,
          "expired claude.ai reading won over a valid status-line reading")

    // Also at display time: a claude.ai reading that expires after loading must stop winning.
    let fresh = AllowanceReading(recordedAt: now, source: .claudeWeb, planType: nil,
                                 windows: [window(50, minutes: 300, resetsIn: 60)])
    let backup = AllowanceReading(recordedAt: now, source: .claudeStatusLine, planType: nil,
                                  windows: [window(20, minutes: 300, resetsIn: 7200)])
    let r = providerReading(.claude, nil)
    var both = r
    both.readings = [fresh, backup]
    if case .available(_, _, let src) = both.display(now: now) {
        check(src.source == .claudeWeb, "fresh claude.ai should win before it expires")
    } else { check(false, "expected .available") }
    if case .available(_, _, let src) = both.display(now: now.addingTimeInterval(61)) {
        check(src.source == .claudeStatusLine, "status line should win once claude.ai expires")
    } else { check(false, "expected .available after claude.ai expiry") }
}

test("LineReader: an oversized line that ends inside one chunk is skipped") {
    let content = Data((String(repeating: "x", count: 65) + "\nok\n").utf8)
    let url = writeFile("single-chunk.jsonl", content)
    var lines: [String] = []
    let offset = try LineReader.forEachLine(url: url, chunkSize: 1024, maxLineBytes: 64) {
        lines.append(String(decoding: $0, as: UTF8.self))
    }
    check(lines == ["ok"], "oversized complete line was delivered")
    check(offset == UInt64(content.count), "offset should cover the whole file")
}

test("Database: schema upgrade is all-or-nothing and the version is in the file name") {
    check(Database.defaultURL.lastPathComponent == "cache-v\(Database.schemaVersion).sqlite",
          "cache file name should include the schema version")
    let url = tmp.appendingPathComponent("upgrade.sqlite")
    _ = try Database(url: url)                  // creates current schema
    let reopened = try Database(url: url)       // reopening must not drop data
    try reopened.begin()
    try reopened.setFileState(provider: "codex", path: "/x.jsonl", inode: 1, offset: 5, mtime: now)
    try reopened.commit()
    let again = try Database(url: url)
    let kept = try again.fileStates(provider: "codex")
    check(kept.count == 1, "reopening a current cache lost data")
}

test("Database: a pass refuses to write if another build changed the schema") {
    let url = tmp.appendingPathComponent("foreign.sqlite")
    let db = try Database(url: url)
    try db.exec("PRAGMA user_version = 999;")   // simulate a different build
    var threw = false
    do { try db.begin() } catch { threw = true }
    check(threw, "begin() should refuse a mismatched schema")
}

test("InstanceLock: a second holder is refused until the first releases") {
    let url = tmp.appendingPathComponent("instance.lock")
    var first = InstanceLock(url: url)
    check(first != nil, "first lock should succeed")
    check(InstanceLock(url: url) == nil, "second lock should be refused")
    first = nil
    check(InstanceLock(url: url) != nil, "lock should be available after release")
}

// MARK: - Found while comparing against the Claude app

test("A window with no reset time goes stale once it is older than its own length") {
    // Anthropic omits resets_at for a 5-hour window sitting at 0%. Such a reading
    // used to stay on screen for ever, showing 0% long after real use had started.
    let noReset = AllowanceWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, limitId: nil)
    let reading = AllowanceReading(recordedAt: now, source: .claudeWeb, planType: nil,
                                   windows: [noReset])
    check(reading.liveWindows(now: now.addingTimeInterval(3600)).count == 1,
          "should still count an hour later")
    check(reading.liveWindows(now: now.addingTimeInterval(5 * 3600 + 1)).isEmpty,
          "should be stale just past 5 hours")

    let r = providerReading(.claude, reading)
    check(UsageStore.menuBarText(r, now: now.addingTimeInterval(13 * 3600)) == "?",
          "a 13-hour-old 5-hour reading must not show a percentage")
}

test("A window with no reset time and no length is trusted for an hour") {
    let w = AllowanceWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, limitId: nil)
    let reading = AllowanceReading(recordedAt: now, source: .codexLog, planType: nil, windows: [w])
    check(!reading.liveWindows(now: now.addingTimeInterval(59 * 60)).isEmpty, "valid within the hour")
    check(reading.liveWindows(now: now.addingTimeInterval(3601)).isEmpty, "stale after an hour")
}

test("An explicit reset time still wins over the window's length") {
    let w = AllowanceWindow(usedPercent: 20, windowMinutes: 10080,
                            resetsAt: now.addingTimeInterval(60), limitId: nil)
    let reading = AllowanceReading(recordedAt: now, source: .claudeWeb, planType: nil, windows: [w])
    check(reading.liveWindows(now: now.addingTimeInterval(61)).isEmpty,
          "a passed reset time expires the window even though the week isn't over")
}

// MARK: - claude.ai website source

test("claude.ai reply: real windows are kept, internal code-name entries are not") {
    // Shape copied from a real reply, values invented. Entries like
    // "nimbus_quill" are 0% with no window and no reset: not usage limits.
    let json = """
    {"__orgCount":1,"usage":{
      "five_hour":{"utilization":45,"resets_at":"2027-03-01T15:50:00.000000Z","limit_dollars":null},
      "seven_day":{"utilization":13,"resets_at":"2027-03-05T17:00:00.000000Z"},
      "seven_day_opus":null,
      "nimbus_quill":{"utilization":0,"resets_at":null},
      "extra_usage":{"is_enabled":false,"utilization":null}}}
    """
    let windows = Dictionary(uniqueKeysWithValues: WebUsageSource.parseWindows(
        (try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])["usage"]!))
    check(windows.count == 2, "expected 2 real windows, got \(windows.keys.sorted())")
    check(windows["five_hour"]?.usedPercent == 45 && windows["five_hour"]?.windowMinutes == 300,
          "five_hour wrong: \(String(describing: windows["five_hour"]))")
    check(windows["seven_day"]?.usedPercent == 13 && windows["seven_day"]?.windowMinutes == 10080,
          "seven_day wrong")
    check(windows["five_hour"]?.resetsAt != nil, "reset time should be parsed from the ISO string")
    check(windows["nimbus_quill"] == nil, "internal entry should be ignored")
}

test("claude.ai: a named limit with a reset time is kept under its own name") {
    let json = """
    {"usage":{"some_new_limit":{"utilization":22,"resets_at":"2027-03-02T10:00:00.000000Z"}}}
    """
    let windows = WebUsageSource.parseWindows(
        (try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])["usage"]!)
    check(windows.count == 1 && windows[0].1.limitId == "some_new_limit",
          "an unfamiliar but real limit should be kept, labelled: \(windows)")
}

test("chatgpt.com: primary/secondary windows keep their length and reset time") {
    // chatgpt.com names windows by rank; the length comes from window_minutes,
    // and some replies give the reset as seconds from now.
    let json = """
    {"usage":{"rate_limits":{
      "primary_window":{"used_percent":61,"limit_window_seconds":604800,"reset_after_seconds":500000,"reset_at":1800500000},
      "secondary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1800000000}}}}
    """
    let windows = Dictionary(uniqueKeysWithValues: WebUsageSource.parseWindows(
        (try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])["usage"]!))
    check(windows.count == 2, "expected both windows, got \(windows.keys.sorted())")
    check(windows["primary"]?.windowMinutes == 10080 && windows["primary"]?.usedPercent == 61,
          "weekly window wrong: \(String(describing: windows["primary"]))")
    check(windows["primary"]?.resetsAt != nil, "reset time should be parsed")
    check(windows["primary"]?.limitId == nil, "a rank name is not a limit id")
    check(windows["secondary"]?.windowMinutes == 300, "5-hour window wrong")
}

test("Source priority: a website wins, and each provider falls back in its own order") {
    let webCodex = AllowanceReading(recordedAt: now.addingTimeInterval(-30), source: .chatgptWeb,
                                    planType: nil, windows: [window(61, minutes: 10080, resetsIn: 8000)])
    let logCodex = AllowanceReading(recordedAt: now, source: .codexLog, planType: "prolite",
                                    windows: [window(55, minutes: 10080, resetsIn: 8000, limitId: "codex")])
    let chosen = ReadingSelection.choose(provider: .codex, readings: [logCodex, webCodex], now: now)
    check(chosen.map(\.source) == [.chatgptWeb], "chatgpt.com should win even over a newer log line")

    // …but an hours-old website reading loses to the log.
    let staleWeb = AllowanceReading(recordedAt: now.addingTimeInterval(-3600), source: .chatgptWeb,
                                    planType: nil, windows: [window(61, minutes: 10080, resetsIn: 8000)])
    check(ReadingSelection.choose(provider: .codex, readings: [logCodex, staleWeb], now: now)
            .map(\.source) == [.codexLog], "a stale website reading should lose to the log")
}

test("A website reading replaces that source's earlier set, not just same-named limits") {
    // chatgpt.com once reported "primary_window", then "primary". The old row
    // must not survive as if it were a second limit.
    let db = try Database(url: tmp.appendingPathComponent("supersede.sqlite"))
    try db.addReading(provider: "codex", AllowanceReading(
        recordedAt: now.addingTimeInterval(-60), source: .chatgptWeb, planType: nil,
        windows: [window(61, minutes: nil ?? 0, resetsIn: 3600, limitId: "primary_window")]))
    try db.deleteReadings(provider: "codex", source: .chatgptWeb)
    try db.addReading(provider: "codex", AllowanceReading(
        recordedAt: now, source: .chatgptWeb, planType: nil,
        windows: [window(61, minutes: 10080, resetsIn: 3600)]))
    let latest = try db.latestReadings(provider: "codex")
    check(latest.count == 1, "expected one reading, got \(latest.count)")
    check(latest.first?.windows.count == 1 && latest.first?.windows.first?.windowMinutes == 10080,
          "the old row survived: \(String(describing: latest.first?.windows))")

    // Log readings are not cleared this way.
    try db.addReading(provider: "codex", AllowanceReading(
        recordedAt: now, source: .codexLog, planType: nil,
        windows: [window(55, minutes: 10080, resetsIn: 3600, limitId: "codex")]))
    try db.deleteReadings(provider: "codex", source: .chatgptWeb)
    let afterClear = try db.latestReadings(provider: "codex")
    check(afterClear.map(\.source) == [.codexLog], "log readings should be untouched")
}

// MARK: - Result

print("\n\(passed) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
