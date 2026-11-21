import AppKit
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
        recordedAt: now, source: .chatgptWeb, planType: nil,
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

test("Codex: the headline is the window closest to its limit") {
    let windows = [window(54, minutes: 10080, resetsIn: 100_000, limitId: "codex"),
                   window(71, minutes: 300, resetsIn: 10_000, limitId: "codex")]
    check(Provider.codex.headline(from: windows)?.usedPercent == 71, "headline should be 71%")
}

test("Codex: usage comes only from chatgpt.com; the app never reads ~/.codex") {
    check(Provider.codex.sourcePriority == [.chatgptWeb], "chatgpt.com should be the only source")
    let dir = URL(fileURLWithPath: "Sources/AIUsageMeter")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(!files.isEmpty, "app sources not found from \(FileManager.default.currentDirectoryPath)")
    for name in files where name.hasSuffix(".swift") {
        let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        check(!text.contains("\".codex/") && !text.contains("\".codex\""), "\(name) refers to the ~/.codex folder")
    }
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

test("Database: a rolled-back pass leaves no readings behind") {
    let db = try Database(url: tmp.appendingPathComponent("rollback.sqlite"))
    try db.begin()
    try db.addReading(provider: "codex", AllowanceReading(
        recordedAt: now, source: .chatgptWeb, planType: nil,
        windows: [window(10, minutes: 10080, resetsIn: 600, limitId: "codex")]))
    db.rollback()
    let readings = try db.latestReadings(provider: "codex")
    check(readings.isEmpty, "reading survived rollback")
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
    let old = AllowanceReading(recordedAt: now.addingTimeInterval(-100), source: .chatgptWeb, planType: "plus",
                               windows: [window(10, minutes: 10080, resetsIn: 1000, limitId: "codex")])
    let new = AllowanceReading(recordedAt: now, source: .chatgptWeb, planType: "prolite",
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
    let a = AllowanceReading(recordedAt: now.addingTimeInterval(-10), source: .chatgptWeb, planType: nil,
                             windows: [window(80, minutes: 10080, resetsIn: 3600, limitId: "codex")])
    let b = AllowanceReading(recordedAt: now, source: .chatgptWeb, planType: nil,
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

test("Database: schema upgrade is all-or-nothing and the version is in the file name") {
    check(Database.defaultURL.lastPathComponent == "cache-v\(Database.schemaVersion).sqlite",
          "cache file name should include the schema version")
    let url = tmp.appendingPathComponent("upgrade.sqlite")
    _ = try Database(url: url)                  // creates current schema
    let reopened = try Database(url: url)       // reopening must not drop data
    try reopened.begin()
    try reopened.addReading(provider: "codex", AllowanceReading(
        recordedAt: now, source: .chatgptWeb, planType: nil,
        windows: [window(10, minutes: 10080, resetsIn: 600)]))
    try reopened.commit()
    let again = try Database(url: url)
    let kept = try again.latestReadings(provider: "codex")
    check(kept.count == 1, "reopening a current cache lost data")
}

test("Old caches are deleted; the current one and other files are kept") {
    let dir = tmp.appendingPathComponent("caches")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let names = ["cache-v4.sqlite", "cache-v4.sqlite-wal", "cache-v4.sqlite-shm", "cache-v3.sqlite",
                 "cache-v5.sqlite", "cache-v5.sqlite-wal", "accounts.json"]
    for name in names { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()) }
    LegacyCleanup.removeOldCaches(current: dir.appendingPathComponent("cache-v5.sqlite"))
    let left = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    check(left == ["cache-v5.sqlite", "cache-v5.sqlite-wal", "accounts.json"], "left: \(left.sorted())")
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
    let reading = AllowanceReading(recordedAt: now, source: .chatgptWeb, planType: nil, windows: [w])
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

test("Source priority: a fresh claude.ai reading wins; a stale one loses to the status line") {
    let web = AllowanceReading(recordedAt: now.addingTimeInterval(-30), source: .claudeWeb,
                               planType: nil, windows: [window(61, minutes: 300, resetsIn: 8000)])
    let status = AllowanceReading(recordedAt: now, source: .claudeStatusLine, planType: nil,
                                  windows: [window(55, minutes: 300, resetsIn: 8000)])
    check(ReadingSelection.choose(provider: .claude, readings: [status, web], now: now)
            .map(\.source) == [.claudeWeb], "claude.ai should win even over a newer status line")
    let staleWeb = AllowanceReading(recordedAt: now.addingTimeInterval(-3600), source: .claudeWeb,
                                    planType: nil, windows: [window(61, minutes: 300, resetsIn: 8000)])
    check(ReadingSelection.choose(provider: .claude, readings: [status, staleWeb], now: now)
            .map(\.source) == [.claudeStatusLine], "a stale claude.ai reading should lose")
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
}

// MARK: - Result

test("Account registry preserves legacy sign-ins and persists separate accounts") {
    MainActor.assumeIsolated {
    let url = tmp.appendingPathComponent("accounts.json")
    let registry = AccountRegistry(fileURL: url)
    check(registry.accounts.count == 2, "first launch should include both previous sign-ins")
    check(registry.accounts.map(\.id) == [AccountRegistry.legacyClaudeID,
                                         AccountRegistry.legacyCodexID],
          "legacy IDs must stay fixed across upgrades")

    let extra = registry.add(provider: .claude, label: "Work", pinned: true)
    check(!extra.isLegacy && extra.id != AccountRegistry.legacyClaudeID,
          "new Claude account needs a distinct store ID")
    let reopened = AccountRegistry(fileURL: url)
    check(reopened.accounts.contains(extra), "new account should survive relaunch")
    check(reopened.accounts.filter(\.pinned).count == 3,
          "all requested accounts can remain pinned")
    var renamed = extra
    renamed.label = "Research"
    renamed.pinned = false
    reopened.update(renamed)
    let afterUpdate = AccountRegistry(fileURL: url)
    check(afterUpdate.accounts.first(where: { $0.id == extra.id }) == renamed,
          "label and pin changes should survive relaunch")
    afterUpdate.remove(id: extra.id)
    check(!AccountRegistry(fileURL: url).accounts.contains(where: { $0.id == extra.id }),
          "removed account should not reappear")
    }
}

test("Each added account has a separate persistent WebKit store") {
    MainActor.assumeIsolated {
    let first = Account(id: UUID(), provider: .claude, label: "One", pinned: true)
    let second = Account(id: UUID(), provider: .claude, label: "Two", pinned: true)
    let a = WebSession.forAccount(first)
    let b = WebSession.forAccount(second)
    check(a !== b, "accounts should not share a browser instance")
    check(a.websiteDataStoreIdentifier == first.id, "first account has wrong WebKit store")
    check(b.websiteDataStoreIdentifier == second.id, "second account has wrong WebKit store")
    check(WebSession.claude.websiteDataStoreIdentifier == nil,
          "existing Claude sign-in should retain the default WebKit store")
    }
}

test("chatgpt.com: the plan name is kept with the reading") {
    let dir = tmp.appendingPathComponent("plan-test", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = WebUsageSource.Destination(reading: dir.appendingPathComponent("codex-web.json"),
                                          rawDump: dir.appendingPathComponent("raw.json"))
    let json = #"{"usage":{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":61,"limit_window_seconds":604800,"reset_at":1800500000}}}}"#
    check(WebUsageSource.store(rawJSON: json, to: dest) == nil, "store should succeed")
    let r = ClaudeReadings.read(dest.reading, source: .chatgptWeb)
    check(r?.planType == "prolite", "plan should survive, got \(String(describing: r?.planType))")
}

test("claude.ai / chatgpt.com: similar limit names never overwrite each other") {
    let json = """
    {"usage":{
      "seven_day":{"utilization":40,"resets_at":"2030-01-08T00:00:00Z"},
      "seven_day_opus":{"utilization":90,"resets_at":"2030-01-08T00:00:00Z"},
      "rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1900000000}},
      "code_review_rate_limit":{"primary_window":{"used_percent":77,"limit_window_seconds":604800,"reset_at":1900000000}}}}
    """
    let usage = (try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])["usage"]!
    for _ in 0..<5 {                      // same answer every time, whatever the dictionary order
        let windows = WebUsageSource.parseWindows(usage)
        let byName = Dictionary(windows, uniquingKeysWith: { a, _ in a })
        check(windows.count == 4 && byName.count == 4, "all four kept: \(windows.map(\.0))")
        check(byName["seven_day"]?.usedPercent == 40, "weekly stays the weekly figure")
        check(byName["seven_day_opus"]?.usedPercent == 90, "Opus kept under its own name")
        check(byName["primary"]?.usedPercent == 10, "Codex stays the Codex figure")
        check(byName["code_review_rate_limit.primary_window"]?.usedPercent == 77, "code review kept apart")
    }
}

test("claude.ai: a model's own weekly limit (Fable) is read from the limits list") {
    // Shape of a real Max reply; numbers made up.
    let json = """
    {"plan":{"tier":"default_claude_max_5x","capabilities":["chat","claude_max"]},
     "usage":{
      "five_hour":{"utilization":7,"resets_at":"2030-01-01T05:00:00Z"},
      "seven_day":{"utilization":2,"resets_at":"2030-01-06T11:00:00Z"},
      "seven_day_opus":null,
      "limits":[
        {"group":"session","kind":"session","percent":7,"resets_at":"2030-01-01T05:00:00Z","scope":null},
        {"group":"weekly","kind":"weekly_all","percent":2,"resets_at":"2030-01-06T11:00:00Z","scope":null},
        {"group":"weekly","kind":"weekly_scoped","percent":1,"resets_at":"2030-01-06T11:00:00Z",
         "scope":{"model":{"display_name":"Fable","id":null},"surface":null}}],
      "seven_day_breakdown":{"rows":[{"display_name":"Claude Code","key":"claude_code","percent":88}]}}}
    """
    let usage = (try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])["usage"]!
    let byName = Dictionary(WebUsageSource.parseWindows(usage), uniquingKeysWith: { a, _ in a })
    check(byName.count == 3, "5-hour, weekly and Fable only: \(byName.keys.sorted())")
    check(byName["five_hour"]?.usedPercent == 7, "5-hour unchanged")
    check(byName["seven_day"]?.usedPercent == 2, "weekly stays the all-models figure")
    check(byName["Fable"]?.usedPercent == 1 && byName["Fable"]?.windowMinutes == 10080, "Fable is a weekly limit")
    check(byName["Fable"]?.limitId == "Fable", "Fable keeps its name for the card")

    // Saved and read back like the app does.
    let dir = tmp.appendingPathComponent("fable-test", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = WebUsageSource.Destination(reading: dir.appendingPathComponent("claude.json"),
                                          rawDump: dir.appendingPathComponent("raw.json"))
    check(WebUsageSource.store(rawJSON: json, to: dest) == nil, "store should succeed")
    let reading = ClaudeReadings.read(dest.reading, source: .claudeWeb)
    check(reading?.windows.count == 3, "three windows saved")
    check(reading.flatMap { Provider.claude.headline(from: $0.windows) }?.usedPercent == 7,
          "the big number stays the 5-hour limit")
}

test("claude.ai: the limits list fills in only what the reply lacks") {
    let onlyList = """
    {"limits":[{"group":"session","kind":"session","percent":12,"resets_at":"2030-01-01T05:00:00Z"},
               {"group":"weekly","kind":"weekly_all","percent":30,"resets_at":"2030-01-06T11:00:00Z"}]}
    """
    let byName = Dictionary(WebUsageSource.parseWindows(
        try! JSONSerialization.jsonObject(with: Data(onlyList.utf8))), uniquingKeysWith: { a, _ in a })
    check(byName["five_hour"]?.usedPercent == 12 && byName["seven_day"]?.usedPercent == 30,
          "session and weekly come from the list when there are no blocks: \(byName.keys.sorted())")

    let noModelLimit = """
    {"five_hour":{"utilization":5,"resets_at":"2030-01-01T05:00:00Z"},
     "seven_day":{"utilization":9,"resets_at":"2030-01-06T11:00:00Z"},
     "limits":[{"group":"session","kind":"session","percent":99,"resets_at":"2030-01-01T05:00:00Z"}]}
    """
    let plain = Dictionary(WebUsageSource.parseWindows(
        try! JSONSerialization.jsonObject(with: Data(noModelLimit.utf8))), uniquingKeysWith: { a, _ in a })
    check(plain.count == 2 && plain["five_hour"]?.usedPercent == 5,
          "a plan without model limits looks the same, and the block wins: \(plain)")
}

test("Website scripts only read: no request can change an account") {
    for script in [WebSession.claudeScript, WebSession.chatGPTScript] {
        let lower = script.lowercased()
        check(lower.contains("fetch("), "script makes requests")
        for banned in ["method", "post", "put", "patch", "delete", "xmlhttprequest", "sendbeacon",
                       "navigator.", "websocket", "form", ".submit", ".click"] {
            check(!lower.contains(banned), "script contains '\(banned)'")
        }
    }
}

test("chatgpt.com: limit resets are kept as a count, and extra limits by name") {
    let json = """
    {"usage":{"plan_type":"prolite",
      "rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1900000000},
                    "secondary_window":null},
      "code_review_rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_at":1900000000}},
      "additional_rate_limits":[{"limit_name":"codex_other","rate_limit":{
          "primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_at":1899990000},
          "secondary_window":null}}],
      "rate_limit_reset_credits":{"available_count":1,"applicable_available_count":0}}}
    """
    let dir = tmp.appendingPathComponent("codex-extra", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = WebUsageSource.Destination(reading: dir.appendingPathComponent("codex.json"),
                                          rawDump: dir.appendingPathComponent("raw.json"))
    check(WebUsageSource.store(rawJSON: json, to: dest) == nil, "store should succeed")
    guard let r = ClaudeReadings.read(dest.reading, source: .chatgptWeb) else { return check(false, "no reading") }
    check(r.resetsAvailable == 1, "reset count kept: \(String(describing: r.resetsAvailable))")
    let ids = Set(r.windows.compactMap(\.limitId))
    check(ids.contains("codex_other"), "additional limit kept by name: \(ids)")
    check(ids.contains { $0.contains("code_review") }, "code review kept apart: \(ids)")
    check(Provider.codex.headline(from: r.windows.filter { $0.limitId == nil || $0.limitId == "primary" })?
            .usedPercent == 40, "the plan's own limit is still there")
    check(ProviderCard.readable("codex_other") == "Codex other", "names read as words")
}

test("chatgpt.com: the soonest usable reset's expiry is kept") {
    let now = Date(timeIntervalSince1970: 1_890_000_000)          // Nov 2029
    let list: [[String: Any]] = [
        ["status": "available", "expires_at": "2030-03-20T10:00:00Z"],
        ["status": "available", "expires_at": "2030-03-10T10:00:00Z"],
        ["status": "redeemed", "expires_at": "2030-03-01T10:00:00Z"],     // used: ignored
        ["status": "available", "expires_at": "2029-01-01T00:00:00Z"],    // past: ignored
    ]
    let soonest = WebUsageSource.nextResetExpiry(list, now: now)
    check(soonest == ISO8601DateFormatter().date(from: "2030-03-10T10:00:00Z"), "soonest usable: \(String(describing: soonest))")
    check(WebUsageSource.nextResetExpiry(nil, now: now) == nil, "no list, no date")

    let json = """
    {"usage":{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_at":1900500000}},
              "rate_limit_reset_credits":{"available_count":1}},
     "resets":[{"status":"available","expires_at":"2099-12-12T22:19:24.476343Z"}]}
    """
    let dir = tmp.appendingPathComponent("reset-expiry", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = WebUsageSource.Destination(reading: dir.appendingPathComponent("codex.json"),
                                          rawDump: dir.appendingPathComponent("raw.json"))
    check(WebUsageSource.store(rawJSON: json, to: dest) == nil, "store should succeed")
    let r = ClaudeReadings.read(dest.reading, source: .chatgptWeb)
    check(r?.resetsAvailable == 1 && r?.resetsExpireAt != nil, "count and expiry saved")

    let many = """
    {"usage":{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_at":1900500000}},
              "rate_limit_reset_credits":{"available_count":3}},
     "resets":[{"status":"available","expires_at":"2099-01-03T14:00:00Z"},
               {"status":"available","expires_at":"2099-12-12T22:19:24Z"},
               {"status":"redeemed","expires_at":"2098-01-01T00:00:00Z"},
               {"status":"available","expires_at":"2099-06-20T09:00:00Z"}]}
    """
    check(WebUsageSource.store(rawJSON: many, to: dest) == nil, "store should succeed")
    let all = ClaudeReadings.read(dest.reading, source: .chatgptWeb)?.resetsExpireAll ?? []
    check(all.count == 3 && all == all.sorted(), "every usable reset, soonest first: \(all)")
    check(all.first == ISO8601DateFormatter().date(from: "2099-01-03T14:00:00Z"), "soonest first")
}

test("Saved raw replies never include the email or account ids") {
    let reply: [String: Any] = ["usage": ["email": "a@b.c", "user_id": "u", "account_id": "x",
                                          "rate_limit": ["primary_window": ["used_percent": 5]]]]
    let text = String(data: try JSONSerialization.data(withJSONObject: WebUsageSource.redacted(reply)),
                      encoding: .utf8) ?? ""
    check(!text.contains("a@b.c") && !text.contains("user_id") && !text.contains("account_id"), text)
    check(text.contains("used_percent"), "usage numbers stay")
}

test("Sign-in sites: subdomains match, look-alike domains don't") {
    check(WebSession.isHost("auth.openai.com", within: "openai.com"), "subdomain")
    check(WebSession.isHost("openai.com", within: "openai.com"), "same")
    check(!WebSession.isHost("notopenai.com", within: "openai.com"), "look-alike")
    check(!WebSession.isHost("openai.com.evil.example", within: "openai.com"), "suffix trick")
}

test("claude.ai: the plan comes from the organization (Max is not shown as Pro)") {
    func plan(_ tier: String?, _ caps: [String]) -> String? {
        WebUsageSource.claudePlan(["tier": tier as Any, "capabilities": caps])
    }
    check(plan("default_claude_max_20x", ["chat", "claude_max"]) == "claude_max_20x", "Max 20x")
    check(plan("default_claude_max_5x", ["chat", "claude_max"]) == "claude_max_5x", "Max 5x")
    check(plan(nil, ["chat", "claude_max"]) == "claude_max", "Max without a tier")
    check(plan("default_claude_ai", ["chat", "claude_pro"]) == "claude_pro", "Pro")
    check(plan(nil, ["chat"]) == nil, "unknown plan stays unknown")
    check(WebUsageSource.claudePlan(nil) == nil, "no plan block")

    let dir = tmp.appendingPathComponent("claude-plan-test", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = WebUsageSource.Destination(reading: dir.appendingPathComponent("claude-web.json"),
                                          rawDump: dir.appendingPathComponent("raw.json"))
    let json = #"{"plan":{"tier":"default_claude_max_5x","capabilities":["chat","claude_max"]},"usage":{"five_hour":{"utilization":3,"resets_at":"2030-01-01T00:00:00Z"}}}"#
    check(WebUsageSource.store(rawJSON: json, to: dest) == nil, "store should succeed")
    check(ClaudeReadings.read(dest.reading, source: .claudeWeb)?.planType == "claude_max_5x", "plan saved")
}

test("Accounts can be reordered, and the order is saved") {
    MainActor.assumeIsolated {
        let url = tmp.appendingPathComponent("accounts-order.json")
        try? FileManager.default.removeItem(at: url)
        let registry = AccountRegistry(fileURL: url)
        let extra = registry.add(provider: .claude, label: "Work")
        let before = registry.accounts.map(\.id)
        registry.move(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        check(registry.accounts.map(\.id) == [before[0], extra.id, before[1]], "moved up one place")
        check(AccountRegistry(fileURL: url).accounts.map(\.id) == registry.accounts.map(\.id),
              "order survives a reopen")

        let ids = registry.accounts.map(\.id)
        // List reordering reports the destination as an index before the move.
        registry.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        check(registry.accounts.map(\.id) == [ids[1], ids[2], ids[0]], "first dragged below the last")
        registry.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        check(registry.accounts.map(\.id) == [ids[0], ids[1], ids[2]], "last dragged above the first")
        registry.move(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        check(registry.accounts.map(\.id) == [ids[0], ids[1], ids[2]], "dropping in place changes nothing")
    }
}

// MARK: - Menu bar appearance

test("Menu bar styles: % and time, % only, time left only") {
    let r = providerReading(.claude, AllowanceReading(
        recordedAt: now, source: .claudeWeb, planType: nil,
        windows: [window(38.4, minutes: 300, resetsIn: 2 * 3600 + 21 * 60 + 5),
                  window(63, minutes: 10080, resetsIn: 86400)]))
    check(UsageStore.menuBarFigure(r, now: now, value: .percentAndTime).text == "38% in 2h 21m", "default style")
    check(UsageStore.menuBarFigure(r, now: now, value: .percent).text == "38%", "% only")
    let time = UsageStore.menuBarFigure(r, now: now, value: .timeLeft)
    check(time.text == "2h 21m", "time left only, got \(time.text)")
    check(time.usedPercent == 38, "time left still carries the % for its colour")
}

test("Menu bar All limits: shows whatever limits the account has, shortest first") {
    let both = providerReading(.claude, AllowanceReading(
        recordedAt: now, source: .claudeWeb, planType: nil,
        windows: [window(63, minutes: 10080, resetsIn: 86400), window(38, minutes: 300, resetsIn: 3600)]))
    let f = UsageStore.menuBarFigure(both, now: now, value: .allLimits)
    check(f.text == "38% · 63%", "5-hour + weekly, got \(f.text)")
    check(f.percents == [38, 63], "each % keeps its own colour")

    let weekly = providerReading(.codex, AllowanceReading(
        recordedAt: now, source: .chatgptWeb, planType: nil,
        windows: [window(86, minutes: 10080, resetsIn: 86400)]))
    check(UsageStore.menuBarFigure(weekly, now: now, value: .allLimits).text == "86%", "weekly only")

    // A 5-hour limit that has reset drops out on its own.
    let reset = providerReading(.claude, AllowanceReading(
        recordedAt: now, source: .claudeWeb, planType: nil,
        windows: [window(90, minutes: 300, resetsIn: -1), window(63, minutes: 10080, resetsIn: 86400)]))
    check(UsageStore.menuBarFigure(reset, now: now, value: .allLimits).text == "63%", "expired window hidden")
}

test("Menu bar colours every % in its own band, and a lone countdown by the headline") {
    let font = NSFont.systemFont(ofSize: 13)
    func colour(_ s: NSAttributedString, at i: Int) -> NSColor? {
        s.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
    }
    let all = ProviderIcons.attributed(ProviderIcons.MenuBarFigure(
        text: "38% · 86%", usedPercent: 38, morePercents: [86], name: "Work"), font: font)
    check(colour(all, at: 0) == .labelColor, "name stays plain")
    check(colour(all, at: 5) == .systemYellow, "38% yellow")
    check(colour(all, at: 11) == .systemRed, "86% red")
    let time = ProviderIcons.attributed(ProviderIcons.MenuBarFigure(text: "2h 21m", usedPercent: 60), font: font)
    check(colour(time, at: 0) == .systemOrange, "countdown alone takes the headline colour")
}

test("Accounts saved before appearance settings load with the default look") {
    let old = #"[{"id":"\#(UUID().uuidString)","provider":"claude","label":"Work","pinned":true}]"#
    let accounts = try? JSONDecoder().decode([Account].self, from: Data(old.utf8))
    check(accounts?.first?.value == .percentAndTime, "default value style")
    check(accounts?.first?.labelStyle == .logoAndName, "default label style")
}

test("A removed original account stays removed after relaunch") {
    MainActor.assumeIsolated {
    let saved = AccountRegistry.removedLegacyIDs
    defer { AccountRegistry.removedLegacyIDs = saved }
    AccountRegistry.removedLegacyIDs = []
    let url = tmp.appendingPathComponent("accounts-removed.json")
    AccountRegistry(fileURL: url).remove(id: AccountRegistry.legacyCodexID)
    let reopened = AccountRegistry(fileURL: url)
    check(!reopened.accounts.contains(where: { $0.id == AccountRegistry.legacyCodexID }),
          "the original Codex account should not be put back")
    check(reopened.accounts.contains(where: { $0.id == AccountRegistry.legacyClaudeID }),
          "the other original account is untouched")
    }
}

print("\n\(passed) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
