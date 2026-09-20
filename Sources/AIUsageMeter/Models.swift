import Foundation

// MARK: - Allowance readings

/// Where an allowance reading came from. The UI words each one differently,
/// because they mean different things:
/// - `anthropicLive`: we asked Anthropic just now ("checked with Anthropic").
/// - `claudeStatusLine`: Claude Code handed it to a local script; the time is
///   when it was *received locally*, not when Anthropic produced it.
/// - `codexLog`: the Codex CLI wrote it into a session log while running.
enum ReadingSource: String, Sendable, Equatable, CaseIterable {
    case anthropicLive = "anthropic-live"
    case claudeStatusLine = "claude-statusline"
    case codexLog = "codex-log"
    /// Read from claude.ai inside the app's own signed-in web view.
    case claudeWeb = "claude-web"
}

/// One limit window as a provider reported it, e.g. "5-hour, 38% used".
struct AllowanceWindow: Sendable, Equatable, Codable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
    /// Provider's own id for the limit (Codex: `limit_id`, e.g. "codex"). Kept so
    /// accounts with several limits are not merged or mislabeled.
    var limitId: String?

    /// A window's figure is only meaningful until it resets. After that the true
    /// usage is unknown -- NOT zero -- and must never be shown as a percentage.
    ///
    /// `resetsAt` is not always reported. Anthropic omits it for a 5-hour window
    /// sitting at 0%, and a reading like that used to stay on screen for ever,
    /// showing 0% long after real usage had started. So a window also goes stale
    /// once it is older than its own length: a 5-hour figure can say nothing
    /// about a moment more than 5 hours after it was taken.
    func isExpired(now: Date, recordedAt: Date) -> Bool {
        if let resetsAt, resetsAt <= now { return true }
        guard let windowMinutes else {
            // Unknown length: treat an hour as the longest it can be trusted.
            return now.timeIntervalSince(recordedAt) >= 3600
        }
        return now.timeIntervalSince(recordedAt) >= Double(windowMinutes) * 60
    }

    var windowLabel: String {
        guard let windowMinutes else { return "unknown window" }
        if windowMinutes % 10080 == 0 { return "\(windowMinutes / 10080)-week" }
        if windowMinutes % 1440 == 0 { return "\(windowMinutes / 1440)-day" }
        if windowMinutes % 60 == 0 { return "\(windowMinutes / 60)-hour" }
        return "\(windowMinutes)-minute"
    }
}

/// Everything one source reported at one moment: possibly several windows.
struct AllowanceReading: Sendable, Equatable {
    var recordedAt: Date
    var source: ReadingSource
    var planType: String?
    var windows: [AllowanceWindow]

    /// Windows still valid at `now`. Recomputed on every render, so a reading
    /// that crosses its reset time -- or simply gets too old -- while the panel
    /// is open stops showing a number.
    func liveWindows(now: Date) -> [AllowanceWindow] {
        windows.filter { !$0.isExpired(now: now, recordedAt: recordedAt) }
    }
}

// MARK: - Provider state

enum Provider: String, Sendable, Equatable {
    case claude, codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        // Named after the subscription, but the figure is the *Codex* limit of
        // that plan -- the UI says "Codex limit" wherever a percentage appears.
        case .codex: return "ChatGPT"
        }
    }

    /// Which window leads the card and the menu bar.
    /// - Claude: the 5-hour window, the one that moves while working.
    /// - Codex: the window closest to its limit, the one that will stop work.
    func headline(from windows: [AllowanceWindow]) -> AllowanceWindow? {
        switch self {
        case .claude:
            return windows.first { $0.windowMinutes == 300 }
                ?? windows.min { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
        case .codex:
            return windows.max { $0.usedPercent < $1.usedPercent }
        }
    }
}

/// What the UI should show for a provider's allowance at a given moment.
enum AllowanceDisplay: Equatable {
    /// At least one valid window. `reading` is the one the headline came from;
    /// `others` are the remaining valid windows, from any reading.
    case available(headline: AllowanceWindow, others: [AllowanceWindow], reading: AllowanceReading)
    /// Readings exist, but every window in them has reset. `reading` is the newest.
    case expired(reading: AllowanceReading)
    /// No provider-reported figure at all.
    case unavailable
}

struct ProviderReading: Sendable, Equatable {
    var provider: Provider
    /// Candidate readings: the newest per source and per limit (`limit_id`), so a
    /// newer reading for one Codex limit can't hide another. Claude's are reduced
    /// to one at display time by `ClaudeReadings.choose`.
    var readings: [AllowanceReading]
    /// Why there is no reading, shown when `readings` is empty.
    var unavailableNote: String
    /// Log files seen for this provider, and how many had new bytes this pass.
    /// Zero read means everything was already indexed.
    var filesSeen: Int = 0
    var filesReadThisPass: Int = 0

    var providerName: String { provider.displayName }

    /// Plan name from the newest reading that reports one.
    var planType: String? {
        readings.sorted { $0.recordedAt > $1.recordedAt }.lazy.compactMap(\.planType).first
    }

    /// Decided at render time, never cached, so expiry is always current. For
    /// Claude the source is also chosen here, since which reading is usable
    /// changes as windows reset.
    func display(now: Date) -> AllowanceDisplay {
        let readings = provider == .claude
            ? ClaudeReadings.choose(self.readings, now: now).map { [$0] } ?? []
            : self.readings
        guard let newest = readings.max(by: { $0.recordedAt < $1.recordedAt }) else { return .unavailable }
        let valid = readings.flatMap { r in r.liveWindows(now: now).map { (window: $0, reading: r) } }
        guard let head = provider.headline(from: valid.map(\.window)),
              let headReading = valid.first(where: { $0.window == head })?.reading
        else { return .expired(reading: newest) }
        var others = valid.map(\.window)
        if let i = others.firstIndex(of: head) { others.remove(at: i) }
        others.sort { ($0.windowMinutes ?? .max, $0.limitId ?? "") < ($1.windowMinutes ?? .max, $1.limitId ?? "") }
        return .available(headline: head, others: others, reading: headReading)
    }
}

struct UsageReport: Sendable, Equatable {
    var claude: ProviderReading?
    var codex: ProviderReading?
    var scannedAt: Date
    var scanDuration: TimeInterval
    var errors: [String] = []
}

// MARK: - Formatting

enum Fmt {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 0 { return "just now" }
        if s < 60 { return "\(Int(s))s ago" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return String(format: "%.1fh ago", s / 3600) }
        return String(format: "%.1fd ago", s / 86400)
    }

    static func until(_ date: Date, now: Date = Date()) -> String {
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "already reset" }
        if s < 3600 { return "in \(Int(s / 60))m" }
        if s < 86400 { return String(format: "in %.1fh", s / 3600) }
        return String(format: "in %.1fd", s / 86400)
    }

    /// Compact countdown for the menu bar: "2h 21m", "21m", "1d 4h".
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let mins = max(0, Int(date.timeIntervalSince(now) / 60))
        if mins >= 1440 { return "\(mins / 1440)d \((mins % 1440) / 60)h" }
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    /// How the source of a reading is described to the user.
    static func sourceLine(_ r: AllowanceReading, now: Date) -> String {
        switch r.source {
        case .anthropicLive: return "Checked with Anthropic · \(age(r.recordedAt, now: now))"
        case .claudeStatusLine: return "From Claude Code status line · received \(age(r.recordedAt, now: now))"
        case .codexLog: return "From Codex logs · recorded \(age(r.recordedAt, now: now))"
        case .claudeWeb: return "From claude.ai · \(age(r.recordedAt, now: now))"
        }
    }
}
